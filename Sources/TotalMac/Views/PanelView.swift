import SwiftUI
import AppKit

struct PanelView: View {

    @ObservedObject var panel: PanelModel
    @EnvironmentObject private var app: AppModel

    let side: PanelSide

    @State private var pathText: String = ""
    @State private var filterText: String = ""
    @State private var showFilter = false
    @FocusState private var pathFocused: Bool
    @FocusState private var filterFocused: Bool

    private var isActive: Bool { app.activeSide == side }

    var body: some View {
        VStack(spacing: 0) {
            accentBar
            tabStrip
            pathBar
            if showFilter { filterBar }
            fileList
            statusBar
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .onAppear { pathText = panel.displayPath }
        .onChange(of: panel.url) { _, _ in
            pathText = panel.displayPath
        }
        .onChange(of: panel.tab.archive) { _, _ in
            pathText = panel.displayPath
        }
        .onChange(of: app.showHidden) { _, _ in
            panel.showHidden = app.showHidden
        }
        .onChange(of: app.showBytes) { _, _ in
            panel.showBytes = app.showBytes
        }
        .onChange(of: app.filterFocusRequest) { _, _ in
            guard isActive else { return }
            showFilter = true
            filterFocused = true
        }
    }

    // MARK: - Pieces

    private var accentBar: some View {
        Rectangle()
            .fill(isActive ? Color.accentColor : Color.clear)
            .frame(height: 2)
    }

    private var tabStrip: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    ForEach(Array(panel.tabs.enumerated()), id: \.element.id) { index, tab in
                        tabChip(index: index, tab: tab)
                    }
                }
                .padding(.horizontal, 4)
            }
            Button {
                app.setActive(side)
                panel.newTab()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.plain)
            .help("New tab (⌘T)")
            .padding(.trailing, 6)
        }
        .frame(height: 24)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func tabChip(index: Int, tab: PanelTab) -> some View {
        let selected = index == panel.activeIndex
        let title = tab.url.lastPathComponent.isEmpty ? "/" : tab.url.lastPathComponent
        return HStack(spacing: 4) {
            Image(systemName: "folder")
                .font(.system(size: 9))
            Text(title)
                .font(.system(size: 11))
                .lineLimit(1)
            if selected && panel.tabs.count > 1 {
                Button {
                    app.setActive(side)
                    panel.closeTab(at: index)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(selected ? (isActive ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.25))
                               : Color.secondary.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(selected ? Color.accentColor.opacity(0.7) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            app.setActive(side)
            panel.selectTab(index)
        }
        .help(tab.url.path)
    }

    private var pathBar: some View {
        HStack(spacing: 3) {
            locationChip
            iconButton("chevron.left", help: "Back (⌘[)", enabled: panel.canGoBack) {
                app.setActive(side); panel.goBack()
            }
            iconButton("chevron.right", help: "Forward (⌘])", enabled: panel.canGoForward) {
                app.setActive(side); panel.goForward()
            }
            iconButton("arrow.up", help: "Parent directory (Backspace)", enabled: true) {
                app.setActive(side); panel.goUp()
            }
            iconButton("arrow.clockwise", help: "Refresh (⌘R)", enabled: true) {
                app.setActive(side); panel.reload()
            }

            TextField("Path", text: $pathText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .focused($pathFocused)
                .onSubmit {
                    app.setActive(side)
                    app.openPath(pathText)
                    focusTable()
                }
                .onTapGesture { app.setActive(side) }

            iconButton(showFilter ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle",
                       help: "Quick filter (⌘F)", enabled: true) {
                showFilter.toggle()
                if showFilter { filterFocused = true } else { filterText = ""; panel.setFilter("") }
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(Color(nsColor: .windowBackgroundColor))
        .contentShape(Rectangle())
        .onTapGesture { app.setActive(side) }
    }

    /// The location name. Clicking it opens the favorites (with volumes and
    /// history), the way Total Commander's directory hotlist works.
    private var locationChip: some View {
        Menu {
            LocationMenuContent(side: side)
                .environmentObject(app)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: panel.isBrowsingArchive ? "archivebox.fill" : "folder.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                Text(locationName)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .frame(width: 148)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(isActive ? 0.18 : 0.10))
            )
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("Favorites, volumes and history — ⌘D opens the favorites list")
    }

    private var locationName: String {
        if let archive = panel.archive {
            let leaf = archive.internalPath.isEmpty
                ? ""
                : "/" + (archive.internalPath as NSString).lastPathComponent
            return archive.archiveURL.lastPathComponent + leaf
        }
        return panel.url.path == "/" ? "Computer" : panel.url.lastPathComponent
    }

    private var filterBar: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            TextField("Filter (* and ? wildcards, ; separated)", text: $filterText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($filterFocused)
                .onChange(of: filterText) { _, newValue in
                    panel.setFilter(newValue)
                }
                .onSubmit { filterFocused = false; focusTable() }
            Text("\(max(0, panel.displayItems.count - 1))")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
            Button {
                filterText = ""
                panel.setFilter("")
                showFilter = false
            } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 10))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var fileList: some View {
        FileListView(
            panel: panel,
            onActivate: { app.setActive(side) },
            onOpen: { item in
                app.setActive(side)
                panel.open(item)
            },
            onRename: { item, newName in
                app.rename(item: item, to: newName)
            },
            onDrop: { request in
                app.setActive(side)
                // Dropping onto an archive inserts the files into it.
                if let archiveTarget = request.archiveTarget {
                    app.operations.rewriteArchive(archive: archiveTarget,
                                                  removing: [],
                                                  adding: request.urls,
                                                  addingPrefix: request.archivePrefix) { _ in
                        app.afterFileOperation()
                    }
                    return
                }
                let move: Bool
                if request.modifiers.contains(.option) { move = false }
                else if request.modifiers.contains(.command) { move = true }
                else {
                    move = request.urls.first.map { FileSystemService.isSameVolume($0, request.directory) } ?? false
                }
                app.operations.transfer(sources: request.urls, destination: request.directory, move: move) { _ in
                    app.afterFileOperation()
                }
            }
        )
        .frame(minHeight: 120)
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Text(panel.statusLine)
                .foregroundStyle(.secondary)
            if !panel.sizeInfo.isEmpty {
                Divider().frame(height: 10)
                HStack(spacing: 4) {
                    if panel.isComputingSize {
                        ProgressView().controlSize(.mini).scaleEffect(0.6).frame(width: 10, height: 10)
                    }
                    Text(panel.sizeInfo)
                }
                .foregroundStyle(.secondary)
            }
            Spacer()
            if !panel.freeSpaceText.isEmpty {
                Text(panel.freeSpaceText)
                    .foregroundStyle(.secondary)
            }
            if panel.tabs.count > 1 {
                Text("tab \(panel.activeIndex + 1)/\(panel.tabs.count)")
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 10.5))
        .lineLimit(1)
        .padding(.horizontal, 6)
        .frame(height: 20)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .top) { Divider() }
    }

    /// Returns keyboard focus to the file list after using the path or filter field.
    private func focusTable() {
        guard let table = panel.table, let window = table.window else { return }
        window.makeFirstResponder(table)
    }

    private func iconButton(_ systemName: String, help: String, enabled: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 20, height: 18)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }
}
