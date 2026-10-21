import SwiftUI
import AppKit
import Quartz
import UniformTypeIdentifiers

/// A drop coming from the Finder or from the other pane.
struct DropRequest {
    var urls: [URL]
    /// Target folder for a normal copy.
    var directory: URL
    /// When set, the files are copied *into* this archive instead.
    var archiveTarget: URL?
    var archivePrefix: String = ""
    var modifiers: NSEvent.ModifierFlags = []
}

/// NSTableView subclass that gives us the Total Commander cursor behaviour:
/// Space toggles and steps down, Return opens, and the cursor row is tracked so
/// Space/Return always act on the row "under the cursor" rather than on a range.
final class FileTable: NSTableView {

    weak var fileCoordinator: FileListView.Coordinator?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { fileCoordinator?.focusChanged() }
        return accepted
    }

    override func draggingSession(_ session: NSDraggingSession,
                                  sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? [.copy, .move] : .copy
    }

    /// Called by the app wide key monitor / menu commands.
    func beginRename(row: Int) {
        fileCoordinator?.beginRename(row: row)
    }

    // MARK: - Quick Look

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        true
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        fileCoordinator?.prepareQuickLook()
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }
}

extension FileTable: QLPreviewPanelDataSource, QLPreviewPanelDelegate {

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        fileCoordinator?.quickLookItems.count ?? 0
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard let coordinator = fileCoordinator else { return nil }
        let items = coordinator.quickLookItems
        guard index >= 0, index < items.count else { return nil }
        return items[index] as NSURL
    }
}

extension NSTableView {
    /// Inline rename for TotalMac file lists (no-op for other table views).
    func beginFileRename(row: Int) {
        (self as? FileTable)?.beginRename(row: row)
    }
}

struct FileListView: NSViewRepresentable {

    @ObservedObject var panel: PanelModel

    /// Called when the pane should become the active one.
    var onActivate: () -> Void = {}
    /// Opens an item (Enter / double click).
    var onOpen: (FileItem) -> Void = { _ in }
    /// Inline rename committed.
    var onRename: (FileItem, String) -> Void = { _, _ in }
    /// Files dropped on the table.
    var onDrop: (DropRequest) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let table = FileTable()
        table.fileCoordinator = context.coordinator
        context.coordinator.table = table
        table.dataSource = context.coordinator
        table.delegate = context.coordinator

        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.allowsColumnReordering = false
        table.allowsColumnSelection = false
        table.usesAlternatingRowBackgroundColors = true
        table.style = .plain
        table.rowHeight = 20
        table.intercellSpacing = NSSize(width: 10, height: 1)
        table.gridStyleMask = []
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.headerView = NSTableHeaderView()
        table.backgroundColor = .controlBackgroundColor
        table.refusesFirstResponder = false

        table.registerForDraggedTypes([.fileURL])
        table.setDraggingSourceOperationMask([.copy, .move, .link], forLocal: false)
        table.setDraggingSourceOperationMask([.copy, .move, .link], forLocal: true)
        table.draggingDestinationFeedbackStyle = .regular

        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.handleDoubleClick(_:))

        let menu = NSMenu()
        menu.delegate = context.coordinator
        table.menu = menu

        context.coordinator.addColumn(to: table, id: "name", title: "Name", width: 300, minWidth: 120)
        context.coordinator.addColumn(to: table, id: "ext", title: "Ext", width: 62, minWidth: 44)
        context.coordinator.addColumn(to: table, id: "size", title: "Size", width: 88, minWidth: 60)
        context.coordinator.addColumn(to: table, id: "modified", title: "Date", width: 118, minWidth: 90)
        context.coordinator.addColumn(to: table, id: "attr", title: "Attr", width: 76, minWidth: 56)

        let scrollView = NSScrollView()
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .controlBackgroundColor

        MainActor.assumeIsolated { panel.table = table }
        context.coordinator.sync(table: table, scrollView: scrollView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let table = scrollView.documentView as? FileTable else { return }
        context.coordinator.sync(table: table, scrollView: scrollView)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, NSTextFieldDelegate {

        var parent: FileListView
        weak var table: FileTable?

        private var lastSignature: Signature?
        private var isSyncingSelection = false
        private var isSyncingSort = false
        private var renamingRow: Int?

        struct Signature: Equatable {
            var count: Int
            var first: String
            var last: String
            var sortKey: String
            var ascending: Bool
            var filter: String
            var showBytes: Bool
        }

        init(parent: FileListView) {
            self.parent = parent
        }

        // MARK: Helpers

        private func onMain<T>(_ body: @MainActor () -> T) -> T {
            MainActor.assumeIsolated(body)
        }

        private func withApp(_ body: @MainActor (AppModel) -> Void) {
            MainActor.assumeIsolated { body(AppModel.shared) }
        }

        private var items: [FileItem] {
            onMain { parent.panel.displayItems }
        }

        func focusChanged() {
            guard let table else { return }
            onMain {
                parent.onActivate()
                AppModel.shared.activeListTable = table
            }
        }

        /// Materialises archive members so Quick Look has real files to show.
        private var previewItems: [URL] = []

        var quickLookItems: [URL] { previewItems }

        func prepareQuickLook() {
            previewItems = onMain { AppModel.shared.quickLookURLs() }
        }

        func addColumn(to table: NSTableView, id: String, title: String, width: CGFloat, minWidth: CGFloat) {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.minWidth = minWidth
            column.maxWidth = 4000
            column.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true)
            table.addTableColumn(column)
        }

        // MARK: Sync

        func sync(table: FileTable, scrollView: NSScrollView) {
            let modelItems = items
            let spec = onMain { parent.panel.sortSpec }
            let filter = onMain { parent.panel.filter }
            let showBytes = onMain { parent.panel.showBytes }

            let signature = Signature(
                count: modelItems.count,
                first: modelItems.first?.id ?? "",
                last: modelItems.last?.id ?? "",
                sortKey: spec.key.rawValue,
                ascending: spec.ascending,
                filter: filter,
                showBytes: showBytes
            )

            if signature != lastSignature {
                lastSignature = signature
                table.reloadData()
            }

            // Keep the header sort indicator in step with the model.
            let descriptor = NSSortDescriptor(key: spec.key.rawValue, ascending: spec.ascending)
            if table.sortDescriptors.first?.key != descriptor.key
                || table.sortDescriptors.first?.ascending != descriptor.ascending {
                isSyncingSort = true
                table.sortDescriptors = [descriptor]
                isSyncingSort = false
            }

            // Let the table cover the empty area under the last row so drops land there.
            let contentHeight = scrollView.contentSize.height
            if table.frame.height < contentHeight {
                table.frame = NSRect(x: 0, y: 0,
                                     width: max(table.frame.width, scrollView.contentSize.width),
                                     height: contentHeight)
            }

            applySelection(table)

            // Give the first pane keyboard focus once the window exists so the
            // arrow keys, Space and Enter work without clicking first.
            let needsInitialFocus = onMain { !AppModel.shared.didPerformInitialFocus }
            if needsInitialFocus, table.window != nil {
                onMain { AppModel.shared.didPerformInitialFocus = true }
                DispatchQueue.main.async { [weak table] in
                    guard let table, let window = table.window else { return }
                    if window.firstResponder === window {
                        window.makeFirstResponder(table)
                    }
                }
            }
        }

        private func applySelection(_ table: FileTable) {
            let modelItems = items
            let ids = onMain { parent.panel.tab.selection }
            let cursor = onMain { parent.panel.cursorIndex }

            var indexes = IndexSet()
            for (index, item) in modelItems.enumerated() where ids.contains(item.id) {
                indexes.insert(index)
            }
            if table.selectedRowIndexes != indexes {
                isSyncingSelection = true
                table.selectRowIndexes(indexes, byExtendingSelection: false)
                isSyncingSelection = false
            }
            if cursor >= 0, cursor < modelItems.count {
                table.scrollRowToVisible(cursor)
            }
        }

        // MARK: Data source

        func numberOfRows(in tableView: NSTableView) -> Int {
            items.count
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let modelItems = items
            guard row < modelItems.count else { return nil }
            let item = modelItems[row]
            guard let columnID = tableColumn?.identifier.rawValue else { return nil }

            switch columnID {
            case "name":
                return nameCell(tableView, item: item)
            case "ext":
                return textCell(tableView, id: "ext", text: item.ext, alignment: .left, monospaced: true)
            case "size":
                let text = onMain { parent.panel.showBytes }
                    ? (item.isDirectory || item.isParent ? item.formattedSize : ByteFormatter.grouped(item.size))
                    : item.formattedSize
                return textCell(tableView, id: "size", text: text, alignment: .right, monospaced: true)
            case "modified":
                let text = item.modified.map { DateFormatter.short($0) } ?? ""
                return textCell(tableView, id: "modified", text: text, alignment: .left, monospaced: true)
            case "attr":
                return textCell(tableView, id: "attr", text: item.attr, alignment: .left, monospaced: true)
            default:
                return nil
            }
        }

        private func textCell(_ tableView: NSTableView, id: String, text: String,
                              alignment: NSTextAlignment, monospaced: Bool) -> NSView {
            let identifier = NSUserInterfaceItemIdentifier(id + "Cell")
            var cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            if cell == nil {
                let newCell = NSTableCellView()
                newCell.identifier = identifier
                let field = NSTextField(labelWithString: "")
                field.translatesAutoresizingMaskIntoConstraints = false
                field.lineBreakMode = .byTruncatingTail
                field.font = monospaced ? Self.monoFont : Self.regularFont
                field.textColor = .secondaryLabelColor
                newCell.addSubview(field)
                newCell.textField = field
                NSLayoutConstraint.activate([
                    field.leadingAnchor.constraint(equalTo: newCell.leadingAnchor, constant: 1),
                    field.trailingAnchor.constraint(equalTo: newCell.trailingAnchor, constant: -1),
                    field.centerYAnchor.constraint(equalTo: newCell.centerYAnchor)
                ])
                cell = newCell
            }
            cell?.textField?.alignment = alignment
            cell?.textField?.stringValue = text
            cell?.textField?.textColor = .secondaryLabelColor
            return cell!
        }

        static let regularFont = NSFont.systemFont(ofSize: 12)
        static let monoFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        static let smallMonoFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        static let boldFont = NSFont.systemFont(ofSize: 12, weight: .semibold)

        private func nameCell(_ tableView: NSTableView, item: FileItem) -> NSView {
            let identifier = NSUserInterfaceItemIdentifier("nameCell")
            var cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            if cell == nil {
                let newCell = NSTableCellView()
                newCell.identifier = identifier

                let imageView = NSImageView()
                imageView.translatesAutoresizingMaskIntoConstraints = false
                imageView.imageScaling = .scaleProportionallyDown
                newCell.addSubview(imageView)
                newCell.imageView = imageView

                let field = NSTextField(labelWithString: "")
                field.translatesAutoresizingMaskIntoConstraints = false
                field.lineBreakMode = .byTruncatingMiddle
                field.font = Self.regularFont
                field.isEditable = false
                field.isSelectable = false
                field.isBezeled = false
                field.drawsBackground = false
                field.delegate = self
                newCell.addSubview(field)
                newCell.textField = field

                NSLayoutConstraint.activate([
                    imageView.leadingAnchor.constraint(equalTo: newCell.leadingAnchor),
                    imageView.centerYAnchor.constraint(equalTo: newCell.centerYAnchor),
                    imageView.widthAnchor.constraint(equalToConstant: 16),
                    imageView.heightAnchor.constraint(equalToConstant: 16),
                    field.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
                    field.trailingAnchor.constraint(equalTo: newCell.trailingAnchor, constant: -2),
                    field.centerYAnchor.constraint(equalTo: newCell.centerYAnchor)
                ])
                cell = newCell
            }

            guard let cell, let field = cell.textField else { return NSTableCellView() }

            let image: NSImage
            if item.isParent {
                image = NSImage(named: NSImage.goBackTemplateName) ?? NSImage()
            } else if item.isArchiveMember {
                // Members have no file on disk: show the icon for their type.
                let type = UTType(filenameExtension: (item.name as NSString).pathExtension)
                image = NSWorkspace.shared.icon(for: type ?? UTType.data)
            } else if ArchiveService.isArchive(item.url) {
                image = NSWorkspace.shared.icon(forFile: item.url.path)
            } else {
                image = NSWorkspace.shared.icon(forFile: item.url.path)
            }
            image.size = NSSize(width: 16, height: 16)
            cell.imageView?.image = image

            let attributed = NSMutableAttributedString()
            let nameColor: NSColor
            let font: NSFont
            if item.isParent {
                nameColor = .labelColor
                font = Self.regularFont
            } else if item.isSymlink {
                nameColor = .systemPurple
                font = Self.regularFont
            } else if item.isDirectory {
                nameColor = .labelColor
                font = Self.boldFont
            } else if item.isHidden {
                nameColor = .tertiaryLabelColor
                font = Self.regularFont
            } else {
                nameColor = .labelColor
                font = Self.regularFont
            }

            attributed.append(NSAttributedString(string: item.name, attributes: [
                .foregroundColor: nameColor,
                .font: font
            ]))

            if item.isSymlink,
               let target = try? FileManager.default.destinationOfSymbolicLink(atPath: item.url.path) {
                attributed.append(NSAttributedString(string: "  →  \(target)", attributes: [
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .font: Self.regularFont
                ]))
            }

            field.attributedStringValue = attributed
            field.toolTip = item.tooltip
            field.isEditable = false
            field.isSelectable = false
            return cell
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            true
        }

        func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
            guard tableColumn?.identifier.rawValue == "name" else { return nil }
            let modelItems = items
            guard row < modelItems.count else { return nil }
            let item = modelItems[row]
            return item.isParent ? nil : item.name
        }

        func tableView(_ tableView: NSTableView, shouldTypeSelectFor event: NSEvent,
                       withCurrentSearch searchString: String?) -> Bool {
            if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
                return false
            }
            guard let characters = event.charactersIgnoringModifiers, !characters.isEmpty else { return false }
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
            return characters.rangeOfCharacter(from: allowed) != nil
        }

        // MARK: Selection

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isSyncingSelection, let table else { return }
            let modelItems = items
            var ids = Set<String>()
            for index in table.selectedRowIndexes where index < modelItems.count {
                ids.insert(modelItems[index].id)
            }
            let cursor = table.selectedRow >= 0 ? table.selectedRow : 0
            onMain {
                parent.panel.setSelection(ids, cursorRow: cursor)
            }
            // Keep an open Quick Look panel in step with the selection.
            if QLPreviewPanel.sharedPreviewPanelExists(),
               let previewPanel = QLPreviewPanel.shared(), previewPanel.isVisible {
                prepareQuickLook()
                previewPanel.reloadData()
            }
        }

        // MARK: Sorting

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !isSyncingSort, let descriptor = tableView.sortDescriptors.first,
                  let key = SortKey(rawValue: descriptor.key ?? "name") else { return }
            onMain {
                parent.panel.setSort(key: key, ascending: descriptor.ascending)
            }
        }

        // MARK: Opening

        @objc func handleDoubleClick(_ sender: Any?) {
            guard let table, table.clickedRow >= 0 else { return }
            let modelItems = items
            let row = table.clickedRow
            guard row < modelItems.count else { return }
            let item = modelItems[row]
            onMain { parent.onOpen(item) }
        }

        @objc private func menuOpen(_ sender: Any?) {
            guard let table, table.clickedRow >= 0 else { return }
            let modelItems = items
            let row = table.clickedRow
            guard row < modelItems.count else { return }
            let item = modelItems[row]
            onMain { parent.onOpen(item) }
        }

        // MARK: Inline rename

        func beginRename(row: Int) {
            guard let table, row >= 0, row < table.numberOfRows else { return }
            guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView,
                  let field = cell.textField else { return }
            renamingRow = row
            field.isEditable = true
            field.isSelectable = true
            table.window?.makeFirstResponder(field)
            field.selectText(nil)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField, let row = renamingRow else { return }
            renamingRow = nil
            field.isEditable = false
            field.isSelectable = false

            let modelItems = items
            guard row < modelItems.count else { return }
            let item = modelItems[row]

            let movement = (notification.userInfo?["NSTextMovement"] as? Int) ?? 0
            if movement == 23 { // NSCancelTextMovement – Escape restores the old name
                table?.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integersIn: 0..<1))
                return
            }
            let newName = field.stringValue
            if newName != item.name {
                onMain { parent.onRename(item, newName) }
            } else {
                table?.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integersIn: 0..<1))
            }
        }

        // MARK: Dragging out

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            let modelItems = items
            guard row < modelItems.count, !modelItems[row].isParent else { return nil }
            let item = modelItems[row]
            // Archive members have no on-disk file: use F5 to extract them instead.
            guard !item.isArchiveMember else { return nil }
            return item.url as NSURL
        }

        // MARK: Dropping in

        private func draggedURLs(from pasteboard: NSPasteboard) -> [URL] {
            let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
            let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]
            return objects ?? []
        }

        enum DropDestination {
            case directory(URL)
            case archive(URL, String)
        }

        /// Where a drop should land: a folder on disk, or an archive to insert into.
        private func dropDestination(targetRow: Int?, panelIsArchive: Bool) -> DropDestination {
            let modelItems = items
            if let targetRow, targetRow >= 0, targetRow < modelItems.count {
                let item = modelItems[targetRow]
                if let member = item.archive, item.isDirectory {
                    return .archive(member.archiveURL, member.memberPath)
                }
                if !item.isArchiveMember {
                    if item.isDirectory {
                        if ArchiveService.isArchive(item.url) { return .archive(item.url, "") }
                        return .directory(item.url)
                    }
                    if ArchiveService.isArchive(item.url) { return .archive(item.url, "") }
                }
            }
            if panelIsArchive, let archive = onMain({ parent.panel.archive }) {
                return .archive(archive.archiveURL, archive.internalPath)
            }
            return .directory(onMain { parent.panel.url })
        }

        private func operation(for urls: [URL], target: URL) -> NSDragOperation {
            let flags = NSEvent.modifierFlags
            if flags.contains(.option) { return .copy }
            if flags.contains(.command) { return .move }
            guard let first = urls.first else { return .copy }
            return FileSystemService.isSameVolume(first, target) ? .move : .copy
        }

        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                       proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
            let urls = draggedURLs(from: info.draggingPasteboard)
            guard !urls.isEmpty else { return [] }

            let modelItems = items
            var targetRow: Int?
            if row >= 0, row < modelItems.count {
                let candidate = modelItems[row]
                let isArchiveFile = !candidate.isArchiveMember && ArchiveService.isArchive(candidate.url)
                if candidate.isDirectory || isArchiveFile {
                    targetRow = row
                }
            }
            if let targetRow {
                tableView.setDropRow(targetRow, dropOperation: .on)
            } else {
                tableView.setDropRow(tableView.numberOfRows, dropOperation: .above)
            }

            let panelIsArchive = onMain { parent.panel.isBrowsingArchive }
            switch dropDestination(targetRow: targetRow, panelIsArchive: panelIsArchive) {
            case .archive(let archiveURL, _):
                if urls.contains(where: { $0.standardizedFileURL.path == archiveURL.standardizedFileURL.path }) {
                    return []
                }
                return .copy
            case .directory(let directory):
                for url in urls where FileSystemService.isDescendant(directory, of: url) {
                    return []
                }
                let parents = Set(urls.map { $0.deletingLastPathComponent().standardizedFileURL.path })
                if parents.count == 1, parents.contains(directory.standardizedFileURL.path) {
                    return []
                }
                return operation(for: urls, target: directory)
            }
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                       row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            let urls = draggedURLs(from: info.draggingPasteboard)
            guard !urls.isEmpty else { return false }

            let modelItems = items
            var targetRow: Int?
            if dropOperation == .on, row >= 0, row < modelItems.count { targetRow = row }
            let panelIsArchive = onMain { parent.panel.isBrowsingArchive }

            var request: DropRequest
            switch dropDestination(targetRow: targetRow, panelIsArchive: panelIsArchive) {
            case .directory(let directory):
                request = DropRequest(urls: urls, directory: directory)
            case .archive(let archiveURL, let prefix):
                request = DropRequest(urls: urls,
                                      directory: onMain { parent.panel.url },
                                      archiveTarget: archiveURL,
                                      archivePrefix: prefix)
            }
            request.modifiers = NSEvent.modifierFlags
            onMain { parent.onDrop(request) }
            return true
        }

        // MARK: Context menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table else { return }
            let clicked = table.clickedRow
            let modelItems = items

            if clicked >= 0, clicked < modelItems.count, !table.selectedRowIndexes.contains(clicked) {
                isSyncingSelection = true
                table.selectRowIndexes(IndexSet(integer: clicked), byExtendingSelection: false)
                isSyncingSelection = false
                onMain { parent.panel.setSelection([modelItems[clicked].id], cursorRow: clicked) }
            }

            let hasSelection = !onMain { parent.panel.operationTargets }.isEmpty
            let focusedIsParent = (clicked >= 0 && clicked < modelItems.count) ? modelItems[clicked].isParent : false

            menu.addItem(item("Open", #selector(menuOpen(_:)), enabled: !focusedIsParent, key: "↩"))
            menu.addItem(item("Open in New Tab", #selector(menuOpenNewTab(_:)), enabled: !focusedIsParent))
            menu.addItem(openWithItem())
            menu.addItem(.separator())
            menu.addItem(item("View  (F3)", #selector(menuView(_:)), enabled: hasSelection))
            menu.addItem(item("Edit  (F4)", #selector(menuEdit(_:)), enabled: hasSelection))
            menu.addItem(item("Rename  (F2)", #selector(menuRename(_:)), enabled: !focusedIsParent))
            menu.addItem(.separator())
            menu.addItem(item("Copy to Other Panel  (F5)", #selector(menuCopy(_:)), enabled: hasSelection))
            menu.addItem(item("Move to Other Panel  (F6)", #selector(menuMove(_:)), enabled: hasSelection))
            menu.addItem(item("Duplicate  (F11)", #selector(menuDuplicate(_:)), enabled: hasSelection))
            menu.addItem(.separator())
            menu.addItem(item("Move to Trash  (F8)", #selector(menuTrash(_:)), enabled: hasSelection))
            menu.addItem(item("Delete Permanently  (⇧F8)", #selector(menuDeleteHard(_:)), enabled: hasSelection))
            menu.addItem(.separator())
            menu.addItem(item("New Folder  (F7)", #selector(menuNewFolder(_:))))
            menu.addItem(item("Refresh  (⌘R)", #selector(menuRefresh(_:))))
            menu.addItem(.separator())
            menu.addItem(item("Get Info", #selector(menuInfo(_:)), enabled: hasSelection))
            menu.addItem(item("Reveal in Finder", #selector(menuReveal(_:)), enabled: hasSelection))
            menu.addItem(item("Copy Full Path", #selector(menuCopyPath(_:)), enabled: hasSelection))
            menu.addItem(.separator())
            menu.addItem(item("Select All  (⌘A)", #selector(menuSelectAll(_:))))
            menu.addItem(item("Select None", #selector(menuSelectNone(_:))))
            menu.addItem(item("Invert Selection", #selector(menuInvertSelection(_:))))
            menu.addItem(item("Select Group…", #selector(menuSelectGroup(_:))))
            menu.addItem(item("Unselect Group…", #selector(menuUnselectGroup(_:))))
            menu.addItem(.separator())
            menu.addItem(item("Sort By", #selector(menuNoop(_:)), enabled: false))
            menu.addItem(sortItem())
            menu.addItem(.separator())
            menu.addItem(item("Pack into Archive…   (⌥F5)", #selector(menuPack(_:)),
                              enabled: hasSelection && !onMain { parent.panel.isBrowsingArchive }))
            menu.addItem(item("Extract to Other Pane (⌥F9)", #selector(menuExtract(_:)),
                              enabled: hasSelection && onMain { parent.panel.isBrowsingArchive }))
            menu.addItem(item("Multi-Rename…        (⌃M)", #selector(menuMultiRename(_:)), enabled: hasSelection))
            menu.addItem(item("Quick Look           (⌘Y)", #selector(menuQuickLook(_:)), enabled: hasSelection))
            menu.addItem(item("Compare Directories…  (F9)", #selector(menuCompare(_:))))
            if let archive = focusedArchiveURL {
                menu.addItem(item("Test “\(archive.lastPathComponent)”",
                                  #selector(menuVerify(_:)), enabled: true))
            }
            menu.addItem(.separator())
            menu.addItem(item("Show Hidden Files", #selector(menuToggleHidden(_:)),
                              enabled: true,
                              checked: onMain { AppModel.shared.showHidden }))
            menu.addItem(item("Show Sizes in Bytes", #selector(menuToggleBytes(_:)),
                              enabled: true,
                              checked: onMain { AppModel.shared.showBytes }))
        }

        /// The archive the cursor is on, or the one being browsed.
        private var focusedArchiveURL: URL? {
            let modelItems = items
            if let table {
                let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
                if row >= 0, row < modelItems.count {
                    let item = modelItems[row]
                    if let member = item.archive { return member.archiveURL }
                    if ArchiveService.isArchive(item.url) { return item.url }
                }
            }
            return onMain { parent.panel.archive?.archiveURL }
        }

        private func item(_ title: String, _ selector: Selector, enabled: Bool = true,
                          checked: Bool = false, key: String = "") -> NSMenuItem {
            let menuItem = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            menuItem.target = self
            menuItem.isEnabled = enabled
            menuItem.state = checked ? .on : .off
            if !key.isEmpty { menuItem.title = title }
            return menuItem
        }

        private func openWithItem() -> NSMenuItem {
            let submenu = NSMenu()
            let modelItems = items
            guard let table, table.clickedRow >= 0, table.clickedRow < modelItems.count else {
                return item("Open With", #selector(menuNoop(_:)), enabled: false)
            }
            let url = modelItems[table.clickedRow].url
            let applications = NSWorkspace.shared.urlsForApplications(toOpen: url).prefix(10)
            if applications.isEmpty {
                return item("Open With", #selector(menuNoop(_:)), enabled: false)
            }
            for application in applications {
                let name = application.deletingPathExtension().lastPathComponent
                let menuItem = NSMenuItem(title: name, action: #selector(menuOpenWith(_:)), keyEquivalent: "")
                menuItem.target = self
                menuItem.representedObject = application
                submenu.addItem(menuItem)
            }
            let host = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
            host.submenu = submenu
            return host
        }

        private func sortItem() -> NSMenuItem {
            let submenu = NSMenu()
            let spec = onMain { parent.panel.sortSpec }
            for key in SortKey.allCases {
                let menuItem = NSMenuItem(title: key.title, action: #selector(menuSortBy(_:)), keyEquivalent: "")
                menuItem.target = self
                menuItem.representedObject = key.rawValue
                menuItem.state = spec.key == key ? .on : .off
                submenu.addItem(menuItem)
            }
            submenu.addItem(.separator())
            let ascending = NSMenuItem(title: "Ascending", action: #selector(menuSortDirection(_:)), keyEquivalent: "")
            ascending.target = self
            ascending.state = spec.ascending ? .on : .off
            submenu.addItem(ascending)

            let host = NSMenuItem(title: "Sort By", action: nil, keyEquivalent: "")
            host.submenu = submenu
            return host
        }

        // MARK: Menu actions

        @objc private func menuNoop(_ sender: Any?) {}

        @objc private func menuOpenNewTab(_ sender: Any?) {
            withApp { $0.newTabFromFocusedFolder() }
        }

        @objc private func menuView(_ sender: Any?) { withApp { $0.viewFocused() } }
        @objc private func menuEdit(_ sender: Any?) { withApp { $0.editFocused() } }
        @objc private func menuRename(_ sender: Any?) {
            guard let table else { return }
            beginRename(row: table.clickedRow >= 0 ? table.clickedRow : table.selectedRow)
        }
        @objc private func menuCopy(_ sender: Any?) { withApp { $0.copyToOtherPanel() } }
        @objc private func menuMove(_ sender: Any?) { withApp { $0.moveToOtherPanel() } }
        @objc private func menuDuplicate(_ sender: Any?) { withApp { $0.duplicateSelection() } }
        @objc private func menuTrash(_ sender: Any?) { withApp { $0.deleteFocused(permanent: false) } }
        @objc private func menuDeleteHard(_ sender: Any?) { withApp { $0.deleteFocused(permanent: true) } }
        @objc private func menuNewFolder(_ sender: Any?) { withApp { $0.createNewFolder() } }
        @objc private func menuRefresh(_ sender: Any?) { withApp { $0.refreshActive() } }
        @objc private func menuReveal(_ sender: Any?) {
            withApp { app in app.revealInFinder(app.activePanel.operationTargets.map(\.url)) }
        }
        @objc private func menuCopyPath(_ sender: Any?) { withApp { $0.copyPathsToClipboard() } }
        @objc private func menuSelectAll(_ sender: Any?) { withApp { $0.selectAll() } }
        @objc private func menuSelectNone(_ sender: Any?) { withApp { $0.selectNone() } }
        @objc private func menuInvertSelection(_ sender: Any?) { withApp { $0.invertSelection() } }
        @objc private func menuSelectGroup(_ sender: Any?) { withApp { $0.selectByMask() } }
        @objc private func menuUnselectGroup(_ sender: Any?) { withApp { $0.deselectByMask() } }
        @objc private func menuToggleHidden(_ sender: Any?) { withApp { $0.toggleHidden() } }
        @objc private func menuToggleBytes(_ sender: Any?) { withApp { $0.toggleBytes() } }
        @objc private func menuPack(_ sender: Any?) { withApp { $0.packSelection() } }
        @objc private func menuExtract(_ sender: Any?) { withApp { $0.extractToOtherPanel() } }
        @objc private func menuMultiRename(_ sender: Any?) { withApp { $0.openMultiRename() } }
        @objc private func menuQuickLook(_ sender: Any?) { withApp { $0.quickLook() } }
        @objc private func menuCompare(_ sender: Any?) { withApp { $0.openCompareWindow() } }
        @objc private func menuVerify(_ sender: Any?) { withApp { $0.verifyArchive() } }

        @objc private func menuInfo(_ sender: Any?) {
            guard let table else { return }
            let modelItems = items
            let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
            guard row >= 0, row < modelItems.count else { return }
            let item = modelItems[row]
            withApp { $0.getInfo(item) }
        }

        @objc private func menuOpenWith(_ sender: Any?) {
            guard let menuItem = sender as? NSMenuItem,
                  let application = menuItem.representedObject as? URL else { return }
            withApp { $0.openWith(application) }
        }

        @objc private func menuSortBy(_ sender: Any?) {
            guard let menuItem = sender as? NSMenuItem,
                  let raw = menuItem.representedObject as? String,
                  let key = SortKey(rawValue: raw) else { return }
            onMain { parent.panel.toggleSort(key: key) }
        }

        @objc private func menuSortDirection(_ sender: Any?) {
            onMain {
                let spec = parent.panel.sortSpec
                parent.panel.setSort(key: spec.key, ascending: !spec.ascending)
            }
        }
    }
}
