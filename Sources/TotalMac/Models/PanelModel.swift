import Foundation
import AppKit
import Combine

struct ArchiveLocation: Equatable, Hashable {
    var archiveURL: URL
    /// "" at the archive root, otherwise a member folder path.
    var internalPath: String

    var displayPath: String {
        internalPath.isEmpty ? archiveURL.path : archiveURL.path + "/" + internalPath
    }
}

/// Where a pane currently is: an on-disk folder, or a folder inside an archive.
struct PanelLocation: Equatable, Hashable {
    var directory: URL
    var archive: ArchiveLocation?

    var displayPath: String { archive?.displayPath ?? directory.path }
}

struct PanelTab: Identifiable {
    let id = UUID()
    /// On-disk folder. While browsing an archive this is the folder that holds it.
    var url: URL
    var archive: ArchiveLocation?
    /// All members of the archive, loaded once when the archive is entered.
    var archiveEntries: [ArchiveEntry] = []
    /// Everything the folder contains, including the synthetic `..` row.
    var rawItems: [FileItem] = []
    /// Sorted + filtered view actually shown in the table.
    var display: [FileItem] = []
    var selection: Set<String> = []
    var sort = SortSpec()
    var filter = ""
    var back: [PanelLocation] = []
    var forward: [PanelLocation] = []
    var cursorRow: Int = 0
    var isLoading = false

    var location: PanelLocation { PanelLocation(directory: url, archive: archive) }
}

/// One half of the dual pane window.
@MainActor
final class PanelModel: ObservableObject, Identifiable {

    let id = UUID()
    let sideTitle: String

    @Published var tabs: [PanelTab] = []
    @Published var activeIndex: Int = 0
    @Published var showHidden: Bool = false
    @Published var showBytes: Bool = false
    @Published var sizeInfo: String = ""
    @Published var isComputingSize: Bool = false
    @Published var freeSpaceText: String = ""

    /// (message, informative) – wired up by AppModel so failures surface as alerts.
    var onError: ((String, String) -> Void)?
    /// Called when a file inside an archive should be opened (F3 / Enter).
    var onOpenArchiveMember: ((FileItem) -> Void)?

    weak var table: NSTableView?

    /// After the next listing finishes, select this path (and optionally start
    /// renaming it). Used by New Folder / Rename / "go to path".
    private var pendingSelectPath: String?
    private var pendingRenameAfterSelect = false

    func selectAfterLoad(path: String, rename: Bool) {
        pendingSelectPath = path
        pendingRenameAfterSelect = rename
    }

    private var loadToken = 0
    private var sizeToken = 0
    private var sizeTask: Task<Void, Never>?

    init(startURL: URL, sideTitle: String) {
        self.sideTitle = sideTitle
        self.tabs = [PanelTab(url: startURL.standardizedFileURL)]
        reload(preserveSelection: false)
    }

    // MARK: - Convenience accessors

    var tab: PanelTab {
        get { tabs[min(activeIndex, tabs.count - 1)] }
        set { tabs[min(activeIndex, tabs.count - 1)] = newValue }
    }

    var url: URL { tab.url }
    var archive: ArchiveLocation? { tab.archive }
    var isBrowsingArchive: Bool { tab.archive != nil }
    var archiveEntries: [ArchiveEntry] { tab.archiveEntries }
    var displayItems: [FileItem] { tab.display }
    var isLoading: Bool { tab.isLoading }
    var filter: String { tab.filter }
    var sortSpec: SortSpec { tab.sort }

    /// Path shown in the path bar, e.g. `/Users/me/file.zip/docs`.
    var displayPath: String { tab.location.displayPath }

    /// Folder that copy/move/paste should target.
    var targetDirectory: URL { tab.archive?.archiveURL.deletingLastPathComponent() ?? tab.url }

    var selectedItems: [FileItem] {
        let selection = tab.selection
        return tab.display.filter { !$0.isParent && selection.contains($0.id) }
    }

    var cursorIndex: Int { tab.cursorRow }

    var focusedItem: FileItem? {
        let items = tab.display
        guard !items.isEmpty else { return nil }
        let index = min(max(0, tab.cursorRow), items.count - 1)
        return items[index]
    }

    /// Files an operation should act on: the marked files, or the file under the cursor.
    var operationTargets: [FileItem] {
        let marked = selectedItems
        if !marked.isEmpty { return marked }
        guard let focused = focusedItem, !focused.isParent else { return [] }
        return [focused]
    }

    var statusLine: String {
        let items = tab.display.filter { !$0.isParent }
        let folders = items.filter { $0.isDirectory }.count
        let files = items.count - folders
        var text = "\(folders) dir\(folders == 1 ? "" : "s"), \(files) file\(files == 1 ? "" : "s")"
        if let archive = tab.archive {
            text = "Archive: \(archive.archiveURL.lastPathComponent)  ·  " + text
        }
        if tab.isLoading { text = "Loading… " + text }
        return text
    }

    // MARK: - Loading

    private struct Listing {
        var items: [FileItem]
        var entries: [ArchiveEntry]
    }

    func reload(preserveSelection: Bool = true) {
        loadToken += 1
        let token = loadToken
        let snapshot = tab
        let hidden = showHidden

        tab.isLoading = true

        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<Listing, Error> in
                Result {
                    if let archive = snapshot.archive {
                        let entries = snapshot.archiveEntries.isEmpty
                            ? try ArchiveService.list(archive.archiveURL).entries
                            : snapshot.archiveEntries
                        var items = ArchiveService.children(of: archive.internalPath,
                                                            archive: archive.archiveURL,
                                                            entries: entries,
                                                            showHidden: hidden)
                        items.insert(Self.archiveParentItem(for: snapshot, archive: archive), at: 0)
                        return Listing(items: items, entries: entries)
                    }
                    return Listing(items: try FileSystemService.list(snapshot.url, showHidden: hidden),
                                   entries: [])
                }
            }.value
            guard token == self.loadToken else { return }
            self.apply(result, preserveSelection: preserveSelection)
        }
    }

    /// The `..` row inside an archive: a member folder steps up, the archive root
    /// leaves the archive.
    nonisolated private static func archiveParentItem(for snapshot: PanelTab,
                                                      archive: ArchiveLocation) -> FileItem {
        FileItem(
            url: snapshot.url,
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
            kind: archive.internalPath.isEmpty ? "Leave the archive" : "Parent folder in archive"
        )
    }

    private func apply(_ result: Result<Listing, Error>, preserveSelection: Bool) {
        var current = tab
        current.isLoading = false
        let previousSelection = current.selection
        let previousScrollRow = current.cursorRow

        switch result {
        case .success(let listing):
            current.rawItems = listing.items
            if !listing.entries.isEmpty { current.archiveEntries = listing.entries }
            Self.refreshDisplay(&current)
            let validIDs = Set(current.display.map(\.id))
            current.selection = preserveSelection ? previousSelection.intersection(validIDs) : []
            if !preserveSelection { current.cursorRow = 0 }
            else if previousScrollRow < current.display.count { current.cursorRow = previousScrollRow }
            current.cursorRow = min(current.cursorRow, max(0, current.display.count - 1))
        case .failure(let error):
            current.rawItems = []
            current.display = []
            current.selection = []
            current.cursorRow = 0
            let name = current.location.displayPath
            onError?("Cannot open “\(name)”", error.localizedDescription)
        }
        tabs[activeIndex] = current
        updateFreeSpace()
        scheduleSizeComputation()
        applyPendingSelection()
    }

    private func applyPendingSelection() {
        guard let path = pendingSelectPath else { return }
        pendingSelectPath = nil
        let rename = pendingRenameAfterSelect
        pendingRenameAfterSelect = false

        let current = tabs[activeIndex]
        guard let index = current.display.firstIndex(where: { $0.url.path == path }) else { return }
        var updated = current
        updated.selection = [updated.display[index].id]
        updated.cursorRow = index
        tabs[activeIndex] = updated

        DispatchQueue.main.async { [weak self] in
            guard let table = self?.table else { return }
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            table.scrollRowToVisible(index)
            if rename { table.beginFileRename(row: index) }
        }
    }

    private func updateFreeSpace() {
        let url = tabs[activeIndex].url
        if let free = FileSystemService.freeSpace(at: url) {
            freeSpaceText = "\(ByteFormatter.string(free)) free"
        } else {
            freeSpaceText = ""
        }
    }

    private static func refreshDisplay(_ tab: inout PanelTab) {
        tab.display = FileSystemService.process(tab.rawItems, spec: tab.sort, filter: tab.filter)
    }

    // MARK: - Navigation

    func navigate(to destination: URL, recordHistory: Bool = true) {
        let target = destination.standardizedFileURL
        var current = tab
        if current.archive == nil, current.url.standardizedFileURL == target {
            reload()
            return
        }
        if recordHistory {
            current.back.append(current.location)
            current.forward.removeAll()
        }
        current.url = target
        current.archive = nil
        current.archiveEntries = []
        current.selection = []
        current.cursorRow = 0
        current.filter = ""
        tabs[activeIndex] = current
        reload(preserveSelection: false)
    }

    /// Opens an archive in this pane.
    func enterArchive(at url: URL, internalPath: String = "", recordHistory: Bool = true) {
        var current = tab
        if recordHistory {
            current.back.append(current.location)
            current.forward.removeAll()
        }
        current.url = url.deletingLastPathComponent().standardizedFileURL
        current.archive = ArchiveLocation(archiveURL: url.standardizedFileURL, internalPath: internalPath)
        current.archiveEntries = []
        current.selection = []
        current.cursorRow = 0
        current.filter = ""
        tabs[activeIndex] = current
        reload(preserveSelection: false)
    }

    /// Moves between folders *inside* the archive currently being browsed.
    func navigateInsideArchive(to internalPath: String, recordHistory: Bool = true) {
        guard var archive = tab.archive else { return }
        guard internalPath != archive.internalPath else {
            reload()
            return
        }
        var current = tab
        if recordHistory {
            current.back.append(current.location)
            current.forward.removeAll()
        }
        archive.internalPath = internalPath
        current.archive = archive
        current.selection = []
        current.cursorRow = 0
        current.filter = ""
        tabs[activeIndex] = current
        reload(preserveSelection: false)
    }

    func goUp() {
        var current = tab
        if let archive = current.archive {
            current.back.append(current.location)
            current.forward.removeAll()
            if archive.internalPath.isEmpty {
                // At the archive root: step out to the folder holding it.
                current.archive = nil
                current.archiveEntries = []
            } else {
                var updated = archive
                updated.internalPath = (archive.internalPath as NSString).deletingLastPathComponent
                current.archive = updated
            }
            current.selection = []
            current.cursorRow = 0
            tabs[activeIndex] = current
            reload(preserveSelection: false)
            return
        }

        let parent = current.url.deletingLastPathComponent()
        guard parent.path != current.url.path else { return }
        current.back.append(current.location)
        current.forward.removeAll()
        current.url = parent.standardizedFileURL
        current.selection = []
        current.cursorRow = 0
        current.filter = ""
        tabs[activeIndex] = current
        reload(preserveSelection: false)
    }

    var canGoBack: Bool { !tab.back.isEmpty }
    var canGoForward: Bool { !tab.forward.isEmpty }

    /// Jumps straight to a stored location (used by the history menu).
    func go(to location: PanelLocation, recordHistory: Bool = true) {
        var current = tab
        if recordHistory {
            current.back.append(current.location)
            current.forward.removeAll()
        }
        current.url = location.directory
        current.archive = location.archive
        if location.archive == nil { current.archiveEntries = [] }
        current.selection = []
        current.cursorRow = 0
        current.filter = ""
        tabs[activeIndex] = current
        reload(preserveSelection: false)
    }

    func goBack() {
        var current = tab
        guard let previous = current.back.popLast() else { return }
        current.forward.append(current.location)
        current.url = previous.directory
        current.archive = previous.archive
        if previous.archive == nil { current.archiveEntries = [] }
        current.selection = []
        current.cursorRow = 0
        tabs[activeIndex] = current
        reload(preserveSelection: false)
    }

    func goForward() {
        var current = tab
        guard let next = current.forward.popLast() else { return }
        current.back.append(current.location)
        current.url = next.directory
        current.archive = next.archive
        if next.archive == nil { current.archiveEntries = [] }
        current.selection = []
        current.cursorRow = 0
        tabs[activeIndex] = current
        reload(preserveSelection: false)
    }

    func goHome() {
        navigate(to: FileManager.default.homeDirectoryForCurrentUser)
    }

    func open(_ item: FileItem) {
        if item.isParent {
            goUp()
            return
        }
        if let member = item.archive {
            if item.isDirectory {
                navigateInsideArchive(to: member.memberPath)
            } else {
                onOpenArchiveMember?(item)
            }
            return
        }
        if item.isDirectory {
            navigate(to: item.url)
        } else if ArchiveService.isArchive(item.url) {
            enterArchive(at: item.url)
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    // MARK: - Tabs

    func newTab(at url: URL? = nil) {
        let target = url ?? tab.url
        if ArchiveService.isArchive(target) {
            var newTab = PanelTab(url: target.deletingLastPathComponent().standardizedFileURL)
            newTab.archive = ArchiveLocation(archiveURL: target.standardizedFileURL, internalPath: "")
            tabs.append(newTab)
        } else {
            tabs.append(PanelTab(url: target.standardizedFileURL))
        }
        activeIndex = tabs.count - 1
        reload(preserveSelection: false)
    }

    func closeCurrentTab() {
        guard tabs.count > 1 else { return }
        tabs.remove(at: activeIndex)
        activeIndex = min(activeIndex, tabs.count - 1)
    }

    func closeTab(at index: Int) {
        guard tabs.count > 1, tabs.indices.contains(index) else { return }
        tabs.remove(at: index)
        activeIndex = min(activeIndex, tabs.count - 1)
    }

    func selectTab(_ index: Int) {
        guard tabs.indices.contains(index), index != activeIndex else { return }
        activeIndex = index
    }

    func activateTab(at url: URL) {
        let target = url.standardizedFileURL
        if let index = tabs.firstIndex(where: { $0.url.standardizedFileURL == target }) {
            activeIndex = index
        } else {
            newTab(at: target)
        }
    }

    // MARK: - Selection

    func setSelection(_ ids: Set<String>, cursorRow: Int? = nil) {
        var current = tab
        current.selection = ids
        if let cursorRow { current.cursorRow = cursorRow }
        tabs[activeIndex] = current
        scheduleSizeComputation()
    }

    func setCursor(row: Int) {
        var current = tab
        current.cursorRow = min(max(0, row), max(0, current.display.count - 1))
        tabs[activeIndex] = current
    }

    func selectAll() {
        var current = tab
        current.selection = Set(current.display.filter { !$0.isParent }.map(\.id))
        tabs[activeIndex] = current
        scheduleSizeComputation()
    }

    func selectNone() {
        var current = tab
        current.selection = []
        tabs[activeIndex] = current
        scheduleSizeComputation()
    }

    func invertSelection() {
        var current = tab
        let selectable = current.display.filter { !$0.isParent }
        var newSelection = Set<String>()
        for item in selectable where !current.selection.contains(item.id) {
            newSelection.insert(item.id)
        }
        current.selection = newSelection
        tabs[activeIndex] = current
        scheduleSizeComputation()
    }

    func selectByMask(_ mask: String) {
        var current = tab
        var newSelection = current.selection
        for item in current.display where !item.isParent {
            if FileSystemService.matchesMask(item.name, mask: mask) {
                newSelection.insert(item.id)
            }
        }
        current.selection = newSelection
        tabs[activeIndex] = current
        scheduleSizeComputation()
    }

    func deselectByMask(_ mask: String) {
        var current = tab
        var newSelection = current.selection
        for item in current.display where !item.isParent {
            if FileSystemService.matchesMask(item.name, mask: mask) {
                newSelection.remove(item.id)
            }
        }
        current.selection = newSelection
        tabs[activeIndex] = current
        scheduleSizeComputation()
    }

    /// Space bar behaviour: toggle the row under the cursor, then step down.
    func toggleSelectionAndAdvance() {
        var current = tab
        let items = current.display
        guard !items.isEmpty else { return }
        let row = min(max(0, current.cursorRow), items.count - 1)
        let item = items[row]
        if !item.isParent {
            if current.selection.contains(item.id) {
                current.selection.remove(item.id)
            } else {
                current.selection.insert(item.id)
            }
        }
        if row + 1 < items.count {
            current.cursorRow = row + 1
            let next = items[row + 1]
            if !next.isParent { current.selection.insert(next.id) }
        }
        tabs[activeIndex] = current
        scheduleSizeComputation()
    }

    func setFilter(_ text: String) {        var current = tab
        current.filter = text
        Self.refreshDisplay(&current)
        current.cursorRow = min(current.cursorRow, max(0, current.display.count - 1))
        current.selection = current.selection.intersection(Set(current.display.map(\.id)))
        tabs[activeIndex] = current
        scheduleSizeComputation()
    }

    // MARK: - Sorting

    func setSort(key: SortKey, ascending: Bool) {
        var current = tab
        current.sort = SortSpec(key: key, ascending: ascending)
        Self.refreshDisplay(&current)
        tabs[activeIndex] = current
    }

    func toggleSort(key: SortKey) {
        let current = tab.sort
        if current.key == key {
            setSort(key: key, ascending: !current.ascending)
        } else {
            setSort(key: key, ascending: true)
        }
    }

    func toggleHidden() {
        showHidden.toggle()
        reload()
    }

    /// Drops the cached archive listings so the next load re-reads the file.
    /// Called after any operation that may have rebuilt an archive.
    func invalidateArchiveCache() {
        for index in tabs.indices where tabs[index].archive != nil {
            tabs[index].archiveEntries = []
        }
    }

    // MARK: - Selection size

    func scheduleSizeComputation() {
        sizeTask?.cancel()
        sizeToken += 1
        let token = sizeToken
        let items = selectedItems
        let folders = items.filter { $0.isDirectory }.count

        if items.isEmpty {
            sizeInfo = ""
            isComputingSize = false
            return
        }

        isComputingSize = true
        // Small selections are cheap enough to measure inline.
        sizeTask = Task {
            if !items.isEmpty {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            if Task.isCancelled { return }
            let total = await Task.detached(priority: .utility) { () -> (Int64, Int) in
                var bytes: Int64 = 0
                var files = 0
                for item in items {
                    if Task.isCancelled { break }
                    if item.isDirectory {
                        let measured = FileSystemService.measure(item.url,
                                                                  shouldStop: { Task.isCancelled })
                        bytes += measured.bytes
                        files += measured.files
                    } else {
                        bytes += item.size
                        files += 1
                    }
                }
                return (bytes, files)
            }.value
            guard token == self.sizeToken else { return }
            self.isComputingSize = false
            let noun = items.count == 1 ? "item" : "items"
            var text = "\(items.count) \(noun) selected"
            if folders > 0 {
                text += " · \(ByteFormatter.string(total.0)) in \(ByteFormatter.grouped(Int64(total.1))) file\(total.1 == 1 ? "" : "s")"
            } else {
                text += " · \(ByteFormatter.string(total.0)) · \(ByteFormatter.grouped(total.0)) bytes"
            }
            self.sizeInfo = text
        }
    }
}
