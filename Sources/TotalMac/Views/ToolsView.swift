import SwiftUI
import AppKit

// MARK: - Pack (create an archive)

struct PackSheet: View {

    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    let request: PackRequest

    @State private var archiveName: String
    @State private var format: ArchiveFormat = .zip
    @State private var level: Double = 6

    init(request: PackRequest) {
        self.request = request
        _archiveName = State(initialValue: request.suggestedName)
    }

    private var totalBytes: Int64 {
        request.sources.reduce(0) { total, url in
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            if isDirectory.boolValue { return total }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return total + Int64(size)
        }
    }

    private var finalName: String {
        let trimmed = archiveName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        let suffix = "." + format.fileExtension
        return trimmed.lowercased().hasSuffix(suffix) ? trimmed : trimmed + suffix
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "archivebox")
                    .foregroundStyle(Color.accentColor)
                Text("Pack files")
                    .font(.headline)
                Text("\(request.sources.count) source\(request.sources.count == 1 ? "" : "s")")
                    .foregroundStyle(.secondary)
            }

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Archive name").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    TextField("name", text: $archiveName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 320)
                }
                GridRow {
                    Text("Format").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    Picker("", selection: $format) {
                        ForEach(ArchiveService.packFormats) { candidate in
                            Text(candidate.title).tag(candidate)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 320)
                }
                GridRow {
                    Text("Compression").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Slider(value: $level, in: 0...9, step: 1)
                            .frame(width: 200)
                        Text(level <= 0 ? "store" : "level \(Int(level))")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    Text("Created in").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    Text(request.destinationDirectory.path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                GridRow {
                    Text("Result").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    Text(finalName.isEmpty ? "—" : finalName)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(finalName.isEmpty ? .secondary : .primary)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 2) {
                Text("Source items")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(request.sources.prefix(200), id: \.self) { url in
                            HStack(spacing: 6) {
                                Image(systemName: "doc")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                                Text(url.lastPathComponent).font(.system(size: 11))
                                Spacer()
                            }
                        }
                    }
                }
                .frame(height: 100)
                Text(totalBytes > 0
                     ? "\(ByteFormatter.string(totalBytes)) of file data (folders are added recursively)"
                     : "Folders are added recursively")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Pack") {
                    let name = finalName
                    dismiss()
                    app.performPack(request, archiveName: name, format: format, level: Int(level))
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(finalName.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 580)
        .onChange(of: format) { _, newValue in
            // Keep the extension in step with the chosen format.
            var name = archiveName
            name = (name as NSString).deletingPathExtension
            if newValue == .tarGz { name = (name as NSString).deletingPathExtension }
            archiveName = name
        }
    }
}

// MARK: - Directory synchronisation

struct SyncSheet: View {

    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var leftPath: String
    @State private var rightPath: String
    @State private var rows: [SyncRow] = []
    @State private var isComparing = false
    @State private var statusText = "Press Compare to look for differences."
    @State private var onlyDifferences = true
    @State private var includeSubdirectories = true
    @State private var compareByContent = false
    @State private var includeHidden = true
    @State private var mask = ""

    init(left: URL, right: URL) {
        _leftPath = State(initialValue: left.path)
        _rightPath = State(initialValue: right.path)
    }

    private var leftURL: URL { URL(fileURLWithPath: (leftPath as NSString).expandingTildeInPath) }
    private var rightURL: URL { URL(fileURLWithPath: (rightPath as NSString).expandingTildeInPath) }

    private var options: SyncService.Options {
        SyncService.Options(includeSubdirectories: includeSubdirectories,
                            compareByContent: compareByContent,
                            includeHidden: includeHidden,
                            onlyDifferences: onlyDifferences,
                            mask: mask)
    }

    private var actionableCount: Int { rows.filter { $0.direction != .none }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "arrow.triangle.branch").foregroundStyle(Color.accentColor)
                Text("Compare and synchronise directories").font(.headline)
                Spacer()
                if isComparing {
                    ProgressView().controlSize(.small)
                }
            }

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    Text("Left").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    TextField("left", text: $leftPath)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                }
                GridRow {
                    Text("Right").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    TextField("right", text: $rightPath)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                }
                GridRow {
                    Text("Mask").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    TextField("*.*", text: $mask)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 200)
                }
            }

            HStack(spacing: 14) {
                Toggle("Subdirectories", isOn: $includeSubdirectories).toggleStyle(.checkbox)
                Toggle("Only differences", isOn: $onlyDifferences).toggleStyle(.checkbox)
                Toggle("Compare content", isOn: $compareByContent).toggleStyle(.checkbox)
                Toggle("Hidden files", isOn: $includeHidden).toggleStyle(.checkbox)
                Spacer()
                Button("Swap") {
                    swap(&leftPath, &rightPath)
                    rows = []
                    statusText = "Press Compare to look for differences."
                }
                .controlSize(.small)
                Button("Compare") { startCompare() }
                    .controlSize(.small)
                    .disabled(isComparing)
            }

            Divider()

            if rows.isEmpty {
                VStack {
                    Spacer()
                    Text(statusText)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, minHeight: 240)
            } else {
                table
            }

            Divider()

            HStack(spacing: 8) {
                Text("\(rows.count) difference\(rows.count == 1 ? "" : "s")")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("All →") { setAll(.leftToRight) }
                Button("← All") { setAll(.rightToLeft) }
                Button("Clear") { setAll(.none) }
                Button("Synchronise") { runSync() }
                    .buttonStyle(.borderedProminent)
                    .disabled(actionableCount == 0)
                    .help("\(actionableCount) action(s) selected")
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: 980, height: 620)
    }

    private var table: some View {
        Table(rows) {
            TableColumn("Name") { row in
                HStack(spacing: 5) {
                    Image(systemName: row.isDirectory ? "folder" : "doc")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(row.relativePath)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .help(row.relativePath)
            }
            .width(min: 200, ideal: 300)

            TableColumn("Left size") { row in
                Text(row.leftSizeText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .width(80)

            TableColumn("Left date") { row in
                Text(row.leftDateText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .width(110)

            TableColumn("Right size") { row in
                Text(row.rightSizeText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .width(80)

            TableColumn("Right date") { row in
                Text(row.rightDateText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .width(110)

            TableColumn("Status") { row in
                Text(row.status.shortName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color(nsColor: row.status.color))
            }
            .width(90)

            TableColumn("Action") { row in
                Button {
                    cycle(row)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: row.direction.symbol)
                            .font(.system(size: 10, weight: .bold))
                        Text(row.direction.label)
                            .font(.system(size: 10))
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.borderless)
                .foregroundStyle(row.direction == .none ? Color.secondary : Color.accentColor)
                .help(row.direction.label + " — click to change")
            }
            .width(min: 120, ideal: 150)
        }
    }

    private func cycle(_ row: SyncRow) {
        guard let index = rows.firstIndex(where: { $0.id == row.id }) else { return }
        let order: [SyncDirection] = [.none, .leftToRight, .rightToLeft, .deleteRight, .deleteLeft]
        let current = order.firstIndex(of: rows[index].direction) ?? 0
        rows[index].direction = order[(current + 1) % order.count]
    }

    private func setAll(_ direction: SyncDirection) {
        for index in rows.indices {
            rows[index].direction = direction
        }
    }

    private func startCompare() {
        isComparing = true
        statusText = "Comparing…"
        let left = leftURL
        let right = rightURL
        let settings = options
        let maskValue = mask
        _ = maskValue
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                SyncService.compare(left: left, right: right, options: settings)
            }.value
            rows = result.rows
            isComparing = false
            if rows.isEmpty {
                statusText = "No differences found."
            } else {
                statusText = "\(rows.count) differences, \(result.leftFiles) entries on the left, \(result.rightFiles) on the right."
            }
        }
    }

    private func runSync() {
        let pending = rows.filter { $0.direction != .none }
        guard !pending.isEmpty else { return }

        let deletions = pending.filter { $0.direction.isDeletion }.count
        let alert = NSAlert()
        alert.messageText = "Synchronise \(pending.count) item\(pending.count == 1 ? "" : "s")?"
        var lines = pending.prefix(12).map { "\($0.direction.symbol)  \($0.relativePath)" }
        if pending.count > 12 { lines.append("… and \(pending.count - 12) more") }
        if deletions > 0 { lines.append("") ; lines.append("\(deletions) item(s) will be deleted.") }
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "Synchronise")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let left = leftURL
        let right = rightURL
        let batch = pending
        app.operations.runCustom(title: "Synchronising") { context in
            context.policy = .replaceAll
            SyncService.execute(rows: batch, left: left, right: right, context: context) { done, total, name in
                context.bytesDone = done
                context.bytesTotal = total
                context.report(detail: name)
            }
        } completion: { [weak app] _ in
            app?.afterFileOperation()
        }
        dismiss()
    }
}

// MARK: - Multi rename

struct MultiRenameSheet: View {

    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    let items: [FileItem]

    @State private var template = RenameTemplate()
    @State private var preview: [RenamePreviewRow] = []
    @State private var overwrite = false

    private var changedCount: Int { preview.filter { $0.hasChange }.count }
    private var conflictCount: Int { preview.filter { $0.isConflicting || $0.isDuplicate }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "textformat.abc").foregroundStyle(Color.accentColor)
                Text("Multi-rename \(items.count) file\(items.count == 1 ? "" : "s")").font(.headline)
                Spacer()
                Text("\(changedCount) will change")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if conflictCount > 0 {
                    Text("\(conflictCount) conflict\(conflictCount == 1 ? "" : "s")")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.red)
                }
            }

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Rename mask").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    HStack {
                        TextField("[N]", text: $template.mask)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(width: 260)
                        Text("[N] name  [E] ext  [F] full  [C] counter  [Y][M][D] date  [h][m][s] time")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                    }
                }
                GridRow {
                    Text("Search").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        TextField("text to find", text: $template.searchText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 150)
                        Text("Replace").foregroundStyle(.secondary)
                        TextField("replacement", text: $template.replaceText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 150)
                        Toggle("Regex", isOn: $template.useRegex).toggleStyle(.checkbox)
                    }
                }
                GridRow {
                    Text("Case").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Picker("", selection: $template.caseMode) {
                            ForEach(RenameTemplate.CaseMode.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 140)

                        Text("Counter").foregroundStyle(.secondary)
                        TextField("", value: $template.counterStart, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 50)
                        Text("step").foregroundStyle(.secondary)
                        TextField("", value: $template.counterStep, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 50)
                        Text("digits").foregroundStyle(.secondary)
                        TextField("", value: $template.counterDigits, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 50)
                    }
                }
                GridRow {
                    Text("Extension").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Picker("", selection: $template.extensionMode) {
                            ForEach(RenameTemplate.ExtensionMode.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 150)
                        if template.extensionMode == .replace {
                            TextField("new extension", text: $template.extensionReplacement)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 120)
                        }
                    }
                }
            }

            Divider()

            Table(preview) {
                TableColumn("Current name") { row in
                    HStack(spacing: 4) {
                        if row.isDirectory {
                            Image(systemName: "folder").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Text(row.original).font(.system(size: 11, design: .monospaced))
                    }
                }
                .width(min: 180, ideal: 280)

                TableColumn("New name") { row in
                    Text(row.proposed)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(row.isConflicting || row.isDuplicate
                                         ? Color.red
                                         : (row.hasChange ? Color.primary : Color.secondary))
                }
                .width(min: 180, ideal: 280)

                TableColumn("") { row in
                    Text(row.isDuplicate ? "duplicate name"
                         : (row.isConflicting ? "already exists"
                            : (row.hasChange ? "ok" : "unchanged")))
                        .font(.system(size: 10))
                        .foregroundStyle(row.isConflicting || row.isDuplicate ? .red : .secondary)
                }
                .width(110)
            }
            .frame(minHeight: 240)

            HStack {
                Toggle("Overwrite existing files", isOn: $overwrite).toggleStyle(.checkbox)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(changedCount == 0)
            }
        }
        .padding(16)
        .frame(width: 900, height: 620)
        .onAppear { refresh() }
        .onChange(of: template) { _, _ in refresh() }
    }

    private func refresh() {
        preview = MultiRenameService.preview(items: items, template: template)
    }

    private func apply() {
        let result = MultiRenameService.apply(rows: preview, overwrite: overwrite)
        if !result.errors.isEmpty {
            app.operations.reportError("Renamed \(result.renamed) file\(result.renamed == 1 ? "" : "s") with problems",
                                       informative: result.errors.prefix(12).joined(separator: "\n"))
        } else {
            app.showStatus("Renamed \(result.renamed) file\(result.renamed == 1 ? "" : "s")")
        }
        app.afterFileOperation()
        dismiss()
    }
}

// MARK: - About

struct AboutView: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    private let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                    .resizable()
                    .frame(width: 96, height: 96)
                Text("TotalMac")
                    .font(.system(size: 24, weight: .semibold))
                Text("Version \(version) · build \(VersionService.currentBuild)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("Built \(VersionService.currentBuildDate)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                Text("A native macOS dual-pane file manager built in the spirit of Total Commander.")
                    .font(.system(size: 12))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            .padding(.top, 20)
            .padding(.bottom, 14)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "heart.fill").foregroundStyle(.pink)
                    Text("Please support Total Commander")
                        .font(.system(size: 13, weight: .semibold))
                }

                Text("""
                TotalMac is an independent, from-scratch Mac application. The idea, the interaction \
                model and the name it honours all come from Total Commander — a brilliant piece of \
                software written over decades and still actively developed by Christian Ghisler \
                (C. Ghisler & Co., Switzerland).

                If you like working this way, please buy a licence and support the original. That is \
                what keeps Total Commander alive and improving, on Windows, Android and beyond.
                """)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Button {
                        NSWorkspace.shared.open(URL(string: "https://www.ghisler.com/index.htm")!)
                    } label: {
                        Label("Total Commander home", systemImage: "safari")
                    }
                    Button {
                        NSWorkspace.shared.open(URL(string: "https://www.ghisler.com/order.htm")!)
                    } label: {
                        Label("Buy a licence / support him", systemImage: "cart")
                    }
                    Button {
                        NSWorkspace.shared.open(URL(string: "https://www.ghisler.ch/board/")!)
                    } label: {
                        Label("Community forum", systemImage: "bubble.left.and.bubble.right")
                    }
                }
                .controlSize(.small)

                Text("Total Commander and the “GHISLER” name are the property of Christian Ghisler. TotalMac is not affiliated with, endorsed by, or connected to him — it simply admires his work.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                Text("Built with SwiftUI and AppKit. Archive support uses the libarchive that ships with macOS. No Total Commander code was used.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            HStack {
                Button("App Versions…") { openWindow(id: "versions") }
                    .controlSize(.small)
                    .help("Keep several builds and switch back to an earlier one")
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 480)
    }
}
