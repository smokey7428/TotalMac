import SwiftUI
import AppKit

@main
struct TotalMacApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var app = AppModel.shared

    var body: some Scene {
        WindowGroup("TotalMac") {
            MainView()
                .environmentObject(app)
        }
        .defaultSize(width: 1340, height: 840)
        .commands { appCommands }

        WindowGroup("Viewer", id: "viewer", for: ViewerRequest.self) { $request in
            if let request {
                ViewerWindow(request: request)
            } else {
                Text("No file selected")
                    .frame(minWidth: 420, minHeight: 260)
            }
        }
        .defaultSize(width: 940, height: 640)

        Window("About TotalMac", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("Favorites", id: "favorites") {
            FavoritesWindow()
                .environmentObject(app)
        }
        .defaultSize(width: 720, height: 480)

        Window("App Versions", id: "versions") {
            VersionsView()
                .environmentObject(app)
        }
        .defaultSize(width: 820, height: 500)
    }

    @CommandsBuilder
    private var appCommands: some Commands {

        CommandGroup(replacing: .newItem) {
            Button("New Tab") { app.newTab() }
                .keyboardShortcut("t", modifiers: .command)
            Button("New Tab from Folder") { app.newTabFromFocusedFolder() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Divider()
            Button("New Folder…") { app.createNewFolder() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }

        CommandGroup(after: .newItem) {
            Button("Close Tab") { app.closeTab() }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(app.activePanel.tabs.count < 2)
        }

        CommandMenu("Go") {
            Button("Favorites…") { app.openFavorites() }
                .keyboardShortcut("d", modifiers: .command)
            Button("Add Current Folder to Favorites") { app.addCurrentFolderToFavorites() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Divider()
            Button("Choose Drive for Left Pane…   (⌥F1)") { app.chooseVolume(for: .left) }
            Button("Choose Drive for Right Pane…  (⌥F2)") { app.chooseVolume(for: .right) }
            Button("Refresh Volumes") { app.refreshVolumes() }
            Divider()
            Button("Parent Folder") { app.goUp() }
                .keyboardShortcut(.upArrow, modifiers: .command)
            Button("Back") { app.goBack() }
                .keyboardShortcut("[", modifiers: .command)
            Button("Forward") { app.goForward() }
                .keyboardShortcut("]", modifiers: .command)
            Divider()
            Button("Home Folder") { app.goHome() }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            Button("Computer (/)") { app.activePanel.navigate(to: URL(fileURLWithPath: "/")) }
                .keyboardShortcut("/", modifiers: [.command, .shift])
            Divider()
            Button("Swap Panes") { app.swapPanels() }
                .keyboardShortcut("u", modifiers: [.command, .shift])
            Button("Switch Pane") { app.switchPanel() }
        }

        CommandMenu("Files") {
            Button("View…          (F3)") { app.viewFocused() }
            Button("Edit…          (F4)") { app.editFocused() }
            Button("Rename…        (F2)") { app.beginRenameOnCursor() }
            Divider()
            Button("Copy to Other Pane…  (F5)") { app.copyToOtherPanel() }
            Button("Move to Other Pane…  (F6)") { app.moveToOtherPanel() }
            Button("Duplicate            (F11)") { app.duplicateSelection() }
            Divider()
            Button("Move to Trash        (F8)") { app.deleteFocused(permanent: false) }
            Button("Delete Permanently   (⇧F8)") { app.deleteFocused(permanent: true) }
            Divider()
            Button("Paste Into This Folder") { app.pasteFromClipboard() }
                .keyboardShortcut("v", modifiers: [.command, .shift])
            Button("Copy Full Paths") { app.copyPathsToClipboard() }
                .keyboardShortcut("8", modifiers: [.command, .shift])
            Divider()
            Button("Get Info") { 
                if let item = app.activePanel.focusedItem { app.getInfo(item) }
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            Button("Reveal in Finder") {
                app.revealInFinder(app.activePanel.operationTargets.map(\.url))
            }
        }

        CommandMenu("Panels") {
            Button("Refresh") { app.refreshAll() }
                .keyboardShortcut("r", modifiers: .command)
            Button("Focus Quick Filter") { app.focusFilter() }
                .keyboardShortcut("f", modifiers: .command)
            Divider()
            Button("Show Hidden Files") { app.toggleHidden() }
                .keyboardShortcut(".", modifiers: [.command, .shift])
            Button("Show Sizes in Bytes") { app.toggleBytes() }
                .keyboardShortcut("b", modifiers: [.command, .shift])
            Divider()
            Button("Select All") { app.selectAll() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
            Button("Select None") { app.selectNone() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Button("Invert Selection") { app.invertSelection() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            Button("Select Group…") { app.selectByMask() }
            Button("Unselect Group…") { app.deselectByMask() }
            Divider()
            ForEach(1...9, id: \.self) { index in
                Button("Tab \(index)") { app.activateTab(index - 1) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index)")), modifiers: .command)
            }
        }

        CommandMenu("Tools") {
            Button("Compare & Synchronise Directories…  (F9)") { app.openCompareWindow() }
            Button("Multi-Rename Tool…                (⌃M)") { app.openMultiRename() }
            Divider()
            Button("Pack into Archive…                (⌥F5)") { app.packSelection() }
            Button("Extract to Other Pane             (⌥F9)") { app.extractToOtherPanel() }
            Button("Test Archive                      (⇧F9)") { app.verifyArchive() }
            Button("Quick Look                        (⌘Y)") { app.quickLook() }
        }

        CommandGroup(replacing: .appInfo) {
            Button("About TotalMac") { app.showAbout = true }
            Divider()
            Button("App Versions…") { app.showVersions = true }
                .keyboardShortcut("v", modifiers: [.command, .shift])
        }

        CommandGroup(replacing: .help) {
            Button("TotalMac Help") { app.showHelp = true }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--selftest") {
            exit(SelfTest.run())
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.cleanUpPreviewFolder()
    }
}
