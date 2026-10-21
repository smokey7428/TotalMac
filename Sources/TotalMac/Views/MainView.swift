import SwiftUI
import AppKit

struct MainView: View {

    @EnvironmentObject private var app: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                PanelView(panel: app.left, side: .left)
                    .frame(minWidth: 300, idealWidth: 620)
                PanelView(panel: app.right, side: .right)
                    .frame(minWidth: 300, idealWidth: 620)
            }
            Divider()
            statusStrip
            FunctionKeyBar()
        }
        .frame(minWidth: 940, minHeight: 520)
        .toolbar { toolbarContent }
        .sheet(item: $app.pendingTransfer) { request in
            TransferSheet(request: request)
                .environmentObject(app)
        }
        .sheet(item: $app.pendingPack) { request in
            PackSheet(request: request)
                .environmentObject(app)
        }
        .sheet(isPresented: $app.showSync) {
            SyncSheet(left: app.left.targetDirectory, right: app.right.targetDirectory)
                .environmentObject(app)
        }
        .sheet(isPresented: $app.showMultiRename) {
            MultiRenameSheet(items: app.activePanel.operationTargets)
                .environmentObject(app)
        }
        .sheet(item: $app.volumeChooser) { request in
            VolumeChooserSheet(request: request)
                .environmentObject(app)
        }
        .sheet(item: $app.infoItem) { item in
            InfoSheet(item: item)
                .environmentObject(app)
        }
        .sheet(isPresented: $app.showHelp) {
            HelpSheet()
        }
        .onChange(of: app.viewerRequest) { _, request in
            if let request {
                openWindow(id: "viewer", value: request)
            }
        }
        .onChange(of: app.showAbout) { _, shouldShow in
            if shouldShow {
                openWindow(id: "about")
                app.showAbout = false
            }
        }
        .onChange(of: app.showFavorites) { _, shouldShow in
            if shouldShow {
                openWindow(id: "favorites")
                app.showFavorites = false
            }
        }
        .onChange(of: app.showVersions) { _, shouldShow in
            if shouldShow {
                openWindow(id: "versions")
                app.showVersions = false
            }
        }
    }

    private var statusStrip: some View {
        HStack(spacing: 10) {
            OperationProgressView(operations: app.operations)
            Spacer()
            if let clipboardCount = app.clipboard.isEmpty ? nil : app.clipboard.count {
                Label("\(clipboardCount) on clipboard\(app.clipboardIsCut ? " (cut)" : "")",
                      systemImage: "doc.on.clipboard")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                app.openFavorites()
            } label: {
                Image(systemName: "star")
            }
            .help("Favorites (⌘D)")

            Menu {
                LocationMenuContent(side: app.activeSide)
                    .environmentObject(app)
            } label: {
                Image(systemName: "externaldrive.connected.to.line.below")
            }
            .help("Volumes, favorites and history")

            Button {
                app.chooseVolume(for: app.activeSide)
            } label: {
                Image(systemName: "externaldrive.fill")
            }
            .help("Choose a drive for the active pane (⌥F1 for left, ⌥F2 for right)")

            Button {
                app.newTab()
            } label: { Image(systemName: "plus.rectangle.on.folder") }
                .help("New tab (⌘T)")

            Button {
                app.closeTab()
            } label: { Image(systemName: "xmark.rectangle") }
                .help("Close tab (⌘W)")
                .disabled(app.activePanel.tabs.count < 2)

            Button {
                app.refreshActive()
            } label: { Image(systemName: "arrow.clockwise") }
                .help("Refresh (⌘R)")

            Button {
                app.swapPanels()
            } label: { Image(systemName: "rectangle.2.swap") }
                .help("Swap the two panes")

            Toggle(isOn: Binding(get: { app.showHidden }, set: { _ in app.toggleHidden() })) {
                Image(systemName: "eye")
            }
            .help("Show hidden files (⇧⌘.)")

            Toggle(isOn: Binding(get: { app.showBytes }, set: { _ in app.toggleBytes() })) {
                Image(systemName: "number")
            }
            .help("Show exact byte counts")

            Menu {
                ForEach(SortKey.allCases) { key in
                    Button {
                        app.activePanel.toggleSort(key: key)
                    } label: {
                        Label(key.title,
                              systemImage: app.activePanel.sortSpec.key == key
                                ? (app.activePanel.sortSpec.ascending ? "chevron.up" : "chevron.down")
                                : "")
                    }
                }
                Divider()
                Button("Directories first") { }
                    .disabled(true)
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }
            .help("Sort order")

            Menu {
                Button("Compare & synchronise panes…  (F9)") { app.openCompareWindow() }
                Button("Multi-rename tool…  (⌃M)") { app.openMultiRename() }
                Divider()
                Button("Pack selection into archive…  (⌥F5)") { app.packSelection() }
                Button("Extract to the other pane  (⌥F9)") { app.extractToOtherPanel() }
                Button("Test archive  (⇧F9)") { app.verifyArchive() }
                Divider()
                Button("Quick Look  (⌘Y)") { app.quickLook() }
            } label: {
                Image(systemName: "wrench.and.screwdriver")
            }
            .help("Tools")

            Button {
                app.showAbout = true
            } label: { Image(systemName: "info.circle") }
                .help("About TotalMac")

            Button {
                app.showHelp = true
            } label: { Image(systemName: "questionmark.circle") }
                .help("Keyboard reference (F1)")
        }
    }
}

/// Watches the operation queue directly so the progress HUD really ticks.
struct OperationProgressView: View {

    @ObservedObject var operations: OperationCenter
    @EnvironmentObject private var app: AppModel

    var body: some View {
        // A timeline view ticks every second even when the engine has nothing new
        // to say, so a stalled destination becomes visible instead of looking like
        // a frozen app.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Group {
                if let progress = operations.progress {
                    running(progress, now: context.date)
                } else {
                    idle
                }
            }
        }
    }

    private func running(_ progress: OpProgress, now: Date) -> some View {
        let stalled = now.timeIntervalSince(progress.updatedAt) > 8
        return HStack(spacing: 10) {
            if progress.isIndeterminate {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 160)
            } else {
                ProgressView(value: progress.fraction)
                    .progressViewStyle(.linear)
                    .frame(width: 160)
            }

            Text("\(progress.title) — \(progress.detail)")
                .lineLimit(1)
                .truncationMode(.middle)
                .font(.system(size: 11))

            if progress.bytesTotal > 0 {
                Text("\(ByteFormatter.string(progress.bytesDone)) / \(ByteFormatter.string(progress.bytesTotal))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            if stalled {
                Text(progress.isStalled
                     ? "waiting for the drive — no progress for \(Int(now.timeIntervalSince(progress.updatedAt))) s"
                     : "waiting for the drive…")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.orange)
            } else {
                if !progress.rateText.isEmpty {
                    Text(progress.rateText)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                if !progress.etaText.isEmpty {
                    Text(progress.etaText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            if stalled {
                Button("Force Stop") { confirmForceStop() }
                    .controlSize(.small)
                    .help("Stop waiting for the destination and free the app")
            } else {
                Button("Cancel") { operations.cancel() }
                    .controlSize(.small)
            }
        }
    }

    private var idle: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(app.statusMessage ?? "Active pane: \(app.activeSide == .left ? "left" : "right")  ·  Tab switches panes  ·  ⌘D favorites  ·  F1 help")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func confirmForceStop() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Stop waiting for the destination?"
        alert.informativeText = """
        The drive has not reported progress for a while. It may be busy, or it may \
        have stopped responding.

        Forcing a stop frees the app immediately, but the transfer itself may still \
        be running in the background and the file at the destination is likely to be \
        incomplete. Reconnect the drive and try again if in doubt.
        """
        alert.addButton(withTitle: "Force Stop")
        alert.addButton(withTitle: "Keep Waiting")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        operations.forceStop()
    }
}

struct FunctionKeyBar: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        HStack(spacing: 1) {
            key("F1", "Help") { app.showHelp = true }
            key("F2", "Rename") { app.beginRenameOnCursor() }
            key("F3", "View") { app.viewFocused() }
            key("F4", "Edit") { app.editFocused() }
            key("F5", "Copy") { app.copyToOtherPanel() }
            key("F6", "Move") { app.moveToOtherPanel() }
            key("F7", "New folder") { app.createNewFolder() }
            key("F8", "Delete") { app.deleteFocused(permanent: false) }
            key("⇧F8", "Destroy") { app.deleteFocused(permanent: true) }
            key("F9", "Compare") { app.openCompareWindow() }
            key("⌥F5", "Pack") { app.packSelection() }
            key("⌃M", "Multi-rename") { app.openMultiRename() }
            key("F11", "Duplicate") { app.duplicateSelection() }
        }
        .frame(height: 34)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func key(_ shortcut: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 0) {
                Text(shortcut)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 10.5))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .trailing) { Divider() }
    }
}

// MARK: - Copy / move dialog

struct TransferSheet: View {

    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    let request: TransferRequest

    @State private var destination: String
    @State private var move: Bool

    init(request: TransferRequest) {
        self.request = request
        _destination = State(initialValue: request.destination)
        _move = State(initialValue: request.move)
    }

    private var expandedDestination: String {
        (destination as NSString).expandingTildeInPath
    }

    private var totalBytes: Int64 {
        request.sources.reduce(0) { $0 + ($1.isDirectory ? 0 : $1.size) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: move ? "arrow.right.square" : "doc.on.doc")
                    .foregroundStyle(Color.accentColor)
                Text(move ? "Move" : "Copy")
                    .font(.headline)
                Text("\(request.sources.count) item\(request.sources.count == 1 ? "" : "s")")
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Destination folder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    TextField("Destination", text: $destination)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                    Button("Browse…") { browse() }
                        .controlSize(.small)
                }
                Text(expandedDestination)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            HStack(spacing: 10) {
                Button {
                    destination = app.inactivePanel.url.path + "/"
                } label: {
                    Label("Other pane", systemImage: "rectangle.2.swap")
                }
                .controlSize(.small)
                Button {
                    destination = app.activePanel.url.path + "/"
                } label: {
                    Label("This folder", systemImage: "folder")
                }
                .controlSize(.small)
                Button {
                    destination = FileManager.default.homeDirectoryForCurrentUser.path + "/"
                } label: {
                    Label("Home", systemImage: "house")
                }
                .controlSize(.small)
            }

            Toggle(isOn: $move) {
                Text(move ? "Move the originals (delete source)" : "Keep the originals (copy)")
            }
            .toggleStyle(.checkbox)

            Divider()

            VStack(alignment: .leading, spacing: 2) {
                Text("Items")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(request.sources.prefix(200)) { item in
                            HStack(spacing: 6) {
                                Image(systemName: item.isDirectory ? "folder" : "doc")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                                Text(item.name)
                                    .font(.system(size: 11))
                                Spacer()
                                Text(item.isDirectory ? "<DIR>" : ByteFormatter.string(item.size))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if request.sources.count > 200 {
                            Text("… and \(request.sources.count - 200) more")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(height: 120)
            }

            HStack {
                Text(totalBytes > 0 ? "About \(ByteFormatter.string(totalBytes)) of file data" : "Folders are processed recursively")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(move ? "Move" : "Copy") {
                    var updated = request
                    updated.destination = expandedDestination
                    updated.move = move
                    dismiss()
                    app.performTransfer(updated)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 560)
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: expandedDestination)
        if panel.runModal() == .OK, let url = panel.url {
            destination = url.path + "/"
        }
    }
}

// MARK: - Get info

struct InfoSheet: View {

    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    let item: FileItem

    @State private var folderSize: String = "calculating…"
    @State private var fileCount: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                    .resizable()
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name).font(.headline).lineLimit(1)
                    Text(item.kind).font(.caption).foregroundStyle(.secondary)
                }
            }

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 5) {
                if let member = item.archive {
                    row("Archive", member.archiveURL.path)
                    row("Member", member.memberPath)
                } else {
                    row("Path", item.url.path)
                }
                row("Permissions", item.permissions)
                row("Attribute", item.attr)
                if item.isArchiveMember {
                    row("Size", "\(ByteFormatter.grouped(item.size)) bytes (\(ByteFormatter.string(item.size)))")
                } else if item.isDirectory {
                    row("Contains", "\(fileCount) files, \(folderSize)")
                } else {
                    row("Size", "\(ByteFormatter.grouped(item.size)) bytes (\(ByteFormatter.string(item.size)))")
                }
                if let modified = item.modified { row("Modified", DateFormatter.long(modified)) }
                if let created = item.created { row("Created", DateFormatter.long(created)) }
                if item.isSymlink,
                   let target = item.archive?.symlinkTarget
                    ?? (try? FileManager.default.destinationOfSymbolicLink(atPath: item.url.path)) {
                    row("Target", target)
                }
                if !item.isArchiveMember,
                   let free = FileSystemService.freeSpace(at: item.url.deletingLastPathComponent()) {
                    row("Volume free", ByteFormatter.string(free))
                }
            }

            Spacer(minLength: 0)

            HStack {
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.url.path, forType: .string)
                }
                Button("Reveal in Finder") {
                    app.revealInFinder([item.url])
                }
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 520)
        .task {
            guard !item.isArchiveMember else {
                folderSize = "—"
                fileCount = 0
                return
            }
            guard item.isDirectory else {
                folderSize = ByteFormatter.string(item.size)
                fileCount = item.size > 0 ? 1 : 0
                return
            }
            let url = item.url
            let measured = await Task.detached(priority: .utility) {
                FileSystemService.measure(url)
            }.value
            folderSize = ByteFormatter.string(measured.bytes)
            fileCount = measured.files
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .font(.system(size: 11.5, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(3)
                .truncationMode(.middle)
        }
    }
}

// MARK: - Help

struct HelpSheet: View {

    @Environment(\.dismiss) private var dismiss

    private let shortcuts: [(String, String)] = [
        ("Tab", "Switch the active pane"),
        ("⌘D", "Favorites window (Total Commander's directory hotlist)"),
        ("⇧⌘D", "Add the folder of the active pane to the favorites"),
        ("Click the location name", "Favorites, volumes and history for that pane"),
        ("⌥F1 / ⌥F2", "Choose a drive for the left / right pane (eject externals there)"),
        ("Enter / double click", "Open folder, or open file with its default app"),
        ("Space", "Select the item under the cursor and step down"),
        ("Backspace", "Go to the parent folder"),
        ("F1", "This help"),
        ("F2 / ⇧F6", "Rename in place (inline edit, Esc cancels)"),
        ("F3", "View file (text / hex / image / PDF)"),
        ("F4", "Edit file with its default editor"),
        ("F5", "Copy selection to the other pane…"),
        ("F6", "Move selection to the other pane…"),
        ("F7", "New folder"),
        ("F8", "Move selection to the Trash"),
        ("⇧F8", "Delete permanently (asks first)"),
        ("⌘⇧F8", "Copy full paths"),
        ("F9", "Compare & synchronise the two panes"),
        ("⇧F9", "Test the archive under the cursor (CRC check)"),
        ("⌥F5", "Pack the selection into a new archive…"),
        ("⌥F9", "Extract the archive selection to the other pane"),
        ("⌃M or ⇧F4", "Multi-rename tool with counters and masks"),
        ("⌘Y", "Quick Look for the selection"),
        ("F11", "Duplicate selection in place"),
        ("Enter on an archive", "Browse inside a ZIP/TAR/7z in the pane itself"),
        ("⌘T / ⌘W", "New tab / close tab"),
        ("⌘1 … ⌘9", "Jump to a tab in the active pane"),
        ("⌘[ / ⌘]", "Back / forward in history"),
        ("⌘↑", "Parent folder"),
        ("⇧⌘H", "Home folder"),
        ("⌘R", "Refresh both panes"),
        ("⌘F", "Quick filter with * and ? wildcards"),
        ("⌘A / ⌘⇧A", "Select all / select none"),
        ("⇧⌘I", "Invert selection"),
        ("⌘C / ⌘X / ⌘V", "Internal clipboard copy / cut / paste"),
        ("⇧⌘U", "Swap the two panes"),
        ("⇧⌘.", "Show hidden files"),
        ("⇧⌘B", "Show exact byte sizes"),
        ("⌥⌘I", "Get info on the selection"),
        ("⌘↑↑", "—"),
        ("Drag & drop", "Drop onto a folder row to drop inside it. Plain drag moves inside one volume, ⌥ copies, ⌘ moves. Drop onto an archive to copy files into it."),
        ("Double click column header", "Sort by that column (click again to reverse)"),
        ("Space", "Mark and step down — use ⌘Y for Quick Look, like in Total Commander")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "keyboard")
                Text("TotalMac keyboard reference").font(.headline)
            }
            ScrollView {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 4) {
                    ForEach(Array(shortcuts.enumerated()), id: \.offset) { _, entry in
                        GridRow {
                            Text(entry.0)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Color.accentColor)
                            Text(entry.1)
                                .font(.system(size: 11))
                        }
                    }
                }
                .padding(.trailing, 12)
            }
            .frame(height: 340)
            HStack {
                Text("TotalMac — a dual pane file manager in the spirit of Total Commander")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 560)
    }
}
