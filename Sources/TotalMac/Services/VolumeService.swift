import Foundation
import AppKit

/// A mounted filesystem, i.e. what Total Commander calls a "drive".
struct Volume: Identifiable, Hashable {

    var url: URL
    var name: String
    var isRemovable: Bool
    var isEjectable: Bool
    var isInternal: Bool
    var isReadOnly: Bool
    var freeSpace: Int64?
    var totalSpace: Int64?

    var id: String { url.path }

    var isRoot: Bool { url.path == "/" }

    /// External / removable media: this is what people want quick access to.
    var isExternal: Bool { isRemovable || (!isInternal && !isRoot) }

    var displayName: String {
        if isRoot { return name.isEmpty ? "Computer" : name }
        return name.isEmpty ? url.lastPathComponent : name
    }

    var subtitle: String {
        if isReadOnly { return "read only" }
        if isRoot { return "startup disk" }
        if isRemovable { return "removable" }
        if isExternal { return "external" }
        return "volume"
    }

    var capacityText: String {
        guard let freeSpace, let totalSpace, totalSpace > 0 else { return "" }
        return "\(ByteFormatter.string(freeSpace)) free of \(ByteFormatter.string(totalSpace))"
    }

    var symbolName: String {
        if isRoot { return "internaldrive" }
        if isRemovable { return "externaldrive.fill" }
        if isExternal { return "externaldrive" }
        return "internaldrive"
    }

    var icon: NSImage {
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: 16, height: 16)
        return image
    }
}

enum VolumeService {

    private static let keys: [URLResourceKey] = [
        .volumeNameKey,
        .volumeLocalizedNameKey,
        .volumeIsRemovableKey,
        .volumeIsEjectableKey,
        .volumeIsInternalKey,
        .volumeIsReadOnlyKey,
        .volumeAvailableCapacityForImportantUsageKey,
        .volumeTotalCapacityKey,
        .isVolumeKey
    ]

    /// Every mounted volume, startup disk first, then external media, then the rest.
    static func mountedVolumes() -> [Volume] {
        let fileManager = FileManager.default
        var urls = fileManager.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                 options: [.skipHiddenVolumes]) ?? []

        let root = URL(fileURLWithPath: "/")
        if !urls.contains(where: { $0.path == "/" }) {
            urls.insert(root, at: 0)
        }

        // Some network and disk images only show up as mount points.
        let volumesFolder = URL(fileURLWithPath: "/Volumes")
        if let children = try? fileManager.contentsOfDirectory(at: volumesFolder,
                                                               includingPropertiesForKeys: keys,
                                                               options: [.skipsHiddenFiles]) {
            for child in children where !urls.contains(where: { $0.path == child.path }) {
                guard (try? child.resourceValues(forKeys: [.isVolumeKey]).isVolume) == true else { continue }
                urls.append(child)
            }
        }

        let volumes = urls.compactMap { makeVolume(url: $0, fileManager: fileManager) }
        return sorted(volumes)
    }

    /// Startup disk first, then external media, then everything else, each
    /// alphabetically — so a plugged-in USB drive is one click away.
    static func sorted(_ volumes: [Volume]) -> [Volume] {
        volumes.sorted { a, b in
            if a.isRoot != b.isRoot { return a.isRoot }
            if a.isExternal != b.isExternal { return a.isExternal }
            return a.displayName.localizedStandardCompare(b.displayName) == .orderedAscending
        }
    }

    private static func makeVolume(url: URL, fileManager: FileManager) -> Volume? {
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
        let name = values.volumeLocalizedName ?? values.volumeName ?? url.lastPathComponent
        return Volume(
            url: url,
            name: name,
            isRemovable: values.volumeIsRemovable ?? false,
            isEjectable: values.volumeIsEjectable ?? false,
            isInternal: values.volumeIsInternal ?? (url.path == "/"),
            isReadOnly: values.volumeIsReadOnly ?? false,
            freeSpace: values.volumeAvailableCapacityForImportantUsage,
            totalSpace: values.volumeTotalCapacity.map(Int64.init)
        )
    }

    /// Unmounts and ejects the volume (used for external drives).
    static func eject(_ volume: Volume) throws {
        try NSWorkspace.shared.unmountAndEjectDevice(at: volume.url)
    }

    /// True when the pane's folder lives on this volume.
    static func contains(_ volume: Volume, path: String) -> Bool {
        let volumePath = volume.url.standardizedFileURL.path
        let candidate = URL(fileURLWithPath: path).standardizedFileURL.path
        if volumePath == "/" { return true }
        return candidate == volumePath || candidate.hasPrefix(volumePath + "/")
    }

    /// The volume a path lives on, longest match wins.
    static func volume(for path: String, in volumes: [Volume]) -> Volume? {
        volumes
            .filter { contains($0, path: path) }
            .max { $0.url.path.count < $1.url.path.count }
    }
}
