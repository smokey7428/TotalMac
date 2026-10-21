import SwiftUI
import AppKit

// MARK: - The popup shown when you click the location name

struct LocationMenuContent: View {

    @EnvironmentObject private var app: AppModel
    let side: PanelSide

    var body: some View {
        let nodes = app.favorites.items

        if nodes.isEmpty {
            Button("No favorites yet") {}.disabled(true)
        } else {
            ForEach(nodes) { node in
                nodeView(node)
            }
        }

        if nodes.contains(where: { $0.isGroup }) || nodes.isEmpty {
            Divider()
        }

        Menu("Volumes") { volumeItems }

        Menu("History") { historyItems }

        Divider()

        Button("Add Current Folder to Favorites…  (⇧⌘D)") {
            app.addCurrentFolderToFavorites()
        }
        Button("Choose Volume…  (⌥F1 / ⌥F2)") {
            app.chooseVolume(for: side)
        }
        Button("Edit Favorites…  (⌘D)") {
            app.openFavorites(for: side)
        }
    }

    // Recursion needs a type eraser: `some View` cannot refer to itself.
    private func nodeView(_ node: FavoriteItem) -> AnyView {
        if node.isGroup {
            return AnyView(Menu(node.title) {
                if node.children.isEmpty {
                    Button("Empty group") {}.disabled(true)
                } else {
                    ForEach(node.children) { child in
                        nodeView(child)
                    }
                }
            })
        }
        return AnyView(Button(node.title) {
            app.go(to: node.path, side: side)
        })
    }

    @ViewBuilder
    private var volumeItems: some View {
        ForEach(app.volumes) { volume in
            Button {
                app.go(to: volume.url.path, side: side)
            } label: {
                Label("\(volume.displayName)  —  \(volume.capacityText.isEmpty ? volume.subtitle : volume.capacityText)",
                      systemImage: volume.symbolName)
            }
        }
        Divider()
        Button("Refresh Volumes") { app.refreshVolumes() }
        Button("Choose Volume…") { app.chooseVolume(for: side) }
    }

    @ViewBuilder
    private var historyItems: some View {
        let panel = app.panel(for: side)
        let back = Array(panel.tab.back.suffix(12).reversed())
        if back.isEmpty {
            Button("Nothing yet") {}.disabled(true)
        } else {
            ForEach(Array(back.enumerated()), id: \.offset) { _, location in
                Button(location.displayPath) {
                    panel.go(to: location)
                }
            }
        }
    }
}

// MARK: - The favorites window (Total Commander's directory hotlist)

struct FavoritesWindow: View {

    @EnvironmentObject private var app: AppModel
    @State private var selection: UUID?
    @State private var search = ""
    @State private var onlyExisting = false

    private var rows: [FavoriteRow] {
        var all = app.favorites.flattened()
        if onlyExisting {
            all = all.filter { row in
                guard let item = app.favorites.item(id: row.id) else { return true }
                return item.isGroup || item.exists
            }
        }
        let needle = search.trimmingCharacters(in: .whitespaces)
        if !needle.isEmpty {
            all = all.filter {
                $0.title.localizedCaseInsensitiveContains(needle)
                    || $0.path.localizedCaseInsensitiveContains(needle)
            }
        }
        return all
    }

    private var selectedRow: FavoriteRow? {
        guard let selection else { return nil }
        return app.favorites.flattened().first { $0.id == selection }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            table
            Divider()
            footer
        }
        .frame(minWidth: 620, minHeight: 420)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "star.fill").foregroundStyle(.yellow)
            Text("Favorites").font(.headline)
            Text("for the \(app.favoritesSide == .left ? "left" : "right") pane")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Toggle("Only existing", isOn: $onlyExisting).toggleStyle(.checkbox)
            TextField("Search", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)
        }
        .padding(10)
    }

    private var table: some View {
        Table(rows, selection: $selection) {
            TableColumn("Name") { row in
                HStack(spacing: 5) {
                    Spacer().frame(width: CGFloat(row.depth) * 14)
                    Button {
                        goTo(row)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: row.isGroup ? "folder" : "folder.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(row.isGroup ? Color.accentColor : Color.secondary)
                            Text(row.title)
                                .font(.system(size: 11.5, weight: row.isGroup ? .semibold : .regular))
                        }
                    }
                    .buttonStyle(.borderless)
                    .help("Go to \(row.path.isEmpty ? row.title : row.path)")
                }
            }
            .width(min: 160, ideal: 240)

            TableColumn("Folder") { row in
                if row.isGroup {
                    Text(row.path.isEmpty ? "—" : row.path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                } else {
                    Text(row.path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(missing(row) ? Color.red : Color.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    private func missing(_ row: FavoriteRow) -> Bool {
        guard let item = app.favorites.item(id: row.id), !item.isGroup else { return false }
        return !item.exists
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                if let row = selectedRow { goTo(row) }
            } label: {
                Label("Go", systemImage: "arrow.right.circle")
            }
            .disabled(selection == nil || (selectedRow?.isGroup ?? true))

            Divider().frame(height: 18)

            Button {
                app.addCurrentFolderToFavorites()
            } label: {
                Label("Add Current Folder", systemImage: "plus")
            }
            .help("Add the folder the \(app.favoritesSide == .left ? "left" : "right") pane is showing")

            Button {
                addSubfolder()
            } label: {
                Label("Add Inside Group", systemImage: "plus.rectangle.on.folder")
            }
            .disabled(selectedRow?.isGroup != true)
            .help("Add the current folder inside the selected group")

            Button {
                newGroup()
            } label: {
                Label("New Group", systemImage: "folder.badge.plus")
            }

            Divider().frame(height: 18)

            Button {
                edit()
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .disabled(selection == nil)

            Button {
                if let selection {
                    app.favorites.remove(id: selection)
                    self.selection = nil
                }
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(selection == nil)

            Button {
                if let selection { app.favorites.move(id: selection, offset: -1) }
            } label: {
                Image(systemName: "arrow.up")
            }
            .disabled(selection == nil)

            Button {
                if let selection { app.favorites.move(id: selection, offset: 1) }
            } label: {
                Image(systemName: "arrow.down")
            }
            .disabled(selection == nil)

            Spacer()

            Text("\(rows.count) entries")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
        .padding(10)
    }

    // MARK: - Actions

    private func goTo(_ row: FavoriteRow) {
        guard !row.isGroup, !row.path.isEmpty else { return }
        app.go(to: row.path, side: app.favoritesSide)
    }

    private func addSubfolder() {
        guard let groupID = selection, selectedRow?.isGroup == true else { return }
        let panel = app.panel(for: app.favoritesSide)
        let title = panel.url.lastPathComponent.isEmpty ? "Computer" : panel.url.lastPathComponent
        app.addFavorite(path: panel.displayPath, suggestedTitle: title, into: groupID)
    }

    private func newGroup() {
        guard let input = FavoriteEditor.prompt(title: "New group",
                                                nameLabel: "Name",
                                                name: "",
                                                pathLabel: nil,
                                                path: "") else { return }
        let groupID = selectedRow?.isGroup == true ? selection : nil
        app.favorites.addGroup(title: input.name.isEmpty ? "New group" : input.name, into: groupID)
    }

    private func edit() {
        guard let row = selectedRow else { return }
        guard let input = FavoriteEditor.editPrompt(title: row.isGroup ? "Edit group" : "Edit favorite",
                                                    name: row.title,
                                                    path: row.isGroup ? nil : row.path) else { return }
        app.favorites.update(id: row.id,
                             title: input.name,
                             path: input.path)
    }
}

/// Small AppKit prompts used by the favorites window.
enum FavoriteEditor {

    static func editPrompt(title: String, name: String, path: String?) -> (name: String, path: String)? {
        guard let result = prompt(title: title,
                                  nameLabel: "Name",
                                  name: name,
                                  pathLabel: path == nil ? nil : "Folder",
                                  path: path ?? "") else { return nil }
        return (result.name, result.path)
    }

    static func prompt(title: String,
                       nameLabel: String,
                       name: String,
                       pathLabel: String?,
                       path: String) -> (name: String, path: String)? {

        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8

        let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 22))
        nameField.stringValue = name
        stack.addArrangedSubview(labelled(nameLabel, nameField))

        var pathField: NSTextField?
        if let pathLabel {
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 22))
            field.stringValue = path
            field.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            stack.addArrangedSubview(labelled(pathLabel, field))
            pathField = field
        }

        stack.frame = NSRect(x: 0, y: 0, width: 340, height: pathField == nil ? 48 : 80)
        alert.accessoryView = stack
        alert.window.initialFirstResponder = nameField

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return (nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                pathField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    }

    private static func labelled(_ text: String, _ field: NSTextField) -> NSStackView {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [label, field])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        return stack
    }
}

// MARK: - Volume chooser (Total Commander's Alt+F1 / Alt+F2)

struct VolumeChooserSheet: View {

    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    let request: VolumeChooserRequest

    @State private var selection: String?

    private var sideName: String { request.side == .left ? "left" : "right" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "externaldrive.connected.to.line.below")
                    .foregroundStyle(Color.accentColor)
                Text("Choose a drive for the \(sideName) pane").font(.headline)
                Spacer()
                Button {
                    app.refreshVolumes()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Rescan the mounted volumes")
            }
            .padding(12)

            Divider()

            List(app.volumes, selection: $selection) { volume in
                HStack(spacing: 10) {
                    Image(nsImage: volume.icon)
                        .resizable()
                        .frame(width: 22, height: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(volume.displayName)
                                .font(.system(size: 12.5, weight: volume.isExternal ? .semibold : .regular))
                            if volume.isExternal {
                                Text(volume.subtitle)
                                    .font(.system(size: 9, weight: .medium))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                            }
                            if volume.isReadOnly {
                                Text("read only")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(volume.capacityText.isEmpty ? volume.url.path : "\(volume.url.path)  ·  \(volume.capacityText)")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    if volume.isEjectable, !volume.isRoot {
                        Button {
                            app.ejectVolume(volume)
                        } label: {
                            Label("Eject", systemImage: "eject")
                        }
                        .controlSize(.small)
                        .help("Unmount and eject \(volume.displayName)")
                    }
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { choose(volume) }
            }
            .frame(minHeight: 220)

            Divider()

            HStack {
                Text(app.volumes.isEmpty
                     ? "No volumes found."
                     : "\(app.volumes.count) volume\(app.volumes.count == 1 ? "" : "s") mounted")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Open in \(sideName) pane") {
                    if let volume = app.volumes.first(where: { $0.id == selection }) {
                        choose(volume)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(selection == nil)
            }
            .padding(12)
        }
        .frame(width: 540, height: 380)
        .onAppear {
            if selection == nil {
                selection = app.volume(for: request.side)?.id ?? app.volumes.first?.id
            }
        }
    }

    private func choose(_ volume: Volume) {
        app.go(to: volume.url.path, side: request.side)
        dismiss()
    }
}
