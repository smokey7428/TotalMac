import Foundation
import CArchive

// MARK: - Model

/// One member of an archive, with its path normalised to use `/` separators
/// and no leading or trailing slash.
struct ArchiveEntry: Identifiable, Hashable {
    var path: String
    var isDirectory: Bool
    var isSymlink: Bool
    var symlinkTarget: String?
    var size: Int64
    var modified: Date?
    var permissions: String
    var isEncrypted: Bool

    var id: String { path }

    var name: String {
        guard let index = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: index)...])
    }

    /// "" for entries at the archive root.
    var parentPath: String {
        guard let index = path.lastIndex(of: "/") else { return "" }
        return String(path[..<index])
    }

    var depth: Int {
        path.reduce(0) { $0 + ($1 == "/" ? 1 : 0) }
    }

    var formattedSize: String {
        isDirectory ? "<DIR>" : ByteFormatter.string(size)
    }
}

enum ArchiveFormat: String, CaseIterable, Identifiable {
    case zip
    case tarGz = "tar.gz"
    case tar

    var id: String { rawValue }

    var title: String {
        switch self {
        case .zip: return "ZIP archive"
        case .tarGz: return "TAR archive, gzip compressed"
        case .tar: return "TAR archive, uncompressed"
        }
    }

    var fileExtension: String {
        switch self {
        case .zip: return "zip"
        case .tarGz: return "tar.gz"
        case .tar: return "tar"
        }
    }

    var isZip: Bool { self == .zip }
}

enum ArchiveError: LocalizedError {
    case cannotOpen(String)
    case corrupt(String)
    case unsupported(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .cannotOpen(let message): return "Cannot open the archive: \(message)"
        case .corrupt(let message): return "The archive could not be read: \(message)"
        case .unsupported(let message): return message
        case .cancelled: return "Cancelled"
        }
    }
}

// MARK: - Reader

/// Thin RAII wrapper over the libarchive reader handle.
final class ArchiveReader {
    private var handle: UnsafeMutableRawPointer?

    let path: String

    init(path: String) throws {
        self.path = path
        var error = [CChar](repeating: 0, count: 512)
        let opened = path.withCString { cPath in
            error.withUnsafeMutableBufferPointer { buffer in
                tmac_read_open(cPath, buffer.baseAddress, 512)
            }
        }
        guard let opened else {
            throw ArchiveError.cannotOpen(String(cString: error))
        }
        handle = opened
    }

    deinit {
        if let handle { _ = tmac_read_close(handle) }
    }

    var formatName: String {
        guard let handle else { return "" }
        return String(cString: tmac_format_name(handle))
    }

    /// nil at the end of the archive.
    func next() throws -> ArchiveEntry? {
        guard let handle else { return nil }
        var info = tmac_entry_info()
        var error = [CChar](repeating: 0, count: 512)
        let status = error.withUnsafeMutableBufferPointer { buffer in
            tmac_read_next(handle, &info, buffer.baseAddress, 512)
        }
        if status == 0 { return nil }
        if status < 0 { throw ArchiveError.corrupt(String(cString: error)) }

        let rawPath = info.pathname.map { String(cString: $0) } ?? ""
        var normalized = ArchiveService.normalize(path: rawPath)
        var isDirectory = tmac_is_dir(info.filetype) != 0
        // Some zips store directories without the trailing slash.
        if !isDirectory && rawPath.hasSuffix("/") { isDirectory = true }
        if isDirectory && normalized.isEmpty { return try next() }

        let isSymlink = tmac_is_symlink(info.filetype) != 0
        let target = info.symlink.map { String(cString: $0) }

        if normalized.isEmpty, !isDirectory {
            // Nothing sensible to show for an unnamed entry.
            return try next()
        }
        if isDirectory, !normalized.hasSuffix("/") {
            normalized += "/"
        }

        let entryPath = isDirectory ? String(normalized.dropLast()) : normalized

        return ArchiveEntry(
            path: entryPath,
            isDirectory: isDirectory,
            isSymlink: isSymlink,
            symlinkTarget: target,
            size: info.size,
            modified: info.mtime > 0 ? Date(timeIntervalSince1970: TimeInterval(info.mtime)) : nil,
            permissions: FileSystemService.posixString(UInt16(truncatingIfNeeded: info.perm),
                                                       ownerIsDirectory: isDirectory),
            isEncrypted: info.is_encrypted != 0
        )
    }

    /// Reads up to `buffer.count` bytes of the current entry's data.
    func read(into buffer: inout [UInt8]) -> Int {
        guard let handle else { return -1 }
        return buffer.withUnsafeMutableBytes { raw in
            Int(tmac_read_data(handle, raw.baseAddress, raw.count))
        }
    }

    func close() {
        if let handle {
            _ = tmac_read_close(handle)
            self.handle = nil
        }
    }
}

// MARK: - Service

struct ArchiveExtractResult {
    var files = 0
    var bytes: Int64 = 0
    var skipped = 0
    var cancelled = false
}

struct ArchivePackResult {
    var files = 0
    var bytes: Int64 = 0
    var cancelled = false
}

enum ArchiveService {

    static var libarchiveVersion: String { String(cString: tmac_version()) }

    /// Last error reported by the underlying library (for diagnostics).
    static var lastError: String { String(cString: tmac_error()) }

    /// Extensions (and compound extensions) we will try to open.
    private static let extensions: Set<String> = [
        "zip", "jar", "war", "apk", "ipa", "xpi", "epub", "odt", "ods", "odp", "docx", "xlsx", "pptx",
        "tar", "tar.gz", "tgz", "tar.bz2", "tbz", "tbz2", "tar.xz", "txz", "tar.zst", "tar.lzma",
        "cpio", "pax", "iso", "7z", "rar", "cab", "xar", "pkg", "dmg", "lha", "lzh", "ar", "mtree"
    ]

    /// Names we can create.
    static let packFormats: [ArchiveFormat] = [.zip, .tarGz, .tar]

    static func isArchive(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return false
        }
        let name = url.lastPathComponent.lowercased()
        if extensions.contains(name) { return false } // a file called "zip"
        for candidate in extensions where name.hasSuffix("." + candidate) {
            return true
        }
        return false
    }

    /// Normalises an archive member path: forward slashes, no leading "./" or
    /// "/", no empty components and no "..", which keeps extraction safe.
    static func normalize(path: String) -> String {
        var result: [String] = []
        for component in path.replacingOccurrences(of: "\\", with: "/").split(separator: "/") {
            let part = String(component)
            if part.isEmpty || part == "." { continue }
            if part == ".." { continue }
            result.append(part)
        }
        return result.joined(separator: "/")
    }

    // MARK: Listing

    static func list(_ url: URL) throws -> (format: String, entries: [ArchiveEntry]) {
        let reader = try ArchiveReader(path: url.path)
        defer { reader.close() }
        var entries: [ArchiveEntry] = []
        while let entry = try reader.next() {
            entries.append(entry)
        }
        return (reader.formatName, entries)
    }

    /// Direct children of `internalPath` ("" = root) as file panel rows.
    static func children(of internalPath: String,
                         archive: URL,
                         entries: [ArchiveEntry],
                         showHidden: Bool) -> [FileItem] {
        let prefix = internalPath.isEmpty ? "" : internalPath + "/"
        var seen = Set<String>()
        var items: [FileItem] = []

        for entry in entries {
            guard entry.path.hasPrefix(prefix) else { continue }
            let remainder = String(entry.path.dropFirst(prefix.count))
            if remainder.isEmpty { continue }

            if let slash = remainder.firstIndex(of: "/") {
                // Deeper entry: contribute its intermediate directory.
                let directoryName = String(remainder[..<slash])
                guard !seen.contains(directoryName) else { continue }
                seen.insert(directoryName)
                let childPath = prefix + directoryName
                items.append(virtualItem(name: directoryName,
                                         memberPath: childPath,
                                         isDirectory: true,
                                         size: descendantSize(of: childPath, in: entries),
                                         modified: nil,
                                         archive: archive))
            } else {
                guard !seen.contains(remainder) else { continue }
                let childPath = prefix + remainder
                items.append(virtualItem(name: remainder,
                                         memberPath: childPath,
                                         isDirectory: entry.isDirectory,
                                         size: entry.isDirectory
                                            ? descendantSize(of: childPath, in: entries)
                                            : entry.size,
                                         modified: entry.modified,
                                         permissions: entry.permissions,
                                         isSymlink: entry.isSymlink,
                                         target: entry.symlinkTarget,
                                         archive: archive))
            }
        }

        if !showHidden {
            items.removeAll { $0.name.hasPrefix(".") }
        }
        return items
    }

    private static func descendantSize(of directoryPath: String, in entries: [ArchiveEntry]) -> Int64 {
        let prefix = directoryPath + "/"
        var total: Int64 = 0
        for entry in entries where !entry.isDirectory && entry.path.hasPrefix(prefix) {
            total += entry.size
        }
        return total
    }

    static func virtualItem(name: String,
                            memberPath: String,
                            isDirectory: Bool,
                            size: Int64,
                            modified: Date?,
                            permissions: String = "rwxr-xr-x",
                            isSymlink: Bool = false,
                            target: String? = nil,
                            archive: URL) -> FileItem {
        FileItem(
            url: URL(fileURLWithPath: archive.path + "/" + memberPath),
            name: name,
            isDirectory: isDirectory,
            isPackage: false,
            isSymlink: isSymlink,
            isHidden: name.hasPrefix("."),
            isAlias: false,
            isParent: false,
            size: size,
            modified: modified,
            created: nil,
            permissions: isDirectory ? "drwxr-xr-x" : permissions,
            kind: isDirectory ? "Folder in archive" : "File in archive",
            archive: ArchiveMember(archiveURL: archive, memberPath: memberPath, symlinkTarget: target)
        )
    }

    // MARK: Extraction

    /// Extracts `wanted` (nil = everything) into `destination`.
    /// `policy` decides what happens when the target already exists.
    @discardableResult
    static func extract(archive: URL,
                        entries: [ArchiveEntry],
                        wanted: Set<String>?,
                        destination: URL,
                        policy: ArchiveConflictPolicy = .replace,
                        onConflict: ((String) -> ArchiveConflictPolicy)? = nil,
                        progress: ((Int64, Int64, String) -> Void)? = nil,
                        cancelled: (() -> Bool)? = nil) throws -> ArchiveExtractResult {

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        let selected = selectionPlan(entries: entries, wanted: wanted)
        let totalBytes = selected.reduce(Int64(0)) { $0 + ($1.isDirectory ? 0 : $1.size) }

        var error = [CChar](repeating: 0, count: 512)
        let disk = error.withUnsafeMutableBufferPointer { buffer in
            tmac_disk_new(ArchiveService.secureExtractFlags, buffer.baseAddress, 512)
        }
        guard let disk else {
            throw ArchiveError.unsupported("Cannot create the extraction writer: \(String(cString: error))")
        }
        defer { _ = tmac_disk_close(disk, nil, 0) }

        let reader = try ArchiveReader(path: archive.path)
        defer { reader.close() }

        var result = ArchiveExtractResult()
        var buffer = [UInt8](repeating: 0, count: 256 * 1024)
        // Members we created as links, so we can refuse to write *through* them.
        var createdSymlinks: Set<String> = []

        while let entry = try reader.next() {
            if cancelled?() == true {
                result.cancelled = true
                break
            }
            guard selected.contains(where: { $0.path == entry.path }) else { continue }

            let relative = entry.path
            guard !relative.isEmpty else { continue }

            if hasSymlinkedAncestor(relative, symlinks: createdSymlinks) {
                result.skipped += 1
                continue
            }

            let target = destination.appendingPathComponent(relative)

            if isSymlinkOrExists(target, fileManager: fileManager) {
                let decision = onConflict?(relative) ?? policy
                switch decision {
                case .skip:
                    result.skipped += 1
                    continue
                case .keepBoth:
                    let unique = FileSystemService.uniqueURL(for: target)
                    try extractOne(entry: entry, reader: reader, disk: disk,
                                   target: unique, buffer: &buffer, progress: progress,
                                   totalBytes: totalBytes, result: &result)
                    continue
                case .replace:
                    try? fileManager.removeItem(at: target)
                }
            }

            if cancelled?() == true {
                result.cancelled = true
                break
            }

            try extractOne(entry: entry, reader: reader, disk: disk,
                           target: target, buffer: &buffer, progress: progress,
                           totalBytes: totalBytes, result: &result)

            if entry.isSymlink {
                createdSymlinks.insert(relative)
            }
        }

        return result
    }

    /// ARCHIVE_EXTRACT_SECURE_NODOTDOT: refuse to write to any path containing
    /// "..". (We deliberately do not use SECURE_SYMLINKS because macOS paths
    /// such as /var and /tmp are themselves symlinks.)
    static let secureExtractFlags: UInt64 = 0x0200

    private static func hasSymlinkedAncestor(_ path: String, symlinks: Set<String>) -> Bool {
        guard !symlinks.isEmpty else { return false }
        var components = path.split(separator: "/").map(String.init)
        guard components.count > 1 else { return false }
        components.removeLast()
        var prefix = ""
        for component in components {
            prefix = prefix.isEmpty ? component : prefix + "/" + component
            if symlinks.contains(prefix) { return true }
        }
        return false
    }

    private static func isSymlinkOrExists(_ url: URL, fileManager: FileManager) -> Bool {
        if fileManager.fileExists(atPath: url.path) { return true }
        // A dangling symlink reports as non-existent but still must be replaced.
        return (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private static func extractOne(entry: ArchiveEntry,
                                   reader: ArchiveReader,
                                   disk: UnsafeMutableRawPointer,
                                   target: URL,
                                   buffer: inout [UInt8],
                                   progress: ((Int64, Int64, String) -> Void)?,
                                   totalBytes: Int64,
                                   result: inout ArchiveExtractResult) throws {

        var error = [CChar](repeating: 0, count: 512)
        let filetype: UInt32 = entry.isDirectory ? TMAC_IFDIR : (entry.isSymlink ? TMAC_IFLNK : TMAC_IFREG)
        let permissionBits = permissionValue(from: entry.permissions)

        let mtime = Int64(entry.modified?.timeIntervalSince1970 ?? 0)

        let status = error.withUnsafeMutableBufferPointer { errorBuffer -> Int32 in
            target.path.withCString { cPath in
                if entry.isSymlink, let link = entry.symlinkTarget {
                    return link.withCString { cLink in
                        tmac_disk_write_entry(disk, cPath, filetype, permissionBits, 0, mtime,
                                              cLink, errorBuffer.baseAddress, 512)
                    }
                }
                return tmac_disk_write_entry(disk, cPath, filetype, permissionBits, entry.size, mtime,
                                             nil, errorBuffer.baseAddress, 512)
            }
        }

        if status < -20 {
            throw ArchiveError.unsupported("\(entry.path): \(String(cString: error))")
        }

        if !entry.isDirectory && !entry.isSymlink {
            var remaining = entry.size > 0 ? entry.size : Int64.max
            while remaining > 0 {
                let read = reader.read(into: &buffer)
                if read < 0 { throw ArchiveError.corrupt(entry.path) }
                if read == 0 { break }
                let chunk = buffer.withUnsafeBytes { raw -> Int32 in
                    tmac_disk_write_data(disk, raw.baseAddress, read)
                }
                if chunk < 0 { throw ArchiveError.unsupported("Cannot write \(entry.path)") }
                remaining -= Int64(read)
                result.bytes += Int64(read)
                progress?(result.bytes, totalBytes, entry.name)
            }
            result.files += 1
        } else if entry.isDirectory {
            result.files += 1
        } else {
            result.files += 1
        }

        _ = error.withUnsafeMutableBufferPointer { buffer in
            tmac_disk_finish_entry(disk, buffer.baseAddress, 512)
        }
    }

    private static func permissionValue(from posix: String) -> UInt32 {
        let characters = Array(posix)
        guard characters.count >= 10 else { return 0o644 }
        var value: UInt32 = 0
        let letters = ["r", "w", "x"]
        for (index, character) in characters.dropFirst().prefix(9).enumerated() {
            if letters.contains(String(character)) {
                value |= UInt32(1) << UInt32(8 - index)
            }
        }
        return value
    }

    /// Expands a set of wanted member paths so that directories imply their
    /// whole subtree, and returns the matching entries in archive order.
    private static func selectionPlan(entries: [ArchiveEntry], wanted: Set<String>?) -> [ArchiveEntry] {
        guard let wanted else { return entries }
        var prefixes = Set<String>()
        for path in wanted {
            prefixes.insert(path.hasSuffix("/") ? path : path + "/")
            prefixes.insert(path)
        }
        return entries.filter { entry in
            if wanted.contains(entry.path) { return true }
            for prefix in prefixes where entry.path.hasPrefix(prefix) { return true }
            return false
        }
    }


    // MARK: Creating and rewriting archives

    private struct PlannedItem {
        var url: URL
        var relative: String
        var isDirectory: Bool
        var isSymlink: Bool
        var linkTarget: String?
        var size: Int64
        var permissions: UInt32
        var mtime: Int64
    }

    /// Packs `sources` into a new archive. Each source keeps its own name as the
    /// top level folder inside the archive.
    @discardableResult
    static func create(archive: URL,
                       sources: [URL],
                       format: ArchiveFormat,
                       level: Int = 6,
                       progress: ((Int64, Int64, String) -> Void)? = nil,
                       cancelled: (() -> Bool)? = nil) throws -> ArchivePackResult {

        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: archive.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)

        var planned: [PlannedItem] = []
        for source in sources {
            guard source.standardizedFileURL.path != archive.standardizedFileURL.path else { continue }
            collectPlanned(source: source,
                           relative: source.lastPathComponent,
                           archivePath: archive.standardizedFileURL.path,
                           into: &planned)
        }

        var buffer = [UInt8](repeating: 0, count: 256 * 1024)
        var error = [CChar](repeating: 0, count: 512)
        guard let writer = openWriter(path: archive.path, format: format, level: level, error: &error) else {
            throw ArchiveError.unsupported("Cannot create the archive: \(String(cString: error))")
        }

        var result = ArchivePackResult()
        do {
            try writeItems(planned, to: writer, buffer: &buffer, progress: progress,
                           cancelled: cancelled, result: &result, error: &error)
        } catch {
            tmac_write_abort(writer)
            try? fileManager.removeItem(at: archive)
            throw error
        }

        let closed = closeWriter(writer, error: &error)
        if closed < -20 {
            try? fileManager.removeItem(at: archive)
            throw ArchiveError.unsupported("Cannot finish the archive: \(String(cString: error))")
        }
        if result.cancelled {
            try? fileManager.removeItem(at: archive)
        }
        return result
    }

    /// Rewrites an archive: members in `pathsToRemove` (and everything below a
    /// removed folder) are dropped, `additions` are inserted under `addingPrefix`.
    /// This is how deleting or copying *into* an archive is implemented.
    @discardableResult
    static func rewrite(archive: URL,
                        removing pathsToRemove: [String],
                        adding additions: [URL] = [],
                        addingPrefix: String = "",
                        format: ArchiveFormat? = nil,
                        level: Int = 6,
                        progress: ((Int64, Int64, String) -> Void)? = nil,
                        cancelled: (() -> Bool)? = nil) throws -> ArchivePackResult {

        guard format != nil || canRewrite(archive) else {
            throw ArchiveError.unsupported(
                "“\(archive.lastPathComponent)” cannot be modified. Only ZIP and TAR archives can be rewritten.")
        }

        let fileManager = FileManager.default
        let resolvedFormat = format ?? formatForFile(archive)
        let temporary = archive.deletingLastPathComponent()
            .appendingPathComponent(".totalmac-\(UUID().uuidString).\(resolvedFormat.fileExtension)")

        var removalPrefixes: Set<String> = []
        for path in pathsToRemove {
            removalPrefixes.insert(path)
            removalPrefixes.insert(path + "/")
        }
        func isRemoved(_ path: String) -> Bool { removalPrefixes.contains(path) }

        var plannedAdditions: [PlannedItem] = []
        for addition in additions {
            let prefix = addingPrefix.isEmpty ? "" : addingPrefix + "/"
            collectPlanned(source: addition,
                           relative: prefix + addition.lastPathComponent,
                           archivePath: archive.standardizedFileURL.path,
                           into: &plannedAdditions)
        }

        var buffer = [UInt8](repeating: 0, count: 256 * 1024)
        var error = [CChar](repeating: 0, count: 512)
        guard let writer = openWriter(path: temporary.path, format: resolvedFormat, level: level, error: &error) else {
            throw ArchiveError.unsupported("Cannot create the new archive: \(String(cString: error))")
        }

        var result = ArchivePackResult()

        func cleanup() {
            tmac_write_abort(writer)
            try? fileManager.removeItem(at: temporary)
        }

        do {
            // 1. copy the survivors straight through.
            let reader = try ArchiveReader(path: archive.path)
            defer { reader.close() }

            while let entry = try reader.next() {
                if cancelled?() == true {
                    result.cancelled = true
                    break
                }
                if isRemoved(entry.path) { continue }

                let filetype: UInt32 = entry.isDirectory ? TMAC_IFDIR : (entry.isSymlink ? TMAC_IFLNK : TMAC_IFREG)
                let name = entry.isDirectory ? entry.path + "/" : entry.path
                let permissions = permissionValue(from: entry.permissions)
                let mtime = Int64(entry.modified?.timeIntervalSince1970 ?? 0)

                let status = writeHeader(writer: writer, name: name, filetype: filetype,
                                         permissions: permissions, size: entry.size, mtime: mtime,
                                         symlink: entry.symlinkTarget, error: &error)
                if status < -20 {
                    cleanup()
                    throw ArchiveError.unsupported("\(entry.path): \(String(cString: error))")
                }

                if !entry.isDirectory && !entry.isSymlink {
                    var remaining = entry.size > 0 ? entry.size : Int64.max
                    while remaining > 0 {
                        let read = reader.read(into: &buffer)
                        if read <= 0 { break }
                        let written = buffer.withUnsafeBytes { raw -> Int32 in
                            tmac_write_data(writer, raw.baseAddress, read)
                        }
                        if written < 0 {
                            cleanup()
                            throw ArchiveError.unsupported("Cannot write \(entry.path)")
                        }
                        remaining -= Int64(read)
                        result.bytes += Int64(read)
                    }
                }
                result.files += 1
                _ = error.withUnsafeMutableBufferPointer { errorBuffer in
                    tmac_write_finish_entry(writer, errorBuffer.baseAddress, 512)
                }
            }

            // 2. append the new members.
            if !result.cancelled && !plannedAdditions.isEmpty {
                try writeItems(plannedAdditions, to: writer, buffer: &buffer, progress: progress,
                               cancelled: cancelled, result: &result, error: &error)
            }
        } catch {
            cleanup()
            throw error
        }

        let closed = closeWriter(writer, error: &error)
        if closed < -20 {
            try? fileManager.removeItem(at: temporary)
            throw ArchiveError.unsupported("Cannot finish the archive: \(String(cString: error))")
        }
        if result.cancelled {
            try? fileManager.removeItem(at: temporary)
            return result
        }

        // 3. swap the rewritten archive in.
        let backup = archive.deletingLastPathComponent()
            .appendingPathComponent(".totalmac-backup-\(UUID().uuidString)")
        do {
            try fileManager.moveItem(at: archive, to: backup)
            try fileManager.moveItem(at: temporary, to: archive)
            try? fileManager.removeItem(at: backup)
        } catch {
            if fileManager.fileExists(atPath: backup.path) {
                try? fileManager.moveItem(at: backup, to: archive)
            }
            try? fileManager.removeItem(at: temporary)
            throw ArchiveError.unsupported("Cannot replace the archive: \(error.localizedDescription)")
        }

        return result
    }

    // MARK: Archive writing internals

    private static func openWriter(path: String,
                                   format: ArchiveFormat,
                                   level: Int,
                                   error: inout [CChar]) -> UnsafeMutableRawPointer? {
        path.withCString { cPath in
            format.rawValue.withCString { cFormat in
                error.withUnsafeMutableBufferPointer { buffer in
                    tmac_write_new(cPath, cFormat, Int32(level), buffer.baseAddress, 512)
                }
            }
        }
    }

    private static func closeWriter(_ writer: UnsafeMutableRawPointer, error: inout [CChar]) -> Int32 {
        error.withUnsafeMutableBufferPointer { buffer in
            tmac_write_close(writer, buffer.baseAddress, 512)
        }
    }

    private static func writeHeader(writer: UnsafeMutableRawPointer,
                                    name: String,
                                    filetype: UInt32,
                                    permissions: UInt32,
                                    size: Int64,
                                    mtime: Int64,
                                    symlink: String?,
                                    error: inout [CChar]) -> Int32 {
        error.withUnsafeMutableBufferPointer { errorBuffer -> Int32 in
            name.withCString { cName in
                if let symlink, !symlink.isEmpty {
                    return symlink.withCString { cLink in
                        tmac_write_entry(writer, cName, filetype, permissions, 0, mtime,
                                         cLink, errorBuffer.baseAddress, 512)
                    }
                }
                return tmac_write_entry(writer, cName, filetype, permissions, size, mtime,
                                        nil, errorBuffer.baseAddress, 512)
            }
        }
    }

    private static func writeItems(_ items: [PlannedItem],
                                   to writer: UnsafeMutableRawPointer,
                                   buffer: inout [UInt8],
                                   progress: ((Int64, Int64, String) -> Void)?,
                                   cancelled: (() -> Bool)?,
                                   result: inout ArchivePackResult,
                                   error: inout [CChar]) throws {

        let fileManager = FileManager.default
        var total: Int64 = 0
        for item in items where !item.isDirectory && !item.isSymlink { total += item.size }

        for item in items {
            if cancelled?() == true {
                result.cancelled = true
                break
            }
            guard fileManager.fileExists(atPath: item.url.path) else { continue }

            let filetype: UInt32 = item.isDirectory ? TMAC_IFDIR : (item.isSymlink ? TMAC_IFLNK : TMAC_IFREG)
            let name = item.isDirectory ? item.relative + "/" : item.relative

            let status = writeHeader(writer: writer, name: name, filetype: filetype,
                                     permissions: item.permissions, size: item.size,
                                     mtime: item.mtime, symlink: item.linkTarget, error: &error)
            if status < -20 {
                throw ArchiveError.unsupported("\(item.relative): \(String(cString: error))")
            }

            if !item.isDirectory && !item.isSymlink {
                guard let input = InputStream(url: item.url) else {
                    throw ArchiveError.unsupported("Cannot read \(item.relative)")
                }
                input.open()
                defer { input.close() }
                while input.hasBytesAvailable {
                    if cancelled?() == true {
                        result.cancelled = true
                        break
                    }
                    let read = buffer.withUnsafeMutableBytes { raw -> Int in
                        input.read(raw.bindMemory(to: UInt8.self).baseAddress!, maxLength: raw.count)
                    }
                    if read <= 0 { break }
                    let written = buffer.withUnsafeBytes { raw -> Int32 in
                        tmac_write_data(writer, raw.baseAddress, read)
                    }
                    if written < 0 { throw ArchiveError.unsupported("Cannot write \(item.relative)") }
                    result.bytes += Int64(read)
                    progress?(result.bytes, total, item.relative)
                }
            }
            result.files += 1
            _ = error.withUnsafeMutableBufferPointer { errorBuffer in
                tmac_write_finish_entry(writer, errorBuffer.baseAddress, 512)
            }
        }
    }

    private static func collectPlanned(source: URL,
                                       relative: String,
                                       archivePath: String,
                                       into planned: inout [PlannedItem]) {
        let fileManager = FileManager.default
        if source.standardizedFileURL.path == archivePath { return }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory) else { return }

        let isSymlink = (try? source.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
        let attributes = try? fileManager.attributesOfItem(atPath: source.path)
        let permissions = (attributes?[.posixPermissions] as? NSNumber)?.uint32Value
            ?? (isDirectory.boolValue ? 0o755 : 0o644)
        let mtime = Int64((attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)

        if isSymlink {
            let target = try? fileManager.destinationOfSymbolicLink(atPath: source.path)
            planned.append(PlannedItem(url: source, relative: relative, isDirectory: false,
                                       isSymlink: true, linkTarget: target, size: 0,
                                       permissions: permissions, mtime: mtime))
            return
        }

        if !isDirectory.boolValue {
            let size = Int64((try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            planned.append(PlannedItem(url: source, relative: relative, isDirectory: false,
                                       isSymlink: false, linkTarget: nil, size: size,
                                       permissions: permissions, mtime: mtime))
            return
        }

        planned.append(PlannedItem(url: source, relative: relative, isDirectory: true,
                                   isSymlink: false, linkTarget: nil, size: 0,
                                   permissions: permissions, mtime: mtime))

        guard let children = try? fileManager.contentsOfDirectory(at: source,
                                                                  includingPropertiesForKeys: nil,
                                                                  options: []) else { return }
        for child in children.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            collectPlanned(source: child,
                           relative: relative + "/" + child.lastPathComponent,
                           archivePath: archivePath,
                           into: &planned)
        }
    }

    static func formatForFile(_ url: URL) -> ArchiveFormat {
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") { return .tarGz }
        if name.hasSuffix(".tar") { return .tar }
        return .zip
    }

    /// True for archives we can rebuild (as opposed to read-only formats such
    /// as 7z, RAR or ISO).
    static func canRewrite(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return name.hasSuffix(".zip")
            || name.hasSuffix(".tar")
            || name.hasSuffix(".tar.gz")
            || name.hasSuffix(".tgz")
            || name.hasSuffix(".tar.bz2")
            || name.hasSuffix(".tar.xz")
    }
}

enum ArchiveConflictPolicy {
    case replace
    case skip
    case keepBoth
}
