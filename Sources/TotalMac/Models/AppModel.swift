import Foundation
import AppKit
import Combine
import SwiftUI
import Quartz

enum PanelSide {
    case left, right

    var opposite: PanelSide { self == .left ? .right : .left }
}

struct TransferRequest: Identifiable {
    let id = UUID()
    var sources: [FileItem]
    var destination: String
    var move: Bool
}

struct PackRequest: Identifiable {
    let id = UUID()
    var sources: [URL]
    var suggestedName: String
    var destinationDirectory: URL
}

struct VolumeChooserRequest: Identifiable {
    let id = UUID()
    var side: PanelSide
}

/// Central coordinator: owns both panels, the clipboard, the operation queue and
/// the global keyboard handling that gives the app its Total Commander feel.
@MainActor
final class AppModel: ObservableObject {

    /// The single application model. Created lazily on the main thread.
    static let shared: AppModel = MainActor.assumeIsolated { AppModel() }

    @Published var left: PanelModel
    @Published var right: PanelModel
    @Published var activeSide: PanelSide = .left
    @Published var showBytes = false
    @Published var showHidden = false

    @Published var clipboard: [URL] = []
    @Published var clipboardIsCut = false

    @Published var pendingTransfer: TransferRequest?
    @Published var pendingPack: PackRequest?
    @Published var infoItem: FileItem?
    @Published var viewerRequest: ViewerRequest?
    @Published var showHelp = false
    @Published var showSync = false
    @Published var showMultiRename = false
    @Published var showAbout = false
    @Published var showVersions = false
    @Published var showFavorites = false
    /// The pane the favorites window acts on.
    @Published var favoritesSide: PanelSide = .left
    @Published var volumeChooser: VolumeChooserRequest?
    @Published var volumes: [Volume] = []
    let favorites = FavoritesStore()
    @Published var statusMessage: String?
    /// Bumped whenever the quick filter of the active pane should take focus.
    @Published var filterFocusRequest = 0

    /// Files extracted from archives for viewing, keyed by member path.
    var materializedCache: [String: URL] = [:]

    let operations = OperationCenter()

    weak var activeListTable: FileTable?
    weak var hostWindow: NSWindow?

    /// Set once the first pane has taken keyboard focus at launch.
    var didPerformInitialFocus = false

    private var statusResetTask: Task<Void, Never>?

    // MARK: - Init

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        left = PanelModel(startURL: home, sideTitle: "Left")
        right = PanelModel(startURL: home, sideTitle: "Right")

        for panel in [left, right] {
            panel.onError = { [weak self] message, informative in
                self?.operations.reportError(message, informative: informative)
            }
            panel.onOpenArchiveMember = { [weak self] item in
                self?.openArchiveMember(item)
            }
        }

        preparePreviewFolder()

        operations.$summary
            .compactMap { $0 }
            .sink { [weak self] text in self?.showStatus(text) }
            .store(in: &cancellables)

        // The favorites list lives in its own observable object; forward its
        // changes so anything observing the app model stays in step.
        favorites.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        refreshVolumes()
        observeVolumeChanges()
        installKeyboardMonitor()
    }

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Panels

    var activePanel: PanelModel { activeSide == .left ? left : right }
    var inactivePanel: PanelModel { activeSide == .left ? right : left }

    func panel(for side: PanelSide) -> PanelModel { side == .left ? left : right }

    func setActive(_ side: PanelSide, focus: Bool = false) {
        activeSide = side
        if focus, let window = NSApp.keyWindow ?? hostWindow {
            let target = panel(for: side).table
            if let target { window.makeFirstResponder(target) }
        }
    }

    func switchPanel() {
        setActive(activeSide.opposite, focus: true)
    }

    func swapPanels() {
        let leftURL = left.url
        let rightURL = right.url
        left.navigate(to: rightURL)
        right.navigate(to: leftURL)
        showStatus("Panels swapped")
    }

    func refreshAll() {
        left.reload()
        right.reload()
        showStatus("Refreshed")
    }

    func refreshActive() {
        activePanel.reload()
    }

    func focusFilter() {
        filterFocusRequest += 1
    }

    func toggleHidden() {
        showHidden.toggle()
        left.showHidden = showHidden
        right.showHidden = showHidden
        left.reload(preserveSelection: false)
        right.reload(preserveSelection: false)
    }

    func toggleBytes() {
        showBytes.toggle()
        left.showBytes = showBytes
        right.showBytes = showBytes
    }

    func showStatus(_ text: String) {
        statusMessage = text
        statusResetTask?.cancel()
        statusResetTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled { self.statusMessage = nil }
        }
    }

    // MARK: - Navigation commands

    func openFocused() {
        if let focused = activePanel.focusedItem {
            let wasParent = focused.isParent
            let url = focused.url
            activePanel.open(focused)
            if wasParent { _ = url }
        }
    }

    func goUp() { activePanel.goUp() }
    func goBack() { activePanel.goBack() }
    func goForward() { activePanel.goForward() }
    func goHome() { activePanel.goHome() }

    // MARK: - Favorites & volumes

    func refreshVolumes() {
        volumes = VolumeService.mountedVolumes()
    }

    private func observeVolumeChanges() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didMountNotification,
            NSWorkspace.didUnmountNotification,
            NSWorkspace.didRenameVolumeNotification
        ]
        for name in names {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refreshVolumes()
                    self?.showStatus("Volumes updated")
                }
            }
        }
    }

    /// Navigates one pane to a favourite path. Archive members are supported:
    /// `/path/to/bundle.zip/docs` is opened straight inside the archive.
    func go(to path: String, side: PanelSide) {
        let panel = panel(for: side)
        if let (archiveURL, internalPath) = AppModel.splitArchivePath(path) {
            panel.enterArchive(at: archiveURL, internalPath: internalPath)
            return
        }
        let expanded = (path as NSString).expandingTildeInPath
        panel.navigate(to: URL(fileURLWithPath: expanded))
    }

    /// Splits `…/bundle.zip/inner/folder` into the archive and the path inside it.
    nonisolated static func splitArchivePath(_ path: String) -> (archive: URL, internalPath: String)? {
        var url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        var inner: [String] = []
        while url.pathComponents.count > 1 {
            if ArchiveService.isArchive(url),
               FileManager.default.fileExists(atPath: url.path) {
                return (url, inner.reversed().joined(separator: "/"))
            }
            inner.append(url.lastPathComponent)
            url = url.deletingLastPathComponent()
        }
        return nil
    }

    func openFavorites(for side: PanelSide? = nil) {
        favoritesSide = side ?? activeSide
        showFavorites = true
    }

    /// Adds a folder (or an archive location) to the favorites list.
    @discardableResult
    func addFavorite(path: String, suggestedTitle: String, into groupID: UUID? = nil) -> Bool {
        let expanded = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            operations.reportError("That folder no longer exists", informative: expanded)
            return false
        }

        let alert = NSAlert()
        alert.messageText = "Add to favorites"
        alert.informativeText = expanded
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = suggestedTitle
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return false }

        let title = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let added = favorites.addIfMissing(title: title.isEmpty ? suggestedTitle : title,
                                           path: path,
                                           into: groupID)
        if added {
            showStatus("Added “\(title.isEmpty ? suggestedTitle : title)” to favorites")
        } else {
            showStatus("That folder is already in the favorites")
        }
        return added
    }

    /// Adds whatever the active pane is showing (folder or archive folder).
    func addCurrentFolderToFavorites() {
        let panel = activePanel
        let path = panel.displayPath
        let title = panel.archive.map { archive -> String in
            let leaf = archive.internalPath.isEmpty
                ? archive.archiveURL.lastPathComponent
                : (archive.internalPath as NSString).lastPathComponent
            return leaf
        } ?? (path == "/" ? "Computer" : panel.url.lastPathComponent)
        addFavorite(path: path, suggestedTitle: title)
    }

    func chooseVolume(for side: PanelSide) {
        refreshVolumes()
        volumeChooser = VolumeChooserRequest(side: side)
    }

    func ejectVolume(_ volume: Volume) {
        do {
            try VolumeService.eject(volume)
            showStatus("Ejected \(volume.displayName)")
        } catch {
            operations.reportError("Cannot eject “\(volume.displayName)”",
                                   informative: error.localizedDescription)
        }
        refreshVolumes()
    }

    /// The volume a pane's folder lives on.
    func volume(for side: PanelSide) -> Volume? {
        VolumeService.volume(for: panel(for: side).url.path, in: volumes)
    }

    func openPath(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var expanded = (trimmed as NSString).expandingTildeInPath
        if expanded.hasPrefix("file://"), let url = URL(string: expanded) {
            activePanel.navigate(to: url)
            return
        }
        if !expanded.hasPrefix("/") {
            expanded = (activePanel.url.path as NSString).appendingPathComponent(expanded)
        }
        let url = URL(fileURLWithPath: expanded)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            if isDirectory.boolValue {
                activePanel.navigate(to: url)
            } else {
                activePanel.selectAfterLoad(path: url.path, rename: false)
                activePanel.navigate(to: url.deletingLastPathComponent())
            }
        } else {
            operations.reportError("“\(trimmed)” not found",
                                   informative: "The path does not exist.")
        }
    }

    func select(path: String) {
        let panel = activePanel
        if let index = panel.displayItems.firstIndex(where: { $0.url.path == path }) {
            panel.setSelection([path], cursorRow: index)
            panel.table?.scrollRowToVisible(index)
        }
    }

    // MARK: - File commands

    func viewFocused() {
        guard let item = activePanel.focusedItem, !item.isParent else { return }
        if let member = item.archive {
            if item.isDirectory {
                activePanel.navigateInsideArchive(to: member.memberPath)
                return
            }
            if let url = materialize(items: [item]).first {
                viewerRequest = ViewerRequest(path: url.path)
            }
            return
        }
        if item.isDirectory {
            operations.reportError("“\(item.name)” is a folder",
                                   informative: "Use Enter to open folders, F3 to view files.")
            return
        }
        if ArchiveService.isArchive(item.url) {
            activePanel.enterArchive(at: item.url)
            return
        }
        viewerRequest = ViewerRequest(path: item.url.path)
    }

    func viewFile(_ url: URL) {
        viewerRequest = ViewerRequest(path: url.path)
    }

    func editFocused() {
        let targets = activePanel.operationTargets
        guard !targets.isEmpty else { return }
        let urls = materialize(items: targets.filter { !$0.isDirectory })
        for url in urls {
            openWithDefaultEditor(url)
        }
    }

    func openWithDefaultEditor(_ url: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open(url, configuration: configuration) { _, _ in }
    }

    func openWith(_ applicationURL: URL) {
        let targets = activePanel.operationTargets
        guard !targets.isEmpty else { return }
        let urls = materialize(items: targets)
        NSWorkspace.shared.open(urls, withApplicationAt: applicationURL, configuration: .init()) { _, error in
            if let error {
                Task { @MainActor in
                    AppModel.shared.operations.reportError("Could not open with application",
                                                           informative: error.localizedDescription)
                }
            }
        }
    }

    func copyToOtherPanel() {
        let targets = activePanel.operationTargets
        guard !targets.isEmpty else { return }
        pendingTransfer = TransferRequest(sources: targets,
                                          destination: inactivePanel.url.path + "/",
                                          move: false)
    }

    func moveToOtherPanel() {
        let targets = activePanel.operationTargets
        guard !targets.isEmpty else { return }
        pendingTransfer = TransferRequest(sources: targets,
                                          destination: inactivePanel.url.path + "/",
                                          move: true)
    }

    func performTransfer(_ request: TransferRequest) {
        guard !operations.isBusy else {
            operations.reportError("A file operation is already running",
                                   informative: "Wait for it to finish or cancel it first.")
            return
        }
        let destination = URL(fileURLWithPath: (request.destination as NSString).expandingTildeInPath)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory) {
            if !isDirectory.boolValue {
                operations.reportError("Destination is not a folder",
                                       informative: destination.path)
                return
            }
        } else {
            do {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            } catch {
                operations.reportError("Cannot create destination folder",
                                       informative: error.localizedDescription)
                return
            }
        }

        // Pulling files out of an archive is an extract (plus a rewrite for move).
        if let member = request.sources.first?.archive,
           request.sources.allSatisfy({ $0.archive != nil }) {
            let wanted = Set(request.sources.compactMap { $0.archive?.memberPath })
            let entries = activePanel.archiveEntries
            operations.extract(archive: member.archiveURL,
                               entries: entries,
                               wanted: wanted,
                               destination: destination,
                               move: request.move) { [weak self] _ in
                self?.afterFileOperation()
            }
            return
        }

        let sources = request.sources.map(\.url)
        operations.transfer(sources: sources, destination: destination, move: request.move) { [weak self] _ in
            self?.afterFileOperation()
        }
    }

    func deleteFocused(permanent: Bool) {
        let targets = activePanel.operationTargets
        guard !targets.isEmpty else { return }

        // Deleting inside an archive rewrites the archive.
        if let member = targets.first?.archive {
            let names = targets.map(\.name)
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Delete \(targets.count) item\(targets.count == 1 ? "" : "s") from the archive?"
            alert.informativeText = "The archive will be rebuilt without: "
                + names.prefix(12).joined(separator: ", ")
                + (names.count > 12 ? " …" : "")
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }

            let paths = targets.compactMap { $0.archive?.memberPath }
            operations.rewriteArchive(archive: member.archiveURL, removing: paths) { [weak self] _ in
                self?.afterFileOperation()
            }
            return
        }

        if permanent {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Delete \(targets.count) item\(targets.count == 1 ? "" : "s") permanently?"
            alert.informativeText = "This cannot be undone. " + targets.prefix(12).map(\.name).joined(separator: ", ")
                + (targets.count > 12 ? " …" : "")
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        operations.delete(urls: targets.map(\.url), permanent: permanent) { [weak self] _ in
            self?.afterFileOperation()
        }
    }

    func createNewFolder() {
        let panel = activePanel
        if panel.isBrowsingArchive {
            operations.reportError("Cannot create folders inside an archive",
                                   informative: "Extract the archive, change it and pack it again — or use F5 to copy files into it.")
            return
        }
        let alert = NSAlert()
        alert.messageText = "New folder"
        alert.informativeText = "Create a folder inside \(panel.url.path)"
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = "New folder"
        field.placeholderString = "Folder name"
        alert.accessoryView = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/") else {
            operations.reportError("Invalid folder name")
            return
        }

        let target = panel.url.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            panel.selectAfterLoad(path: target.path, rename: true)
            panel.reload(preserveSelection: false)
            showStatus("Created \(name)")
        } catch {
            operations.reportError("Cannot create folder", informative: error.localizedDescription)
        }
    }

    func rename(item: FileItem, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != item.name, !trimmed.contains("/") else { return }
        if item.isArchiveMember {
            operations.reportError("Cannot rename inside an archive",
                                   informative: "Extract, rename and pack again — or use the multi-rename tool on extracted files.")
            activePanel.reload()
            return
        }
        let destination = item.url.deletingLastPathComponent().appendingPathComponent(trimmed)
        do {
            try FileManager.default.moveItem(at: item.url, to: destination)
            activePanel.selectAfterLoad(path: destination.path, rename: false)
            activePanel.reload()
            showStatus("Renamed to \(trimmed)")
        } catch {
            operations.reportError("Cannot rename “\(item.name)”",
                                   informative: error.localizedDescription)
            activePanel.reload()
        }
    }

    func beginRenameOnCursor() {
        guard let table = activeListTable ?? (activePanel.table as? FileTable) else { return }
        let row = table.selectedRow >= 0 ? table.selectedRow : activePanel.cursorIndex
        table.beginRename(row: row)
    }

    func getInfo(_ item: FileItem) {
        infoItem = item
    }

    func revealInFinder(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// Reveals the archive itself when the selection lives inside one.
    func revealSelectionInFinder() {
        if let member = activePanel.operationTargets.first?.archive {
            NSWorkspace.shared.activateFileViewerSelecting([member.archiveURL])
            return
        }
        revealInFinder(activePanel.operationTargets.map(\.url))
    }

    func copyPathsToClipboard() {
        let targets = activePanel.operationTargets
        guard !targets.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(targets.map(\.url.path).joined(separator: "\n"), forType: .string)
        showStatus("Copied \(targets.count) path\(targets.count == 1 ? "" : "s")")
    }

    func copyToClipboard(cut: Bool) {
        let targets = activePanel.operationTargets
        guard !targets.isEmpty else { return }
        clipboard = targets.map(\.url)
        clipboardIsCut = cut
        showStatus(cut ? "Cut \(targets.count) item(s)" : "Copied \(targets.count) item(s)")
    }

    func pasteFromClipboard() {
        guard !clipboard.isEmpty else { return }
        let move = clipboardIsCut
        let sources = clipboard

        // Pasting while browsing an archive copies the files into it.
        if let archive = activePanel.archive {
            operations.rewriteArchive(archive: archive.archiveURL,
                                      removing: [],
                                      adding: sources,
                                      addingPrefix: archive.internalPath) { [weak self] success in
                guard let self else { return }
                if success && move {
                    self.operations.delete(urls: sources, permanent: false) { _ in
                        self.clipboard = []
                        self.clipboardIsCut = false
                        self.afterFileOperation()
                    }
                } else {
                    self.afterFileOperation()
                }
            }
            return
        }

        let destination = activePanel.url
        operations.transfer(sources: sources, destination: destination, move: move) { [weak self] success in
            guard let self else { return }
            if success && move {
                self.clipboard = []
                self.clipboardIsCut = false
            }
            self.afterFileOperation()
        }
    }

    func duplicateSelection() {
        let targets = activePanel.operationTargets
        guard !targets.isEmpty else { return }
        for item in targets {
            let destination = FileSystemService.uniqueURL(for: item.url)
            do {
                try FileManager.default.copyItem(at: item.url, to: destination)
            } catch {
                operations.reportError("Cannot duplicate “\(item.name)”", informative: error.localizedDescription)
                break
            }
        }
        afterFileOperation()
    }

    func afterFileOperation() {
        left.invalidateArchiveCache()
        right.invalidateArchiveCache()
        left.reload()
        right.reload()
    }

    // MARK: - Keyboard

    private func installKeyboardMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            var handled = false
            MainActor.assumeIsolated {
                handled = self.handleKeyEvent(event)
            }
            return handled ? nil : event
        }
    }

    private var isEditingText: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        if responder is NSTextView { return true }
        return false
    }

    func handleKeyEvent(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        let hasCommand = modifiers.contains(.command)
        let hasControl = modifiers.contains(.control)

        // Function keys always work, even while typing.
        switch event.keyCode {
        case 122: // F1
            if modifiers.contains(.option) {
                chooseVolume(for: .left)
            } else {
                showHelp = true
            }
            return true
        case 120: // F2
            if modifiers.contains(.option) {
                chooseVolume(for: .right)
            } else {
                beginRenameOnCursor()
            }
            return true
        case 99:  // F3
            viewFocused()
            return true
        case 118: // F4
            if modifiers.contains(.shift) {
                openMultiRename()
            } else {
                editFocused()
            }
            return true
        case 96:  // F5
            if modifiers.contains(.option) {
                packSelection()
            } else {
                copyToOtherPanel()
            }
            return true
        case 97:  // F6
            if modifiers.contains(.shift) {
                beginRenameOnCursor()
            } else {
                moveToOtherPanel()
            }
            return true
        case 98:  // F7
            createNewFolder()
            return true
        case 100: // F8
            if modifiers.contains(.shift) {
                deleteFocused(permanent: true)
            } else if hasCommand {
                copyPathsToClipboard()
            } else {
                deleteFocused(permanent: false)
            }
            return true
        case 101: // F9
            if modifiers.contains(.shift) {
                verifyArchive()
            } else if modifiers.contains(.option) {
                extractToOtherPanel()
            } else {
                openCompareWindow()
            }
            return true
        case 109: // F10
            if hasControl { return false }
            showStatus("F10: the menu bar lives in the top toolbar")
            return true
        case 103: // F11
            duplicateSelection()
            return true
        case 111: // F12
            showStatus("F12: no saved tab configuration in this build")
            return true
        default:
            break
        }

        // Control key shortcuts that Total Commander users expect.
        if hasControl, !hasCommand {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "m":
                openMultiRename()
                return true
            case "p":
                packSelection()
                return true
            default:
                break
            }
        }

        guard !isEditingText else { return false }

        // Total Commander's Ctrl+D opens the directory hotlist; on macOS ⌘D does.
        if hasCommand, !modifiers.contains(.option) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "d":
                if modifiers.contains(.shift) {
                    addCurrentFolderToFavorites()
                } else {
                    openFavorites()
                }
                return true
            default:
                break
            }
        }

        // Tab switches the active pane unless a modifier is involved.
        if event.keyCode == 48 && !hasCommand && !hasControl {
            switchPanel()
            return true
        }

        // Internal file clipboard. While editing text we fall through so the
        // standard text clipboard keeps working.
        if hasCommand, !modifiers.contains(.option), !modifiers.contains(.shift) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c":
                copyToClipboard(cut: false)
                return true
            case "x":
                copyToClipboard(cut: true)
                return true
            case "v":
                pasteFromClipboard()
                return true
            case "a":
                if NSApp.keyWindow?.firstResponder === activeListTable {
                    selectAll()
                    return true
                }
            case "y":
                quickLook()
                return true
            default:
                break
            }
        }

        guard let table = activeListTable, NSApp.keyWindow?.firstResponder === table else {
            return false
        }

        switch event.keyCode {
        case 49: // space
            activePanel.toggleSelectionAndAdvance()
            syncTableSelection()
            return true
        case 36, 76: // return / enter
            openFocused()
            return true
        case 51: // backspace
            goUp()
            return true
        default:
            return false
        }
    }

    func syncTableSelection() {
        let panel = activePanel
        guard let table = panel.table else { return }
        let ids = panel.tab.selection
        var indexes = IndexSet()
        for (index, item) in panel.displayItems.enumerated() where ids.contains(item.id) {
            indexes.insert(index)
        }
        if table.selectedRowIndexes != indexes {
            table.selectRowIndexes(indexes, byExtendingSelection: false)
        }
        let row = panel.cursorIndex
        if row >= 0, row < table.numberOfRows {
            table.scrollRowToVisible(row)
        }
    }

    // MARK: - Tab commands

    func newTab() { activePanel.newTab() }
    func closeTab() { activePanel.closeCurrentTab() }

    func newTabFromFocusedFolder() {
        if let item = activePanel.focusedItem, item.isDirectory, !item.isParent {
            activePanel.newTab(at: item.url)
        } else {
            activePanel.newTab()
        }
    }

    func activateTab(_ index: Int) { activePanel.selectTab(index) }

    // MARK: - Selection commands

    func selectAll() {
        activePanel.selectAll()
        syncTableSelection()
    }

    func selectNone() {
        activePanel.selectNone()
        syncTableSelection()
    }

    func invertSelection() {
        activePanel.invertSelection()
        syncTableSelection()
    }

    func selectByMask() {
        let alert = NSAlert()
        alert.messageText = "Select group"
        alert.informativeText = "Wildcards: * and ?"
        alert.addButton(withTitle: "Select")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = "*.*"
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        activePanel.selectByMask(field.stringValue)
        syncTableSelection()
    }

    func deselectByMask() {
        let alert = NSAlert()
        alert.messageText = "Unselect group"
        alert.informativeText = "Wildcards: * and ?"
        alert.addButton(withTitle: "Unselect")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = "*.*"
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        activePanel.deselectByMask(field.stringValue)
        syncTableSelection()
    }

    // MARK: - Archives

    /// Files pulled out of an archive have to land somewhere before another
    /// application (or the viewer) can use them.
    private var previewRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("TotalMac-preview", isDirectory: true)
    }

    private func preparePreviewFolder() {
        try? FileManager.default.removeItem(at: previewRoot)
        try? FileManager.default.createDirectory(at: previewRoot, withIntermediateDirectories: true)
    }

    func cleanUpPreviewFolder() {
        try? FileManager.default.removeItem(at: previewRoot)
    }

    /// Returns real filesystem URLs for the given rows, extracting archive
    /// members into a scratch folder first. Repeated calls reuse the extraction.
    func materialize(items: [FileItem]) -> [URL] {
        var results: [URL] = []
        var cache = materializedCache

        for item in items {
            guard let member = item.archive else {
                results.append(item.url)
                continue
            }
            let key = member.displayPath
            if let existing = cache[key], FileManager.default.fileExists(atPath: existing.path) {
                results.append(existing)
                continue
            }
            let scratch = previewRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
            do {
                try ArchiveService.extract(archive: member.archiveURL,
                                           entries: activePanel.archiveEntries.isEmpty
                                                ? ArchiveService.list(member.archiveURL).entries
                                                : activePanel.archiveEntries,
                                           wanted: [member.memberPath],
                                           destination: scratch,
                                           policy: .replace)
                let target = scratch.appendingPathComponent(member.memberPath)
                cache[key] = target
                results.append(target)
            } catch {
                operations.reportError("Cannot open “\(item.name)” from the archive",
                                       informative: error.localizedDescription)
            }
        }
        materializedCache = cache
        return results
    }

    /// Opens a file that lives inside an archive with its default application.
    func openArchiveMember(_ item: FileItem) {
        guard let url = materialize(items: [item]).first else { return }
        NSWorkspace.shared.open(url)
    }

    /// Extracts the selection to the other pane through the normal copy dialog.
    func extractToOtherPanel() {
        guard activePanel.isBrowsingArchive else {
            copyToOtherPanel()
            return
        }
        let targets = activePanel.operationTargets
        guard !targets.isEmpty else { return }
        pendingTransfer = TransferRequest(sources: targets,
                                          destination: inactivePanel.targetDirectory.path + "/",
                                          move: false)
    }

    /// Opens the pack dialog for the current selection.
    func packSelection() {
        let targets = activePanel.operationTargets
        if activePanel.isBrowsingArchive {
            operations.reportError("Repacking an archive from inside itself is not supported",
                                   informative: "Extract it first, then pack the extracted folder.")
            return
        }
        guard !targets.isEmpty else {
            operations.reportError("Nothing selected", informative: "Mark the files to pack first.")
            return
        }
        let sources = targets.map(\.url)
        let suggested: String
        if sources.count == 1, let name = sources.first?.deletingPathExtension().lastPathComponent {
            suggested = name
        } else {
            suggested = activePanel.url.lastPathComponent
        }
        pendingPack = PackRequest(sources: sources,
                                  suggestedName: suggested,
                                  destinationDirectory: activePanel.url)
    }

    func performPack(_ request: PackRequest, archiveName: String, format: ArchiveFormat, level: Int) {
        var name = archiveName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if !name.lowercased().hasSuffix("." + format.fileExtension) {
            name += "." + format.fileExtension
        }
        let archive = request.destinationDirectory.appendingPathComponent(name)
        operations.createArchive(archive: archive,
                                 sources: request.sources,
                                 format: format,
                                 level: level) { [weak self] _ in
            self?.afterFileOperation()
            self?.selectInActivePanel(path: archive.path)
        }
    }

    private func selectInActivePanel(path: String) {
        activePanel.selectAfterLoad(path: path, rename: false)
        activePanel.reload()
    }

    /// Verifies every member of the archive under the cursor (CRC check).
    func verifyArchive() {
        guard let item = activePanel.focusedItem, !item.isParent else { return }
        let url = item.archive?.archiveURL ?? item.url
        guard ArchiveService.isArchive(url) else {
            operations.reportError("Not an archive", informative: url.lastPathComponent)
            return
        }

        operations.runCustom(title: "Testing the archive") { context in
            do {
                let listing = try ArchiveService.list(url)
                context.bytesTotal = listing.entries.reduce(0) { $0 + ($1.isDirectory ? 0 : $1.size) }
                context.filesTotal = listing.entries.count

                let reader = try ArchiveReader(path: url.path)
                var buffer = [UInt8](repeating: 0, count: 256 * 1024)
                var bytes: Int64 = 0
                var members = 0
                while let entry = try reader.next() {
                    if context.cancelled { break }
                    members += 1
                    if entry.isDirectory || entry.isSymlink {
                        context.filesDone = members
                        continue
                    }
                    while true {
                        let read = reader.read(into: &buffer)
                        if read <= 0 { break }
                        bytes += Int64(read)
                        context.bytesDone = bytes
                        context.report(detail: entry.name)
                    }
                    context.filesDone = members
                }
                reader.close()
                context.filesDone = members
            } catch {
                context.errors.append(error.localizedDescription)
            }
        } completion: { _ in }
    }

    // MARK: - Tools

    func openCompareWindow() {
        showSync = true
    }

    func openMultiRename() {
        guard !activePanel.isBrowsingArchive else {
            operations.reportError("The multi-rename tool works on files on disk",
                                   informative: "Extract the archive first.")
            return
        }
        let targets = activePanel.operationTargets
        guard !targets.isEmpty else {
            operations.reportError("Nothing selected", informative: "Mark the files to rename first.")
            return
        }
        showMultiRename = true
    }

    func quickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.orderOut(nil)
            return
        }
        panel.makeKeyAndOrderFront(nil)
    }

    /// Rows Quick Look should show: the marked files, or the cursor row.
    func quickLookItems() -> [FileItem] {
        let targets = activePanel.operationTargets
        return targets.isEmpty ? [] : targets
    }

    func quickLookURLs() -> [URL] {
        materialize(items: quickLookItems())
    }
}
