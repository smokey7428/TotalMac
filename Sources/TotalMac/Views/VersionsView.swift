import SwiftUI
import AppKit

/// Lists the archived builds and lets you go back to one.
struct VersionsView: View {

    @EnvironmentObject private var app: AppModel

    @State private var builds: [AppBuild] = []
    @State private var selection: String?
    @State private var status = ""

    private var folder: URL { VersionService.archivedBuildsFolder }

    private var selected: AppBuild? {
        guard let selection else { return nil }
        return builds.first { $0.id == selection }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if builds.isEmpty {
                empty
            } else {
                table
            }

            Divider()
            footer
        }
        .frame(minWidth: 720, minHeight: 420)
        .onAppear { refresh() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text("App versions").font(.headline)
                Text(VersionService.currentDescription)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .controlSize(.small)
        }
        .padding(12)
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "shippingbox")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("No archived builds yet")
                .font(.system(size: 13, weight: .medium))
            Text("""
            Every time you run ./build.sh the finished app is stamped with a version \
            and copied into:

            \(folder.path)

            Keep building and each version stays available here, so you can always go \
            back to the one that worked.
            """)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 460)
            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: 240)
    }

    private var table: some View {
        Table(builds, selection: $selection) {
            TableColumn("Version") { build in
                HStack(spacing: 6) {
                    if build.isRunning {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.green)
                    }
                    Text(build.versionText)
                        .font(.system(size: 11.5, weight: build.isRunning ? .semibold : .regular, design: .monospaced))
                }
            }
            .width(min: 130, ideal: 160)

            TableColumn("Built") { build in
                Text(build.dateText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 150)

            TableColumn("Size") { build in
                Text(build.sizeText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .width(70)

            TableColumn("State") { build in
                Text(build.statusText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(build.isRunning ? Color.green : Color.secondary)
            }
            .width(min: 120, ideal: 170)

            TableColumn("File") { build in
                Text(build.fileName)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(build.url.path)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                if let selected {
                    NSWorkspace.shared.open(selected.url)
                }
            } label: {
                Label("Open", systemImage: "play.circle")
            }
            .disabled(selected == nil)
            .help("Launch this build to try it")

            Button {
                if let selected {
                    NSWorkspace.shared.activateFileViewerSelecting([selected.url])
                }
            } label: {
                Label("Reveal", systemImage: "folder")
            }
            .disabled(selected == nil)

            Button {
                makeCurrent()
            } label: {
                Label("Make Current", systemImage: "arrow.uturn.backward.circle")
            }
            .disabled(selected == nil || selected?.isRunning == true)
            .help("Copy this build over the app you are running, then relaunch")

            Button {
                if let selected, selected.isRunning != true {
                    try? FileManager.default.trashItem(at: selected.url, resultingItemURL: nil)
                    refresh()
                }
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(selected == nil || selected?.isRunning == true)

            Spacer()

            if !status.isEmpty {
                Text(status)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                Text("\(builds.count) build\(builds.count == 1 ? "" : "s") archived")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Button("Relaunch Now") { VersionService.relaunch() }
                .controlSize(.small)
                .help("Quit and start the app again")
        }
        .padding(12)
    }

    private func refresh() {
        builds = VersionService.archivedBuilds()
        if selection == nil { selection = builds.first?.id }
        status = ""
    }

    private func makeCurrent() {
        guard let build = selected else { return }

        let alert = NSAlert()
        alert.messageText = "Switch to TotalMac \(build.versionText)?"
        alert.informativeText = """
        \(build.fileName)

        This replaces the app you are running now with this build. The current app \
        keeps running until you relaunch, and your favorites and settings are kept.
        """
        alert.addButton(withTitle: "Switch and Relaunch")
        alert.addButton(withTitle: "Switch Only")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        guard response != .alertThirdButtonReturn else { return }

        do {
            try VersionService.makeCurrent(build)
            status = "Switched to \(build.versionText)"
            refresh()
            if response == .alertFirstButtonReturn {
                VersionService.relaunch()
            }
        } catch {
            app.operations.reportError("Could not switch versions",
                                       informative: error.localizedDescription)
        }
    }
}
