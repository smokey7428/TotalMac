import Foundation
import AppKit

// MARK: - Model

enum SyncStatus: String, CaseIterable {
    case identical = "identical"
    case leftOnly = "only in left"
    case rightOnly = "only in right"
    case leftNewer = "left is newer"
    case rightNewer = "right is newer"
    case sizeDiffers = "size differs"
    case contentDiffers = "content differs"
    case typeDiffers = "type differs"

    var isDifferent: Bool { self != .identical }

    var shortName: String {
        switch self {
        case .identical: return "same"
        case .leftOnly: return "left only"
        case .rightOnly: return "right only"
        case .leftNewer: return "left newer"
        case .rightNewer: return "right newer"
        case .sizeDiffers: return "size"
        case .contentDiffers: return "content"
        case .typeDiffers: return "type"
        }
    }

    var color: NSColor {
        switch self {
        case .identical: return .secondaryLabelColor
        case .leftOnly: return .systemBlue
        case .rightOnly: return .systemOrange
        case .leftNewer: return .systemGreen
        case .rightNewer: return .systemPurple
        case .sizeDiffers, .contentDiffers: return .systemRed
        case .typeDiffers: return .systemPink
        }
    }
}

enum SyncDirection: String, CaseIterable {
    case none
    case leftToRight
    case rightToLeft
    case deleteLeft
    case deleteRight

    var symbol: String {
        switch self {
        case .none: return "equal"
        case .leftToRight: return "arrow.right"
        case .rightToLeft: return "arrow.left"
        case .deleteLeft: return "trash"
        case .deleteRight: return "trash"
        }
    }

    var label: String {
        switch self {
        case .none: return "No action"
        case .leftToRight: return "Copy left → right"
        case .rightToLeft: return "Copy right → left"
        case .deleteLeft: return "Delete on the left"
        case .deleteRight: return "Delete on the right"
        }
    }

    var isDeletion: Bool { self == .deleteLeft || self == .deleteRight }
}

struct SyncRow: Identifiable, Hashable {
    var relativePath: String
    var name: String
    var isDirectory: Bool
    var left: FileItem?
    var right: FileItem?
    var status: SyncStatus
    var direction: SyncDirection = .none

    var id: String { relativePath }

    var leftSizeText: String { left.map { $0.isDirectory ? "<DIR>" : ByteFormatter.string($0.size) } ?? "" }
    var rightSizeText: String { right.map { $0.isDirectory ? "<DIR>" : ByteFormatter.string($0.size) } ?? "" }
    var leftDateText: String { left?.modified.map { DateFormatter.short($0) } ?? "" }
    var rightDateText: String { right?.modified.map { DateFormatter.short($0) } ?? "" }
}

// MARK: - Service

enum SyncService {

    struct Options {
        var includeSubdirectories = true
        var compareByContent = false
        var includeHidden = true
        var onlyDifferences = true
        /// `;` separated wildcards; empty means everything.
        var mask = ""
    }

    struct Result {
        var rows: [SyncRow]
        var leftFiles = 0
        var rightFiles = 0
        var different = 0
    }

    static func compare(left: URL,
                        right: URL,
                        options: Options,
                        progress: ((Int, String) -> Void)? = nil,
                        cancelled: () -> Bool = { false }) -> Result {

        var result = Result(rows: [])

        let leftEntries = walk(left, includeHidden: options.includeHidden,
                               recursive: options.includeSubdirectories,
                               progress: progress, cancelled: cancelled)
        let rightEntries = walk(right, includeHidden: options.includeHidden,
                                recursive: options.includeSubdirectories,
                                progress: progress, cancelled: cancelled)

        result.leftFiles = leftEntries.count
        result.rightFiles = rightEntries.count

        let leftMap = Dictionary(leftEntries.map { ($0.relative, $0) }, uniquingKeysWith: { first, _ in first })
        let rightMap = Dictionary(rightEntries.map { ($0.relative, $0) }, uniquingKeysWith: { first, _ in first })

        var keys = Set(leftMap.keys).union(rightMap.keys)
        if !options.mask.trimmingCharacters(in: .whitespaces).isEmpty {
            keys = keys.filter { FileSystemService.matchesMask(($0 as NSString).lastPathComponent, mask: options.mask) }
        }

        let sortedKeys = keys.sorted { a, b in
            let depthA = a.filter { $0 == "/" }.count
            let depthB = b.filter { $0 == "/" }.count
            if depthA != depthB { return depthA < depthB }
            return a.localizedStandardCompare(b) == .orderedAscending
        }

        var rows: [SyncRow] = []
        var checked = 0
        for key in sortedKeys {
            if cancelled() { break }
            checked += 1
            if let progress, checked % 64 == 0 { progress(checked, key) }

            let leftURL = leftMap[key]?.url
            let rightURL = rightMap[key]?.url

            if leftURL == nil && rightURL == nil { continue }

            var status: SyncStatus
            let isDirectory = (leftMap[key]?.isDirectory ?? false) || (rightMap[key]?.isDirectory ?? false)

            if let leftURL, rightURL == nil {
                status = .leftOnly
                _ = leftURL
            } else if rightURL != nil, leftURL == nil {
                status = .rightOnly
            } else if let leftURL, let rightURL {
                let leftItem = FileSystemService.makeItem(url: leftURL)
                let rightItem = FileSystemService.makeItem(url: rightURL)
                if leftItem?.isDirectory != rightItem?.isDirectory {
                    status = .typeDiffers
                } else if isDirectory {
                    status = .identical
                } else {
                    status = compareFiles(leftURL, rightURL, options: options)
                }
                _ = leftItem
            } else {
                continue
            }

            if options.onlyDifferences && !status.isDifferent { continue }

            rows.append(SyncRow(
                relativePath: key,
                name: (key as NSString).lastPathComponent,
                isDirectory: isDirectory,
                left: leftURL.flatMap { FileSystemService.makeItem(url: $0) },
                right: rightURL.flatMap { FileSystemService.makeItem(url: $0) },
                status: status,
                direction: .none
            ))
        }

        result.rows = rows
        result.different = rows.count
        return result
    }

    private struct WalkedEntry {
        var relative: String
        var url: URL
        var isDirectory: Bool
    }

    private static func walk(_ root: URL,
                             includeHidden: Bool,
                             recursive: Bool,
                             progress: ((Int, String) -> Void)?,
                             cancelled: () -> Bool) -> [WalkedEntry] {

        var entries: [WalkedEntry] = []
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey]

        func descend(_ directory: URL, prefix: String, depth: Int) {
            guard let children = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: keys,
                options: includeHidden ? [] : [.skipsHiddenFiles]) else { return }

            for child in children {
                if cancelled() { return }
                guard let values = try? child.resourceValues(forKeys: Set(keys)) else { continue }
                let isDirectory = values.isDirectory ?? false
                let isSymlink = values.isSymbolicLink ?? false
                let relative = prefix.isEmpty ? child.lastPathComponent : prefix + "/" + child.lastPathComponent
                entries.append(WalkedEntry(relative: relative, url: child,
                                           isDirectory: isDirectory && !isSymlink))
                if depth == 0, recursive, isDirectory, !isSymlink {
                    descend(child, prefix: relative, depth: depth + 1)
                }
            }
        }

        descend(root, prefix: "", depth: 0)
        progress?(entries.count, root.lastPathComponent)
        return entries
    }

    static func compareFiles(_ left: URL, _ right: URL, options: Options) -> SyncStatus {
        let leftSize = (try? left.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let rightSize = (try? right.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if leftSize != rightSize { return .sizeDiffers }

        if options.compareByContent {
            return contentsEqual(left, right) ? .identical : .contentDiffers
        }

        let leftDate = (try? left.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        let rightDate = (try? right.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        if abs(leftDate.timeIntervalSince(rightDate)) < 1 { return .identical }
        return leftDate > rightDate ? .leftNewer : .rightNewer
    }

    /// Chunked byte comparison so huge files do not blow up memory.
    static func contentsEqual(_ left: URL, _ right: URL) -> Bool {
        guard let leftHandle = try? FileHandle(forReadingFrom: left),
              let rightHandle = try? FileHandle(forReadingFrom: right) else { return false }
        defer {
            try? leftHandle.close()
            try? rightHandle.close()
        }
        let chunk = 256 * 1024
        while true {
            let leftData = (try? leftHandle.read(upToCount: chunk)) ?? Data()
            let rightData = (try? rightHandle.read(upToCount: chunk)) ?? Data()
            if leftData != rightData { return false }
            if leftData.isEmpty && rightData.isEmpty { return true }
        }
    }

    // MARK: Executing

    static func execute(rows: [SyncRow],
                        left: URL,
                        right: URL,
                        context: TransferContext,
                        progress: ((Int64, Int64, String) -> Void)? = nil) {

        let fileManager = FileManager.default
        let actionable = rows.filter { $0.direction != .none }
        var coveredPrefixes: [String] = []

        // Folder rows win: anything below a folder we already moved is skipped.
        for row in actionable.sorted(by: { $0.relativePath.count < $1.relativePath.count }) {
            if context.cancelled { return }
            if coveredPrefixes.contains(where: { row.relativePath.hasPrefix($0 + "/") }) { continue }

            let leftURL = left.appendingPathComponent(row.relativePath)
            let rightURL = right.appendingPathComponent(row.relativePath)

            switch row.direction {
            case .none:
                continue
            case .leftToRight:
                guard fileManager.fileExists(atPath: leftURL.path) else { continue }
                TransferEngine.transfer(source: leftURL,
                                        destination: rightURL,
                                        move: false,
                                        context: context)
            case .rightToLeft:
                guard fileManager.fileExists(atPath: rightURL.path) else { continue }
                TransferEngine.transfer(source: rightURL,
                                        destination: leftURL,
                                        move: false,
                                        context: context)
            case .deleteLeft:
                if fileManager.fileExists(atPath: leftURL.path) {
                    try? fileManager.removeItem(at: leftURL)
                    context.filesDone += 1
                }
            case .deleteRight:
                if fileManager.fileExists(atPath: rightURL.path) {
                    try? fileManager.removeItem(at: rightURL)
                    context.filesDone += 1
                }
            }

            if row.isDirectory {
                coveredPrefixes.append(row.relativePath)
            }
            progress?(context.bytesDone, context.bytesTotal, row.relativePath)
        }
    }
}
