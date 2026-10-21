import Foundation
import AppKit

// MARK: - Progress reporting

struct OpProgress: Equatable {
    var title: String
    var detail: String
    var filesDone: Int
    var filesTotal: Int
    var bytesDone: Int64
    var bytesTotal: Int64
    var bytesPerSecond: Double
    /// When the engine last reported. Lets the UI spot a stalled destination.
    var updatedAt: Date = Date()

    var fraction: Double {
        if bytesTotal > 0 { return min(1, Double(bytesDone) / Double(bytesTotal)) }
        if filesTotal > 0 { return min(1, Double(filesDone) / Double(filesTotal)) }
        return 0
    }

    /// Nothing to measure yet (e.g. the up front folder scan).
    var isIndeterminate: Bool { bytesTotal == 0 && filesTotal == 0 }

    var secondsSinceUpdate: Double { Date().timeIntervalSince(updatedAt) }

    /// No news for a while: the destination is almost certainly the bottleneck.
    var isStalled: Bool { secondsSinceUpdate > 8 && !isIndeterminate }

    var etaText: String {
        guard bytesPerSecond > 1000, bytesTotal > bytesDone else { return "" }
        let seconds = Double(bytesTotal - bytesDone) / bytesPerSecond
        if seconds < 1 { return "less than a second remaining" }
        if seconds < 60 { return "\(Int(seconds)) s remaining" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min remaining" }
        return "\(Int(seconds / 3600)) h remaining"
    }

    var rateText: String {
        guard bytesPerSecond > 0 else { return "" }
        return ByteFormatter.string(Int64(bytesPerSecond)) + "/s"
    }
}

final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }
}

enum ConflictResolution {
    case replace
    case skip
    case keepBoth
    case cancel
}

struct ConflictPrompt {
    let name: String
    let sourceDetail: [String]
    let targetDetail: [String]
}

// MARK: - Transfer engine (runs off the main thread)

/// Mutable state for one transfer. It is only mutated from the single worker
/// queue; the cancel token inside it is thread safe.
final class TransferContext: @unchecked Sendable {
    let title: String
    let token = CancelToken()

    var filesDone = 0
    var filesTotal = 0
    var bytesDone: Int64 = 0
    var bytesTotal: Int64 = 0
    var errors: [String] = []
    var cancelled: Bool { token.isCancelled }

    /// `ask` prompts for every conflict, the others short-circuit the dialog.
    enum Policy { case ask, replaceAll, skipAll, keepBothAll }
    var policy: Policy = .ask

    private let onReport: (OpProgress) -> Void
    private let started = Date()
    private var lastReport = Date.distantPast

    init(title: String, onReport: @escaping (OpProgress) -> Void) {
        self.title = title
        self.onReport = onReport
    }

    func report(detail: String, force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastReport) > 0.08 else { return }
        lastReport = now
        let elapsed = max(0.001, now.timeIntervalSince(started))
        let progress = OpProgress(
            title: title,
            detail: detail,
            filesDone: filesDone,
            filesTotal: filesTotal,
            bytesDone: bytesDone,
            bytesTotal: bytesTotal,
            bytesPerSecond: Double(bytesDone) / elapsed,
            updatedAt: now
        )
        onReport(progress)
    }

    func addError(_ message: String) {
        if errors.count < 500 { errors.append(message) }
    }
}

enum TransferEngine {

    // MARK: Public entry points

    static func run(sources: [URL], destination: URL, move: Bool, context: TransferContext) {
        try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        // The up front scan can take a while on a big tree, so say so and keep
        // reporting while it runs instead of sitting silent.
        context.report(detail: "Measuring \(sources.count == 1 ? sources[0].lastPathComponent : "\(sources.count) items")…",
                       force: true)

        var planned: [(URL, Int64, Int)] = []
        for source in sources {
            if context.cancelled { return }
            let measured = FileSystemService.measure(source, progress: { bytes, files in
                context.filesDone = files
                context.bytesDone = bytes
                context.report(detail: "Measuring \(source.lastPathComponent)…")
            }, shouldStop: { context.cancelled })
            planned.append((source, measured.bytes, max(1, measured.files)))
        }

        context.bytesTotal = planned.reduce(0) { $0 + $1.1 }
        context.filesTotal = planned.reduce(0) { $0 + $1.2 }
        context.bytesDone = 0
        context.filesDone = 0
        context.report(detail: "Starting…", force: true)

        for (source, _, _) in planned {
            if context.cancelled { break }
            let target = destination.appendingPathComponent(source.lastPathComponent)
            transfer(source: source, destination: target, move: move, context: context)
        }

        context.report(detail: move ? "Move finished" : "Copy finished", force: true)
    }

    static func delete(urls: [URL], permanent: Bool, context: TransferContext) {
        let fm = FileManager.default
        var total: Int64 = 0
        var count = 0
        for url in urls {
            let measured = FileSystemService.measure(url)
            total += measured.bytes
            count += max(1, measured.files)
        }
        context.bytesTotal = total
        context.filesTotal = count
        context.report(detail: permanent ? "Deleting…" : "Moving to Trash…", force: true)

        for url in urls {
            if context.cancelled { break }
            let measuredSize = FileSystemService.measure(url).bytes
            do {
                if permanent {
                    try fm.removeItem(at: url)
                } else {
                    var resulting: NSURL?
                    try fm.trashItem(at: url, resultingItemURL: &resulting)
                }
                context.filesDone += 1
                context.bytesDone += measuredSize
            } catch {
                context.addError("\(url.lastPathComponent): \(error.localizedDescription)")
            }
            context.report(detail: url.lastPathComponent)
        }
        context.report(detail: permanent ? "Delete finished" : "Trash finished", force: true)
    }

    // MARK: Core transfer

    /// Returns true when the item was fully transferred (or deliberately skipped).
    @discardableResult
    static func transfer(source: URL, destination: URL, move: Bool, context: TransferContext) -> Bool {
        if context.cancelled { return false }
        let fm = FileManager.default

        // Refuse to copy or move an item onto itself, or a folder into itself.
        let sourcePath = source.standardizedFileURL.path
        let destinationPath = destination.standardizedFileURL.path
        if sourcePath == destinationPath {
            context.addError("“\(source.lastPathComponent)” is already in place.")
            return false
        }
        if FileSystemService.isDescendant(destination, of: source) {
            context.addError("Cannot copy “\(source.lastPathComponent)” into itself.")
            return false
        }

        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDirectory) else {
            context.addError("\(source.path): no such file")
            return false
        }

        // Symlinks are copied as links, never followed.
        if let values = try? source.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true {
            return transferSymlink(source: source, destination: destination, context: context)
        }

        guard isDirectory.boolValue else {
            return transferFile(source: source, destination: destination, move: move, context: context)
        }

        return transferDirectory(source: source, destination: destination, move: move, context: context)
    }

    private static func transferDirectory(source: URL, destination: URL, move: Bool, context: TransferContext) -> Bool {
        let fm = FileManager.default
        var destinationIsDirectory: ObjCBool = false
        let destinationExists = fm.fileExists(atPath: destination.path, isDirectory: &destinationIsDirectory)

        if destinationExists && !destinationIsDirectory.boolValue {
            // A file occupies the name we need.
            switch resolveConflict(source: source, destination: destination, context: context) {
            case .skip:
                return true
            case .cancel:
                context.token.cancel()
                return false
            case .replace:
                do { try fm.removeItem(at: destination) }
                catch { context.addError("\(destination.lastPathComponent): \(error.localizedDescription)"); return false }
            case .keepBoth:
                return transferDirectory(source: source,
                                         destination: FileSystemService.uniqueURL(for: destination),
                                         move: move, context: context)
            }
        }

        if !destinationExists {
            do {
                try fm.createDirectory(at: destination, withIntermediateDirectories: true,
                                       attributes: try? fm.attributesOfItem(atPath: source.path))
            } catch {
                context.addError("\(destination.lastPathComponent): \(error.localizedDescription)")
                return false
            }
        }

        let children: [URL]
        do {
            children = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil, options: [])
        } catch {
            context.addError("\(source.lastPathComponent): \(error.localizedDescription)")
            return false
        }

        for child in children {
            if context.cancelled { return false }
            let target = destination.appendingPathComponent(child.lastPathComponent)
            transfer(source: child, destination: target, move: move, context: context)
        }

        if move && !context.cancelled {
            do { try fm.removeItem(at: source) }
            catch { context.addError("\(source.lastPathComponent): \(error.localizedDescription)") }
        }
        copyMetadata(from: source, to: destination)
        return true
    }

    private static func transferFile(source: URL, destination: URL, move: Bool, context: TransferContext) -> Bool {
        let fm = FileManager.default

        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: destination.path, isDirectory: &isDirectory) {
            if isDirectory.boolValue {
                // file onto a folder of the same name
                switch resolveConflict(source: source, destination: destination, context: context) {
                case .skip: return true
                case .cancel: context.token.cancel(); return false
                case .replace:
                    do { try fm.removeItem(at: destination) }
                    catch { context.addError("\(destination.lastPathComponent): \(error.localizedDescription)"); return false }
                case .keepBoth:
                    return transferFile(source: source,
                                        destination: FileSystemService.uniqueURL(for: destination),
                                        move: move, context: context)
                }
            } else {
                switch resolveConflict(source: source, destination: destination, context: context) {
                case .skip:
                    context.filesDone += 1
                    context.bytesDone += fileSize(source)
                    context.report(detail: source.lastPathComponent)
                    return true
                case .cancel:
                    context.token.cancel()
                    return false
                case .replace:
                    do { try fm.removeItem(at: destination) }
                    catch { context.addError("\(destination.lastPathComponent): \(error.localizedDescription)"); return false }
                case .keepBoth:
                    return transferFile(source: source,
                                        destination: FileSystemService.uniqueURL(for: destination),
                                        move: move, context: context)
                }
            }
        }

        let sourceSize = fileSize(source)

        // Fast path: a move inside the same filesystem is just a rename.
        if move, FileSystemService.isSameVolume(source, destination) {
            do {
                try fm.moveItem(at: source, to: destination)
                context.filesDone += 1
                context.bytesDone += sourceSize
                context.report(detail: source.lastPathComponent)
                return true
            } catch {
                // Cross device or a race: fall through to the streaming copy.
            }
        }

        do {
            try streamCopy(source: source,
                           destination: destination,
                           context: context,
                           flushing: !FileSystemService.isSameVolume(source, destination))
        } catch {
            if (error as NSError).code == NSUserCancelledError { return false }
            context.addError("\(source.lastPathComponent): \(error.localizedDescription)")
            return false
        }
        if move {
            try? fm.removeItem(at: source)
        }

        context.filesDone += 1
        context.report(detail: source.lastPathComponent)
        return true
    }

    private static func transferSymlink(source: URL, destination: URL, context: TransferContext) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            switch resolveConflict(source: source, destination: destination, context: context) {
            case .skip: return true
            case .cancel: context.token.cancel(); return false
            case .replace:
                do { try fm.removeItem(at: destination) }
                catch { context.addError("\(destination.lastPathComponent): \(error.localizedDescription)"); return false }
            case .keepBoth:
                return transferSymlink(source: source,
                                       destination: FileSystemService.uniqueURL(for: destination),
                                       context: context)
            }
        }
        do {
            let target = try fm.destinationOfSymbolicLink(atPath: source.path)
            try fm.createSymbolicLink(atPath: destination.path, withDestinationPath: target)
        } catch {
            context.addError("\(source.lastPathComponent): \(error.localizedDescription)")
            return false
        }
        context.filesDone += 1
        context.report(detail: source.lastPathComponent)
        return true
    }

    // MARK: Byte streaming

    /// Streams a file's contents between two locations.
    ///
    /// `flushing` is on for cross volume copies (see the notes inside); the self
    /// tests drive it directly so both paths stay covered.
    static func streamCopy(source: URL,
                           destination: URL,
                           context: TransferContext,
                           flushing: Bool) throws {
        let chunkSize = 1024 * 1024
        let flushInterval: Int64 = 32 * 1024 * 1024

        let sourceDescriptor = source.path.withCString { open($0, O_RDONLY) }
        guard sourceDescriptor >= 0 else { throw posixError(for: source) }
        defer { close(sourceDescriptor) }

        let attributes = try? FileManager.default.attributesOfItem(atPath: source.path)
        let permissions = mode_t((attributes?[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o644)
        let destinationDescriptor = destination.path.withCString {
            open($0, O_WRONLY | O_CREAT | O_TRUNC, permissions)
        }
        guard destinationDescriptor >= 0 else { throw posixError(for: destination) }

        var destinationClosed = false
        func closeDestination() {
            if !destinationClosed {
                destinationClosed = true
                close(destinationDescriptor)
            }
        }
        defer { closeDestination() }

        // Writing through the page cache is great between two directories on the
        // same volume, but when the destination is slower than the source (an
        // external drive, say) a fast reader fills RAM with dirty pages until the
        // kernel blocks the writer. Dropping the cache for cross volume copies and
        // flushing in bounded windows keeps progress honest and the Mac usable.
        if flushing {
            _ = fcntl(destinationDescriptor, F_NOCACHE, 1)
        }

        var buffer = [UInt8](repeating: 0, count: chunkSize)
        var sinceFlush: Int64 = 0
        var lastTick = Date()

        while true {
            if context.cancelled {
                closeDestination()
                try? FileManager.default.removeItem(at: destination)
                throw NSError(domain: "TotalMac", code: NSUserCancelledError,
                              userInfo: [NSLocalizedDescriptionKey: "Cancelled"])
            }

            let bytesRead = buffer.withUnsafeMutableBytes { raw -> Int in
                read(sourceDescriptor, raw.baseAddress, chunkSize)
            }
            if bytesRead < 0 {
                if errno == EINTR { continue }
                throw posixError(for: source)
            }
            if bytesRead == 0 { break }

            var offset = 0
            while offset < bytesRead {
                let written = buffer.withUnsafeBytes { raw -> Int in
                    write(destinationDescriptor,
                          raw.baseAddress!.advanced(by: offset),
                          bytesRead - offset)
                }
                if written < 0 {
                    if errno == EINTR { continue }
                    throw posixError(for: destination)
                }
                if written == 0 {
                    throw NSError(domain: "TotalMac", code: 0, userInfo: [
                        NSLocalizedDescriptionKey: "\(destination.lastPathComponent): the destination refused more data"
                    ])
                }
                offset += written
            }

            context.bytesDone += Int64(bytesRead)
            sinceFlush += Int64(bytesRead)

            if sinceFlush >= flushInterval {
                sinceFlush = 0
                // Announce before blocking, so the window shows why it is waiting.
                context.report(detail: "flushing to \(destination.deletingLastPathComponent().lastPathComponent)…",
                               force: true)
                if fsync(destinationDescriptor) != 0, errno == ENOSPC {
                    throw posixError(for: destination)
                }
            }

            let now = Date()
            if now.timeIntervalSince(lastTick) > 0.08 {
                lastTick = now
                context.report(detail: source.lastPathComponent)
            }
        }

        if fsync(destinationDescriptor) != 0, errno == ENOSPC {
            throw posixError(for: destination)
        }
        closeDestination()
        copyMetadata(from: source, to: destination)
    }

    private static func posixError(for url: URL) -> NSError {
        let code = errno
        let message = String(cString: strerror(code))
        return NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                       userInfo: [NSLocalizedDescriptionKey: "\(url.lastPathComponent): \(message)"])
    }

    static func copyMetadata(from source: URL, to destination: URL) {
        let fm = FileManager.default
        var attributes: [FileAttributeKey: Any] = [:]
        if let sourceAttributes = try? fm.attributesOfItem(atPath: source.path) {
            if let permissions = sourceAttributes[.posixPermissions] { attributes[.posixPermissions] = permissions }
            if let modified = sourceAttributes[.modificationDate] { attributes[.modificationDate] = modified }
            if let created = sourceAttributes[.creationDate] { attributes[.creationDate] = created }
        }
        if !attributes.isEmpty {
            try? fm.setAttributes(attributes, ofItemAtPath: destination.path)
        }
        // Preserve extended attributes, ACLs and Finder metadata.
        _ = copyfile(source.path, destination.path, nil, copyfile_flags_t(COPYFILE_METADATA))
    }

    // MARK: Conflict handling

    private static func resolveConflict(source: URL, destination: URL, context: TransferContext) -> ConflictResolution {
        switch context.policy {
        case .replaceAll: return .replace
        case .skipAll: return .skip
        case .keepBothAll: return .keepBoth
        case .ask: break
        }

        let prompt = ConflictPrompt(
            name: source.lastPathComponent,
            sourceDetail: details(for: source),
            targetDetail: details(for: destination)
        )

        var resolution: ConflictResolution = .skip
        var applyToAll = false

        DispatchQueue.main.sync {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "File already exists"
            alert.informativeText = """
            The destination file already exists.

            Source:
            \(prompt.sourceDetail.joined(separator: "\n"))

            Target:
            \(prompt.targetDetail.joined(separator: "\n"))
            """
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Skip")
            alert.addButton(withTitle: "Keep Both")
            alert.addButton(withTitle: "Cancel")

            let checkbox = NSButton(checkboxWithTitle: "Apply to all", target: nil, action: nil)
            checkbox.state = .off
            alert.accessoryView = checkbox

            let response = alert.runModal()
            applyToAll = checkbox.state == .on
            switch response {
            case .alertFirstButtonReturn: resolution = .replace
            case .alertSecondButtonReturn: resolution = .skip
            case .alertThirdButtonReturn: resolution = .keepBoth
            default: resolution = .cancel
            }
        }

        if applyToAll {
            switch resolution {
            case .replace: context.policy = .replaceAll
            case .skip: context.policy = .skipAll
            case .keepBoth: context.policy = .keepBothAll
            case .cancel: break
            }
        }
        return resolution
    }

    private static func details(for url: URL) -> [String] {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return ["  (nothing)"] }
        var lines = ["  \(url.path)"]
        if isDirectory.boolValue {
            lines.append("  Folder")
        } else {
            lines.append("  \(ByteFormatter.string(fileSize(url))) (\(fileSize(url)) bytes)")
        }
        if let attributes = try? fm.attributesOfItem(atPath: url.path),
           let modified = attributes[.modificationDate] as? Date {
            lines.append("  Modified \(DateFormatter.short(modified))")
        }
        return lines
    }

    private static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
}

extension FileSystemService {
    /// True when `candidate` lives inside `ancestor` (or is the same item).
    static func isDescendant(_ candidate: URL, of ancestor: URL) -> Bool {
        let a = ancestor.standardizedFileURL.resolvingSymlinksInPath().path
        let c = candidate.standardizedFileURL.resolvingSymlinksInPath().path
        if a == c { return true }
        return c.hasPrefix(a.hasSuffix("/") ? a : a + "/")
    }
}
