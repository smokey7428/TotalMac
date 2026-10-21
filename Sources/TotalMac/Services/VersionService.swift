import Foundation
import AppKit

/// One archived build of the app, as found in `dist/versions`.
struct AppBuild: Identifiable, Hashable {

    var url: URL
    var version: String
    var build: Int
    var date: Date?
    var size: Int64
    /// Matches the build that is running right now.
    var isRunning: Bool

    var id: String { url.path }

    var fileName: String { url.lastPathComponent }

    var versionText: String { "\(version) (build \(build))" }

    var sizeText: String { ByteFormatter.string(size) }

    var dateText: String {
        guard let date else { return "—" }
        return DateFormatter.medium(date)
    }

    var statusText: String {
        if isRunning { return "running" }
        let runningBuild = VersionService.currentBuild
        if build > runningBuild { return "newer than the running app" }
        return "older"
    }
}

/// Version stamping and the archive of previous builds.
///
/// `build.sh` stamps `CFBundleShortVersionString`, `CFBundleVersion` and the
/// build date into the bundle and keeps a copy of every build in `dist/versions`,
/// which is what makes "go back to the version that worked" possible.
enum VersionService {

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    static var currentBuild: Int {
        if let number = Bundle.main.infoDictionary?["TotalMacBuildNumber"] as? Int {
            return number
        }
        return Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1") ?? 1
    }

    /// Human readable build time, stamped in by the build script.
    static var currentBuildDate: String {
        Bundle.main.infoDictionary?["TotalMacBuildDate"] as? String ?? "development build"
    }

    static var currentDescription: String {
        "TotalMac \(currentVersion) · build \(currentBuild) · \(currentBuildDate)"
    }

    /// `dist/versions`, sitting next to the running bundle.
    static var archivedBuildsFolder: URL {
        Bundle.main.bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("versions", isDirectory: true)
    }

    // MARK: - Reading archives

    /// Every archived build, newest first. Pass a folder to inspect somewhere else.
    static func archivedBuilds(in folder: URL? = nil) -> [AppBuild] {
        let directory = folder ?? archivedBuildsFolder
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]) else {
            return []
        }

        let builds = entries
            .filter { $0.pathExtension == "app" }
            .compactMap { read(appAt: $0) }

        return builds.sorted { a, b in
            if a.build != b.build { return a.build > b.build }
            return a.fileName > b.fileName
        }
    }

    /// Reads one `.app` bundle's version stamp. Returns nil when the thing at
    /// `url` is not an app bundle with a readable Info.plist.
    static func read(appAt url: URL) -> AppBuild? {
        guard let bundle = Bundle(url: url),
              let info = bundle.infoDictionary,
              let bundleIdentifier = info["CFBundleIdentifier"] as? String else {
            return nil
        }

        let version = info["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let build = (info["TotalMacBuildNumber"] as? Int)
            ?? Int(info["CFBundleVersion"] as? String ?? "0")
            ?? 0
        guard build > 0, bundleIdentifier == runningBundleIdentifier || bundleIdentifier.hasPrefix("com.totalmac") else {
            return nil
        }

        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        let matchesRunning = build == currentBuild && version == currentVersion

        return AppBuild(url: url,
                        version: version,
                        build: build,
                        date: date,
                        size: FileSystemService.measure(url).bytes,
                        isRunning: matchesRunning)
    }

    private static var runningBundleIdentifier: String {
        Bundle.main.infoDictionary?["CFBundleIdentifier"] as? String ?? "com.totalmac.app"
    }

    // MARK: - Switching versions

    /// Copies an archived build over the running one. The app must be relaunched
    /// afterwards; the caller is expected to say so.
    static func makeCurrent(_ build: AppBuild) throws {
        let fileManager = FileManager.default
        let target = Bundle.main.bundleURL
        guard target.standardizedFileURL.path != build.url.standardizedFileURL.path else { return }

        let staging = target.deletingLastPathComponent()
            .appendingPathComponent(".TotalMac-previous-\(UUID().uuidString).app")

        try fileManager.moveItem(at: target, to: staging)
        do {
            try fileManager.copyItem(at: build.url, to: target)
            try? fileManager.removeItem(at: staging)
        } catch {
            try? fileManager.moveItem(at: staging, to: target)
            throw error
        }
    }

    /// Starts a fresh copy of the app and quits this one.
    static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL,
                                          configuration: configuration) { _, _ in
            Task { @MainActor in
                NSApp.terminate(nil)
            }
        }
    }

    /// Keeps the archive folder from growing forever. The dropped builds are
    /// deleted rather than trashed: `build.sh` can recreate any of them.
    @discardableResult
    static func pruneArchivedBuilds(keeping keep: Int, in folder: URL? = nil) -> Int {
        let builds = archivedBuilds(in: folder)
        guard builds.count > keep else { return 0 }
        var removed = 0
        for build in builds.dropFirst(keep) {
            if (try? FileManager.default.removeItem(at: build.url)) != nil {
                removed += 1
            }
        }
        return removed
    }
}
