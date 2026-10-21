import Foundation

/// Identifies a row that lives inside an archive instead of on disk.
struct ArchiveMember: Hashable {
    var archiveURL: URL
    var memberPath: String
    var symlinkTarget: String?

    var displayPath: String { archiveURL.path + "/" + memberPath }
}

/// One row in a file panel. Mirrors the information Total Commander shows in its
/// columns: name, extension, size, date and a compact attribute string.
struct FileItem: Identifiable, Hashable {

    let url: URL
    let name: String
    /// True for real directories. Symlinks pointing at directories are *not*
    /// treated as directories so that recursive operations never loop.
    let isDirectory: Bool
    /// True for macOS bundles (`.app`, `.rtfd`, ...) which we treat as folders.
    let isPackage: Bool
    let isSymlink: Bool
    let isHidden: Bool
    let isAlias: Bool
    /// The synthetic `..` entry at the top of every listing.
    let isParent: Bool

    let size: Int64
    let modified: Date?
    let created: Date?
    /// `rwxr-xr-x` style permissions.
    let permissions: String
    /// Human readable type, e.g. `PNG image` or `Folder`.
    let kind: String
    /// Set when this row is a member of an archive rather than a real file.
    var archive: ArchiveMember? = nil

    var id: String { isParent ? url.path + "/\u{0}.." : (archive?.displayPath ?? url.path) }

    var isArchiveMember: Bool { archive != nil }

    var ext: String {
        if isParent { return "" }
        if isDirectory { return "<DIR>" }
        let e = url.pathExtension
        return e.isEmpty ? "" : e.uppercased()
    }

    /// Total Commander style attribute column: `d-a--` etc.
    var attr: String {
        var s = ""
        s.append(isDirectory ? "d" : (isSymlink ? "l" : "-"))
        s.append(isDirectory ? "-" : "a")   // archive bit
        s.append(ownerCanWrite ? "-" : "r") // read-only
        s.append(isHidden ? "h" : "-")
        s.append(isSymlink ? "s" : "-")
        if isAlias { s.append("i") }
        return s
    }

    private var ownerCanWrite: Bool {
        let chars = Array(permissions)
        return chars.count > 2 && chars[2] == "w"
    }

    var formattedSize: String {
        if isParent { return "" }
        if isDirectory { return "<DIR>" }
        return ByteFormatter.string(size)
    }

    var tooltip: String {
        if isParent { return "Parent directory" }
        var lines = ["Name: \(name)", "Full path: \(url.path)", "Type: \(kind)"]
        if !isDirectory {
            lines.append("Size: \(size) bytes (\(ByteFormatter.string(size)))")
        }
        if let modified { lines.append("Modified: \(DateFormatter.long(modified))") }
        if let created { lines.append("Created: \(DateFormatter.long(created))") }
        lines.append("Permissions: \(permissions)")
        lines.append("Attribute: \(attr)")
        if isSymlink, let target = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) {
            lines.append("Symlink target: \(target)")
        }
        return lines.joined(separator: "\n")
    }
}

enum ByteFormatter {
    private static let units = ["B", "K", "M", "G", "T", "P"]

    static func string(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes)" }
        var value = Double(bytes)
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        let fractionDigits = value < 10 ? 1 : 0
        return String(format: "%.\(fractionDigits)f %@", value, units[index])
    }

    /// `12 345` style grouping, used where exact byte counts are wanted.
    static func grouped(_ bytes: Int64) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = " "
        return f.string(from: NSNumber(value: bytes)) ?? "\(bytes)"
    }
}

extension DateFormatter {
    static let mediumFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    static let shortFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd/MM/yy HH:mm"
        return f
    }()

    static let longFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .medium
        return f
    }()

    static func medium(_ date: Date) -> String { mediumFormatter.string(from: date) }
    static func short(_ date: Date) -> String { shortFormatter.string(from: date) }
    static func long(_ date: Date) -> String { longFormatter.string(from: date) }
}
