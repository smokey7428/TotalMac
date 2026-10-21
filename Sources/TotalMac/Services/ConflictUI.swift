import Foundation
import AppKit

/// The "file already exists" prompt, shared by the copy engine and the archive
/// extractor. It runs on the main thread; callers on a worker queue reach it
/// with `DispatchQueue.main.sync`.
enum ConflictUI {

    enum Choice {
        case replace
        case skip
        case keepBoth
        case cancel
    }

    /// Returns the chosen action plus whether the user asked to apply it to
    /// everything that follows.
    static func ask(name: String,
                    sourceDetail: [String],
                    targetDetail: [String],
                    title: String = "File already exists") -> (choice: Choice, applyToAll: Bool) {

        var choice: Choice = .skip
        var applyToAll = false

        let present = {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = title
            alert.informativeText = """
            \(name)

            Source:
            \(sourceDetail.joined(separator: "\n"))

            Target:
            \(targetDetail.joined(separator: "\n"))
            """
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Skip")
            alert.addButton(withTitle: "Keep Both")
            alert.addButton(withTitle: "Cancel")

            let checkbox = NSButton(checkboxWithTitle: "Apply to all", target: nil, action: nil)
            checkbox.state = .off
            alert.accessoryView = checkbox

            let response = alert.runModal()
            applyToAll = checkbox.state == .on
            switch response {
            case .alertFirstButtonReturn: choice = .replace
            case .alertSecondButtonReturn: choice = .skip
            case .alertThirdButtonReturn: choice = .keepBoth
            default: choice = .cancel
            }
        }

        if Thread.isMainThread {
            present()
        } else {
            DispatchQueue.main.sync(execute: present)
        }

        return (choice, applyToAll)
    }

    /// Detail lines for a file on disk (or an archive member description).
    static func details(for url: URL) -> [String] {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return ["  (nothing)"]
        }
        var lines = ["  \(url.path)"]
        if isDirectory.boolValue {
            lines.append("  Folder")
        } else {
            let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            lines.append("  \(ByteFormatter.string(size)) (\(size) bytes)")
        }
        if let attributes = try? fileManager.attributesOfItem(atPath: url.path),
           let modified = attributes[.modificationDate] as? Date {
            lines.append("  Modified \(DateFormatter.short(modified))")
        }
        return lines
    }
}
