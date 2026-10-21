import Foundation

/// Total Commander's multi-rename tool: a mask with placeholders plus search and
/// replace, applied to a whole selection with a live preview.
struct RenameTemplate: Equatable {

    enum CaseMode: String, CaseIterable, Identifiable {
        case unchanged, lower, upper, capitalized
        var id: String { rawValue }
        var title: String {
            switch self {
            case .unchanged: return "Unchanged"
            case .lower: return "lowercase"
            case .upper: return "UPPERCASE"
            case .capitalized: return "Capitalised"
            }
        }
    }

    enum ExtensionMode: String, CaseIterable, Identifiable {
        case keep, lower, upper, replace, remove
        var id: String { rawValue }
        var title: String {
            switch self {
            case .keep: return "Keep as is"
            case .lower: return "lowercase"
            case .upper: return "UPPERCASE"
            case .replace: return "Replace with"
            case .remove: return "Remove"
            }
        }
    }

    /// Placeholders: [N] name, [E] extension, [F] full name, [C] counter,
    /// [Y] year, [M] month, [D] day, [h] hour, [m] minute, [s] second.
    var mask: String = "[N]"
    var searchText: String = ""
    var replaceText: String = ""
    var useRegex: Bool = false
    var caseMode: CaseMode = .unchanged
    var counterStart: Int = 1
    var counterStep: Int = 1
    var counterDigits: Int = 2
    var extensionMode: ExtensionMode = .keep
    var extensionReplacement: String = ""
}

struct RenamePreviewRow: Identifiable, Hashable {
    var id: String { original }
    var original: String
    var proposed: String
    var folder: URL
    var isDirectory: Bool
    var modified: Date?

    var hasChange: Bool { original != proposed }
    var isConflicting: Bool = false
    var isDuplicate: Bool = false

    var targetExists: Bool = false
}

enum MultiRenameService {

    /// Expands the mask for one file name.
    static func newName(for original: String,
                        isDirectory: Bool,
                        modified: Date?,
                        counter: Int,
                        template: RenameTemplate) -> String {

        let url = URL(fileURLWithPath: original)
        var base = url.deletingPathExtension().lastPathComponent
        var ext = url.pathExtension

        if isDirectory { base = original; ext = "" }

        // Search & replace on the name part (Total Commander semantics).
        if !template.searchText.isEmpty {
            if template.useRegex {
                base = base.replacingOccurrences(of: template.searchText,
                                                 with: template.replaceText,
                                                 options: .regularExpression)
            } else {
                base = base.replacingOccurrences(of: template.searchText,
                                                 with: template.replaceText,
                                                 options: [.caseInsensitive])
            }
        }

        switch template.caseMode {
        case .unchanged: break
        case .lower: base = base.lowercased()
        case .upper: base = base.uppercased()
        case .capitalized: base = base.capitalized
        }

        let counterText = String(format: "%0\(max(1, template.counterDigits))d", counter)
        let date = modified ?? Date()
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)

        var result = template.mask
        let replacements: [(String, String)] = [
            ("[N]", base),
            ("[E]", ext),
            ("[F]", original),
            ("[C]", counterText),
            ("[Y]", String(format: "%04d", components.year ?? 0)),
            ("[M]", String(format: "%02d", components.month ?? 0)),
            ("[D]", String(format: "%02d", components.day ?? 0)),
            ("[h]", String(format: "%02d", components.hour ?? 0)),
            ("[m]", String(format: "%02d", components.minute ?? 0)),
            ("[s]", String(format: "%02d", components.second ?? 0)),
            ("[n]", String(counter))
        ]
        for (token, value) in replacements {
            result = result.replacingOccurrences(of: token, with: value)
        }

        // Extension handling
        switch template.extensionMode {
        case .keep:
            if !ext.isEmpty { result += "." + ext }
        case .lower:
            if !ext.isEmpty { result += "." + ext.lowercased() }
        case .upper:
            if !ext.isEmpty { result += "." + ext.uppercased() }
        case .replace:
            if !template.extensionReplacement.isEmpty {
                result += "." + template.extensionReplacement
            }
        case .remove:
            break
        }

        return result
    }

    /// Builds the preview table, including collision detection.
    static func preview(items: [FileItem], template: RenameTemplate) -> [RenamePreviewRow] {
        var rows: [RenamePreviewRow] = []
        var counter = template.counterStart

        for item in items where !item.isParent {
            let proposed = newName(for: item.name,
                                   isDirectory: item.isDirectory,
                                   modified: item.modified,
                                   counter: counter,
                                   template: template)
            counter += template.counterStep
            rows.append(RenamePreviewRow(original: item.name,
                                         proposed: proposed,
                                         folder: item.url.deletingLastPathComponent(),
                                         isDirectory: item.isDirectory,
                                         modified: item.modified))
        }

        // Duplicates inside the batch
        var counts: [String: Int] = [:]
        for row in rows {
            counts[row.proposed.lowercased(), default: 0] += 1
        }
        let originals = Set(rows.map { $0.original.lowercased() })

        for index in rows.indices {
            let row = rows[index]
            let folder = row.folder
            rows[index].isDuplicate = (counts[row.proposed.lowercased()] ?? 0) > 1
            let target = folder.appendingPathComponent(row.proposed)
            let exists = FileManager.default.fileExists(atPath: target.path)
            rows[index].targetExists = exists
            // Overwriting something that is not part of this rename batch is a conflict.
            rows[index].isConflicting = exists && !originals.contains(row.proposed.lowercased())
        }
        return rows
    }

    /// Applies the rename. Two phase (via unique temporary names) so swaps and
    /// cycles work, and a failure rolls back what it can.
    static func apply(rows: [RenamePreviewRow], overwrite: Bool) -> (renamed: Int, errors: [String]) {
        var errors: [String] = []
        var renamed = 0
        let fileManager = FileManager.default

        let actionable = rows.filter { $0.hasChange }
        var temporaryNames: [(folder: URL, temporary: URL, final: URL, original: URL)] = []

        // Phase 1: move everything to a unique temporary name.
        for row in actionable {
            if row.isConflicting && !overwrite {
                errors.append("\(row.original): “\(row.proposed)” already exists")
                continue
            }
            let source = row.folder.appendingPathComponent(row.original)
            guard fileManager.fileExists(atPath: source.path) else {
                errors.append("\(row.original): no longer exists")
                continue
            }
            let temporary = FileSystemService.uniqueURL(
                for: row.folder.appendingPathComponent(".totalmac-rename-\(UUID().uuidString)"))
            do {
                try fileManager.moveItem(at: source, to: temporary)
                temporaryNames.append((row.folder, temporary,
                                       row.folder.appendingPathComponent(row.proposed), source))
            } catch {
                errors.append("\(row.original): \(error.localizedDescription)")
            }
        }

        // Phase 2: move into place.
        for entry in temporaryNames {
            if overwrite, fileManager.fileExists(atPath: entry.final.path) {
                try? fileManager.removeItem(at: entry.final)
            }
            do {
                try fileManager.moveItem(at: entry.temporary, to: entry.final)
                renamed += 1
            } catch {
                errors.append("\(entry.final.lastPathComponent): \(error.localizedDescription)")
                try? fileManager.moveItem(at: entry.temporary, to: entry.original)
            }
        }

        return (renamed, errors)
    }
}
