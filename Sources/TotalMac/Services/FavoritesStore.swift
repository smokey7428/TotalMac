import Foundation
import AppKit
import Combine

/// One entry in the favorites list: either a folder (with a path) or a group
/// that can hold other entries — Total Commander's "Directory hotlist".
struct FavoriteItem: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var title: String
    var path: String = ""
    var isGroup: Bool = false
    var children: [FavoriteItem] = []

    var url: URL? {
        guard !isGroup, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    var exists: Bool {
        guard let url else { return true }
        return FileManager.default.fileExists(atPath: url.path)
    }

    static func folder(_ title: String, _ path: String) -> FavoriteItem {
        FavoriteItem(title: title, path: path)
    }

    static func group(_ title: String, _ children: [FavoriteItem] = []) -> FavoriteItem {
        FavoriteItem(title: title, isGroup: true, children: children)
    }
}

/// A favourite flattened for display (depth drives the indentation).
struct FavoriteRow: Identifiable, Hashable {
    var id: UUID
    var title: String
    var path: String
    var isGroup: Bool
    var depth: Int
}

/// Persists the favorites in `~/Library/Application Support/TotalMac/favorites.json`.
@MainActor
final class FavoritesStore: ObservableObject {

    @Published private(set) var items: [FavoriteItem] = []

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
            self.fileURL = base
                .appendingPathComponent("TotalMac", isDirectory: true)
                .appendingPathComponent("favorites.json")
        }
        load()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([FavoriteItem].self, from: data),
              !decoded.isEmpty else {
            items = Self.seed()
            save()
            return
        }
        items = decoded
    }

    func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(items)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("TotalMac: could not write favorites: \(error.localizedDescription)")
        }
    }

    /// A sensible starting list the first time the app runs.
    static func seed() -> [FavoriteItem] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            .group("Quick Access", [
                .folder("Home", home),
                .folder("Desktop", home + "/Desktop"),
                .folder("Documents", home + "/Documents"),
                .folder("Downloads", home + "/Downloads"),
                .folder("Pictures", home + "/Pictures")
            ]),
            .folder("Applications", "/Applications"),
            .folder("Utilities", "/Applications/Utilities"),
            .folder("Computer", "/"),
            .folder("Volumes", "/Volumes"),
            .group("Projects", [])
        ]
    }

    // MARK: - Queries

    func flattened() -> [FavoriteRow] {
        var rows: [FavoriteRow] = []
        func walk(_ nodes: [FavoriteItem], depth: Int) {
            for node in nodes {
                rows.append(FavoriteRow(id: node.id, title: node.title, path: node.path,
                                        isGroup: node.isGroup, depth: depth))
                if node.isGroup { walk(node.children, depth: depth + 1) }
            }
        }
        walk(items, depth: 0)
        return rows
    }

    func item(id: UUID) -> FavoriteItem? {
        func find(_ nodes: [FavoriteItem]) -> FavoriteItem? {
            for node in nodes {
                if node.id == id { return node }
                if let found = find(node.children) { return found }
            }
            return nil
        }
        return find(items)
    }

    /// True when the item or one of its ancestors is a group.
    func parentGroupID(of id: UUID) -> UUID? {
        func find(_ nodes: [FavoriteItem], parent: UUID?) -> UUID? {
            for node in nodes {
                if node.id == id { return parent }
                if let found = find(node.children, parent: node.isGroup ? node.id : parent) { return found }
            }
            return nil
        }
        return find(items, parent: nil)
    }

    // MARK: - Mutation

    private func mutate(_ body: (inout [FavoriteItem]) -> Bool) {
        var updated = items
        if body(&updated) {
            items = updated
            save()
        }
    }

    @discardableResult
    func add(title: String, path: String, into groupID: UUID? = nil) -> FavoriteItem {
        let entry = FavoriteItem(title: title, path: path)
        if let groupID {
            mutate { nodes in Self.insert(entry, into: groupID, nodes: &nodes) }
        } else {
            items.append(entry)
            save()
        }
        return entry
    }

    @discardableResult
    func addGroup(title: String, into groupID: UUID? = nil) -> FavoriteItem {
        let entry = FavoriteItem(title: title, isGroup: true)
        if let groupID {
            mutate { nodes in Self.insert(entry, into: groupID, nodes: &nodes) }
        } else {
            items.append(entry)
            save()
        }
        return entry
    }

    private static func insert(_ item: FavoriteItem, into groupID: UUID, nodes: inout [FavoriteItem]) -> Bool {
        for index in nodes.indices {
            if nodes[index].id == groupID, nodes[index].isGroup {
                nodes[index].children.append(item)
                return true
            }
            if insert(item, into: groupID, nodes: &nodes[index].children) { return true }
        }
        return false
    }

    func remove(id: UUID) {
        mutate { nodes in Self.remove(id: id, nodes: &nodes) }
    }

    private static func remove(id: UUID, nodes: inout [FavoriteItem]) -> Bool {
        if let index = nodes.firstIndex(where: { $0.id == id }) {
            nodes.remove(at: index)
            return true
        }
        for index in nodes.indices {
            if remove(id: id, nodes: &nodes[index].children) { return true }
        }
        return false
    }

    func update(id: UUID, title: String? = nil, path: String? = nil) {
        mutate { nodes in
            Self.update(id: id, title: title, path: path, nodes: &nodes)
        }
    }

    private static func update(id: UUID, title: String?, path: String?, nodes: inout [FavoriteItem]) -> Bool {
        for index in nodes.indices {
            if nodes[index].id == id {
                if let title, !title.isEmpty { nodes[index].title = title }
                if let path, !nodes[index].isGroup { nodes[index].path = path }
                return true
            }
            if update(id: id, title: title, path: path, nodes: &nodes[index].children) { return true }
        }
        return false
    }

    /// Moves an entry one slot up or down inside its own group.
    func move(id: UUID, offset: Int) {
        guard offset != 0 else { return }
        mutate { nodes in Self.move(id: id, offset: offset, nodes: &nodes) }
    }

    private static func move(id: UUID, offset: Int, nodes: inout [FavoriteItem]) -> Bool {
        if let index = nodes.firstIndex(where: { $0.id == id }) {
            let target = index + offset
            guard nodes.indices.contains(target) else { return false }
            nodes.swapAt(index, target)
            return true
        }
        for index in nodes.indices {
            if move(id: id, offset: offset, nodes: &nodes[index].children) { return true }
        }
        return false
    }

    /// Adds a folder to the list unless it is already there.
    @discardableResult
    func addIfMissing(title: String, path: String, into groupID: UUID? = nil) -> Bool {
        let normalised = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
        let already = flattened().contains { !$0.isGroup && $0.path == normalised }
        guard !already else { return false }
        add(title: title, path: normalised, into: groupID)
        return true
    }
}
