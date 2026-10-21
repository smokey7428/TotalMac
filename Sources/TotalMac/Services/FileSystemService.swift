import Foundation
import AppKit
import UniformTypeIdentifiers

enum SortKey: String, CaseIterable, Identifiable {
    case name, ext, size, modified, created, kind, attr

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: return "Name"
        case .ext: return "Ext"
        case .size: return "Size"
        case .modified: return "Date"
        case .created: return "Created"
        case .kind: return "Kind"
        case .attr: return "Attr"
        }
    }
}

struct SortSpec: Equatable {
    var key: SortKey = .name
    var ascending: Bool = true
}

/// Stateless filesystem helpers shared by the panels.
enum FileSystemService {

    static let resourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey, .isPackageKey,
        .fileSizeKey, .contentModificationDateKey, .creationDateKey,
        .isRegularFileKey, .isAliasFileKey, .nameKey, .volumeIdentifierKey
    ]

    // MARK: - Listing

    static func list(_ directory: URL, showHidden: Bool) throws -> [FileItem] {
        let fm = FileManager.default
        let options: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]
        let urls = try fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(resourceKeys),
            options: options
        )

        var items: [FileItem] = []
        items.reserveCapacity(urls.count + 1)

        for url in urls {
            if let item = makeItem(url: url) {
                items.append(item)
            }
        }
        if let parent = parentItem(for: directory) {
            items.insert(parent, at: 0)
        }
        return items
    }

    static func parentItem(for directory: URL) -> FileItem? {
        let parent = directory.deletingLastPathComponent()
        let standardized = directory.standardizedFileURL.path
        let parentPath = parent.standardizedFileURL.path
        guard parentPath != standardized, !parentPath.isEmpty else { return nil }
        return FileItem(
            url: parent,
            name: "..",
            isDirectory: true,
            isPackage: false,
            isSymlink: false,
            isHidden: false,
            isAlias: false,
            isParent: true,
            size: 0,
            modified: nil,
            created: nil,
            permissions: "drwxr-xr-x",
            kind: "Parent directory"
        )
    }

    static func makeItem(url: URL) -> FileItem? {
        guard let values = try? url.resourceValues(forKeys: resourceKeys) else { return nil }

        let isSymlink = values.isSymbolicLink ?? false
        let isPackage = values.isPackage ?? false
        let isDir = (values.isDirectory ?? false) || isPackage
        let isHidden = values.isHidden ?? false
        let isAlias = values.isAliasFile ?? false
        let name = values.name ?? url.lastPathComponent

        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let rawMode = (attributes?[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
        let permissions = posixString(rawMode, ownerIsDirectory: isDir)

        let size: Int64 = isDir ? 0 : Int64(values.fileSize ?? 0)

        return FileItem(
            url: url,
            name: name,
            isDirectory: isDir && !isSymlink,
            isPackage: isPackage,
            isSymlink: isSymlink,
            isHidden: isHidden,
            isAlias: isAlias,
            isParent: false,
            size: size,
            modified: values.contentModificationDate,
            created: values.creationDate,
            permissions: permissions,
            kind: kindDescription(url: url, isDirectory: isDir, isPackage: isPackage, isSymlink: isSymlink)
        )
    }

    static func posixString(_ mode: UInt16, ownerIsDirectory: Bool) -> String {
        let bits = Int(mode)
        var result = ownerIsDirectory ? "d" : "-"
        let letters = ["r", "w", "x"]
        for group in [6, 3, 0] {
            for offset in [2, 1, 0] {
                let set = (bits >> (group + offset)) & 1 == 1
                result += set ? letters[2 - offset] : "-"
            }
        }
        return result
    }

    static func kindDescription(url: URL, isDirectory: Bool, isPackage: Bool, isSymlink: Bool) -> String {
        if isSymlink { return "Symbolic link" }
        if isPackage { return "Bundle" }
        if isDirectory { return "Folder" }
        if url.lastPathComponent.hasPrefix(".") { return "Hidden file" }
        if let type = UTType(filenameExtension: url.pathExtension) {
            return type.localizedDescription ?? "Document"
        }
        return url.pathExtension.isEmpty ? "Document" : "\(url.pathExtension.uppercased()) file"
    }

    // MARK: - Sorting & filtering

    static func process(_ items: [FileItem], spec: SortSpec, filter: String) -> [FileItem] {
        var parent: FileItem?
        var rest: [FileItem] = []
        rest.reserveCapacity(items.count)

        for item in items {
            if item.isParent {
                parent = item
            } else if matches(item, filter: filter) {
                rest.append(item)
            }
        }

        let directories = rest.filter { $0.isDirectory }
        let files = rest.filter { !$0.isDirectory }

        var result = sortGroup(directories, spec: spec)
        result.append(contentsOf: sortGroup(files, spec: spec))
        if let parent { result.insert(parent, at: 0) }
        return result
    }

    private static func sortGroup(_ items: [FileItem], spec: SortSpec) -> [FileItem] {
        items.sorted { a, b in
            let order = compare(a, b, key: spec.key)
            return spec.ascending ? order == .orderedAscending : order == .orderedDescending
        }
    }

    static func compare(_ a: FileItem, _ b: FileItem, key: SortKey) -> ComparisonResult {
        switch key {
        case .name:
            return a.name.localizedStandardCompare(b.name)
        case .ext:
            let r = a.ext.localizedStandardCompare(b.ext)
            return r == .orderedSame ? a.name.localizedStandardCompare(b.name) : r
        case .size:
            if a.size == b.size { return a.name.localizedStandardCompare(b.name) }
            return a.size < b.size ? .orderedAscending : .orderedDescending
        case .modified:
            return compareDates(a.modified, b.modified, tieBreak: a.name, other: b.name)
        case .created:
            return compareDates(a.created, b.created, tieBreak: a.name, other: b.name)
        case .kind:
            let r = a.kind.localizedStandardCompare(b.kind)
            return r == .orderedSame ? a.name.localizedStandardCompare(b.name) : r
        case .attr:
            let r = a.attr.localizedStandardCompare(b.attr)
            return r == .orderedSame ? a.name.localizedStandardCompare(b.name) : r
        }
    }

    private static func compareDates(_ a: Date?, _ b: Date?, tieBreak: String, other: String) -> ComparisonResult {
        let da = a ?? .distantPast
        let db = b ?? .distantPast
        if da == db { return tieBreak.localizedStandardCompare(other) }
        return da < db ? .orderedAscending : .orderedDescending
    }

    /// Empty filter matches everything. `*` and `?` act as wildcards; multiple
    /// patterns may be separated with `;` or `,`. Without a wildcard the filter
    /// behaves as a case insensitive substring match.
    static func matches(_ item: FileItem, filter: String) -> Bool {
        matchesMask(item.name, mask: filter)
    }

    static func matchesMask(_ name: String, mask: String) -> Bool {
        let patterns = mask.split(whereSeparator: { $0 == ";" || $0 == "," }).map(String.init)
        if patterns.isEmpty { return true }
        for pattern in patterns where matchesSingleMask(name, mask: pattern) {
            return true
        }
        return false
    }

    private static func matchesSingleMask(_ name: String, mask: String) -> Bool {
        let pattern = mask.trimmingCharacters(in: .whitespaces)
        if pattern.isEmpty { return true }
        let hasWildcard = pattern.contains("*") || pattern.contains("?")
        if !hasWildcard {
            return name.range(of: pattern, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        let regex = wildcardRegex(pattern)
        return name.range(of: regex, options: [.regularExpression, .caseInsensitive, .diacriticInsensitive]) != nil
    }

    private static func wildcardRegex(_ mask: String) -> String {
        var out = "^"
        for character in mask {
            switch character {
            case "*": out += ".*"
            case "?": out += "."
            default: out += NSRegularExpression.escapedPattern(for: String(character))
            }
        }
        return out + "$"
    }

    /// Suggests a non-colliding name inside `directory` by appending " 2", " 3", ...
    static func uniqueURL(for url: URL, in directory: URL? = nil) -> URL {
        let folder = directory ?? url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        let fm = FileManager.default

        var candidate = url
        var counter = 2
        while fm.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            candidate = folder.appendingPathComponent(name)
            counter += 1
            if counter > 9999 { break }
        }
        return candidate
    }

    // MARK: - Measuring

    /// Recursively totals the byte size and file count of `url`.
    /// When `shouldStop` returns true the walk aborts early.
    static func measure(_ url: URL,
                        progress: ((Int64, Int) -> Void)? = nil,
                        shouldStop: @escaping () -> Bool = { false }) -> (bytes: Int64, files: Int) {
        var bytes: Int64 = 0
        var files = 0
        let fm = FileManager.default

        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return (0, 0) }

        if !isDirectory.boolValue {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return (Int64(size), 1)
        }

        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: keys,
                                             options: [], errorHandler: { _, _ in true }) else {
            return (0, 0)
        }
        var seen = 0
        for case let child as URL in enumerator {
            if shouldStop() { break }
            seen += 1
            if seen % 256 == 0 { progress?(bytes, files) }
            guard let values = try? child.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            if values.isDirectory == true { continue }
            bytes += Int64(values.fileSize ?? 0)
            files += 1
        }
        progress?(bytes, files)
        return (bytes, files)
    }

    static func freeSpace(at url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]) else {
            return nil
        }
        return values.volumeAvailableCapacityForImportantUsage
    }

    /// Same filesystem test, used to decide drag & drop semantics and fast renames.
    /// Compares `st_dev`, exactly like `rename(2)` does, so a cross device move can
    /// never be mistaken for a rename.
    static func isSameVolume(_ a: URL, _ b: URL) -> Bool {
        guard let deviceA = deviceID(of: a), let deviceB = deviceID(of: b) else { return false }
        return deviceA == deviceB
    }

    private static func deviceID(of url: URL) -> dev_t? {
        var info = stat()
        if url.path.withCString({ stat($0, &info) }) == 0 {
            return info.st_dev
        }
        // The destination may not exist yet: its folder decides.
        let parent = url.deletingLastPathComponent()
        guard parent.path != url.path,
              parent.path.withCString({ stat($0, &info) }) == 0 else { return nil }
        return info.st_dev
    }
}
