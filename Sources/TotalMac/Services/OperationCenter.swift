import Foundation
import AppKit
import Combine

/// Owns all long running file operations. Work happens on a background queue;
/// progress is published on the main actor for the HUD in the window.
@MainActor
final class OperationCenter: ObservableObject {

    @Published private(set) var progress: OpProgress?
    @Published private(set) var isBusy = false
    @Published var summary: String?

    private var context: TransferContext?
    /// Concurrent, so one operation blocked in a slow device cannot block the queue.
    private let queue = DispatchQueue(label: "com.totalmac.fileops",
                                      qos: .userInitiated,
                                      attributes: .concurrent)

    var canCancel: Bool { isBusy }

    func cancel() {
        context?.token.cancel()
    }

    /// Last resort for a destination that has stopped responding: stop waiting
    /// for the worker (which may be stuck inside the kernel) and free the app.
    func forceStop() {
        context?.token.cancel()
        context = nil
        progress = nil
        isBusy = false
        summary = "Operation abandoned — the drive may still be finishing in the background"
    }

    // MARK: - Copy / move

    func transfer(sources: [URL], destination: URL, move: Bool, completion: @escaping (Bool) -> Void) {
        guard !sources.isEmpty, !isBusy else { return }
        let title = move ? "Moving" : "Copying"
        let context = makeContext(title: title)
        self.context = context
        self.isBusy = true

        queue.async {
            let started = Date()
            TransferEngine.run(sources: sources, destination: destination, move: move, context: context)
            self.finishOperation(context: context, title: title, started: started, completion: completion)
        }
    }

    // MARK: - Delete

    func delete(urls: [URL], permanent: Bool, completion: @escaping (Bool) -> Void) {
        guard !urls.isEmpty, !isBusy else { return }
        let title = permanent ? "Deleting" : "Moving to Trash"
        let context = makeContext(title: title)
        self.context = context
        self.isBusy = true

        queue.async {
            let started = Date()
            TransferEngine.delete(urls: urls, permanent: permanent, context: context)
            self.finishOperation(context: context, title: title, started: started, completion: completion)
        }
    }

    // MARK: - Archives

    /// Extracts archive members into `destination`. When `move` is set the
    /// members are removed from the archive afterwards by rewriting it.
    func extract(archive: URL,
                 entries: [ArchiveEntry],
                 wanted: Set<String>?,
                 destination: URL,
                 move: Bool,
                 completion: @escaping (Bool) -> Void) {

        guard !isBusy else { return }
        let title = move ? "Extracting and removing" : "Extracting"
        let context = makeContext(title: title)
        self.context = context
        self.isBusy = true

        queue.async {
            let started = Date()
            var errors: [String] = []
            var cancelled = false
            var files = 0
            var bytes: Int64 = 0

            // Sticky answer for "Apply to all".
            var sticky: ArchiveConflictPolicy?
            let asker: (String) -> ArchiveConflictPolicy = { name in
                if let sticky { return sticky }
                let target = destination.appendingPathComponent(name)
                let (choice, applyAll) = ConflictUI.ask(
                    name: name,
                    sourceDetail: ["  \(archive.lastPathComponent) → \(name)"],
                    targetDetail: ConflictUI.details(for: target)
                )
                let policy: ArchiveConflictPolicy
                switch choice {
                case .replace: policy = .replace
                case .skip: policy = .skip
                case .keepBoth: policy = .keepBoth
                case .cancel:
                    context.token.cancel()
                    policy = .skip
                }
                if applyAll { sticky = policy }
                return policy
            }

            do {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                let result = try ArchiveService.extract(
                    archive: archive,
                    entries: entries,
                    wanted: wanted,
                    destination: destination,
                    policy: .replace,
                    onConflict: asker,
                    progress: { done, total, name in
                        context.bytesDone = done
                        context.bytesTotal = total
                        context.report(detail: name)
                    },
                    cancelled: { context.cancelled }
                )
                files = result.files
                bytes = result.bytes
                cancelled = result.cancelled
            } catch {
                errors.append(error.localizedDescription)
            }

            // Move out of an archive = extract, then rewrite the archive.
            if move, !cancelled, errors.isEmpty, let wanted, !context.cancelled {
                do {
                    context.report(detail: "Rewriting the archive…", force: true)
                    _ = try ArchiveService.rewrite(archive: archive, removing: Array(wanted))
                } catch {
                    errors.append(error.localizedDescription)
                }
            }

            context.filesDone = files
            context.bytesDone = bytes
            context.errors.append(contentsOf: errors)
            self.finishOperation(context: context, title: title, started: started, completion: completion)
        }
    }

    /// Creates a new archive from the given sources.
    func createArchive(archive: URL,
                       sources: [URL],
                       format: ArchiveFormat,
                       level: Int,
                       completion: @escaping (Bool) -> Void) {

        guard !sources.isEmpty, !isBusy else { return }
        let title = "Packing"
        let context = makeContext(title: title)
        self.context = context
        self.isBusy = true

        queue.async {
            let started = Date()
            var errors: [String] = []
            var files = 0
            var bytes: Int64 = 0
            var cancelled = false

            do {
                let result = try ArchiveService.create(
                    archive: archive,
                    sources: sources,
                    format: format,
                    level: level,
                    progress: { done, total, name in
                        context.bytesDone = done
                        context.bytesTotal = total
                        context.report(detail: name)
                    },
                    cancelled: { context.cancelled }
                )
                files = result.files
                bytes = result.bytes
                cancelled = result.cancelled
                if cancelled { try? FileManager.default.removeItem(at: archive) }
            } catch {
                errors.append(error.localizedDescription)
            }

            context.filesDone = files
            context.bytesDone = bytes
            context.errors.append(contentsOf: errors)
            self.finishOperation(context: context, title: title, started: started, completion: completion)
        }
    }

    /// Deletes members (or adds files) inside an existing archive.
    func rewriteArchive(archive: URL,
                        removing: [String],
                        adding: [URL] = [],
                        addingPrefix: String = "",
                        completion: @escaping (Bool) -> Void) {

        guard (!removing.isEmpty || !adding.isEmpty), !isBusy else { return }
        let title = adding.isEmpty ? "Updating the archive" : "Adding to the archive"
        let context = makeContext(title: title)
        self.context = context
        self.isBusy = true

        queue.async {
            let started = Date()
            var errors: [String] = []
            var files = 0
            do {
                context.report(detail: archive.lastPathComponent, force: true)
                let result = try ArchiveService.rewrite(
                    archive: archive,
                    removing: removing,
                    adding: adding,
                    addingPrefix: addingPrefix,
                    progress: { done, total, name in
                        context.bytesDone = done
                        context.bytesTotal = total
                        context.report(detail: name)
                    },
                    cancelled: { context.cancelled }
                )
                files = result.files
            } catch {
                errors.append(error.localizedDescription)
            }
            context.filesDone = files
            context.errors.append(contentsOf: errors)
            self.finishOperation(context: context, title: title, started: started, completion: completion)
        }
    }

    // MARK: - Custom work

    /// Runs arbitrary file work on the shared operation queue with progress,
    /// cancellation and the summary dialog. Used by the sync window.
    func runCustom(title: String,
                   _ body: @escaping (TransferContext) -> Void,
                   completion: @escaping (Bool) -> Void) {
        guard !isBusy else { return }
        let context = makeContext(title: title)
        self.context = context
        self.isBusy = true

        queue.async {
            let started = Date()
            body(context)
            self.finishOperation(context: context, title: title, started: started, completion: completion)
        }
    }

    // MARK: - Plumbing

    private func makeContext(title: String) -> TransferContext {
        TransferContext(title: title) { [weak self] progress in
            Task { @MainActor in
                // Ignore reports from an operation the user abandoned.
                guard let self, self.context != nil else { return }
                self.progress = progress
            }
        }
    }

    private nonisolated func finishOperation(context: TransferContext,
                                             title: String,
                                             started: Date,
                                             completion: @escaping (Bool) -> Void) {
        let elapsed = Date().timeIntervalSince(started)
        let cancelled = context.cancelled
        let errors = context.errors
        let files = context.filesDone

        Task { @MainActor in
            // If the operation was abandoned (or superseded) the result is stale.
            guard self.context === context else { return }
            self.isBusy = false
            self.progress = nil
            self.context = nil
            self.finish(cancelled: cancelled, errors: errors,
                        title: title, files: files, elapsed: elapsed)
            completion(errors.isEmpty && !cancelled)
        }
    }

    private func finish(cancelled: Bool, errors: [String], title: String, files: Int, elapsed: Double) {
        if cancelled {
            summary = "\(title) cancelled"
            return
        }
        if errors.isEmpty {
            let seconds = String(format: "%.1f", elapsed)
            summary = "\(title) \(files) item\(files == 1 ? "" : "s") in \(seconds)s"
            return
        }

        summary = "\(title) finished with \(errors.count) problem\(errors.count == 1 ? "" : "s")"
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Some items could not be processed"
        alert.informativeText = errors.prefix(20).joined(separator: "\n")
            + (errors.count > 20 ? "\n… and \(errors.count - 20) more" : "")
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Simple synchronous helper used by Rename / New Folder style commands.
    func reportError(_ message: String, informative: String = "") {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        if !informative.isEmpty { alert.informativeText = informative }
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
