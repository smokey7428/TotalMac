import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers

struct ViewerRequest: Codable, Hashable, Identifiable {
    var path: String
    var id: String { path }
}

enum ViewerMode: String, CaseIterable, Identifiable {
    case text = "Text"
    case hex = "Hex"
    case image = "Image"
    case pdf = "PDF"
    case info = "Info"

    var id: String { rawValue }
}

struct ViewerPayload {
    var data = Data()
    var fileSize: Int64 = 0
    var truncated = false
    var isBinary = false
    var isImage = false
    var isPDF = false
    var text = ""
}

struct ViewerWindow: View {

    @Environment(\.dismiss) private var dismiss
    let request: ViewerRequest

    @State private var payload: ViewerPayload?
    @State private var mode: ViewerMode = .text
    @State private var errorText: String?

    private var url: URL { URL(fileURLWithPath: request.path) }

    private var availableModes: [ViewerMode] {
        guard let payload else { return [.info] }
        var modes: [ViewerMode] = []
        if payload.isPDF { modes.append(.pdf) }
        if payload.isImage { modes.append(.image) }
        if !payload.isBinary { modes.append(.text) }
        modes.append(.hex)
        modes.append(.info)
        return modes
    }

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .frame(minWidth: 560, minHeight: 380)
        .navigationTitle(url.lastPathComponent)
        .toolbar { toolbarContent }
        .task(id: request.path) { load() }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Picker("Mode", selection: $mode) {
                ForEach(availableModes) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 320)

            Button {
                NSWorkspace.shared.open(url)
            } label: {
                Label("Open with default app", systemImage: "arrow.up.forward.app")
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let errorText {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                Text(errorText)
                Text(url.path).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let payload {
            switch mode {
            case .text:
                textView(payload)
            case .hex:
                hexView(payload)
            case .image:
                imageView(payload)
            case .pdf:
                PDFKitView(url: url)
            case .info:
                infoView(payload)
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func textView(_ payload: ViewerPayload) -> some View {
        VStack(spacing: 0) {
            if payload.truncated {
                banner("Showing the first \(ByteFormatter.string(Int64(payload.data.count))) of \(ByteFormatter.string(payload.fileSize))")
            }
            ScrollView([.vertical, .horizontal]) {
                Text(payload.text)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(8)
            }
        }
    }

    private func hexView(_ payload: ViewerPayload) -> some View {
        VStack(spacing: 0) {
            if payload.truncated {
                banner("Hex view shows the first \(ByteFormatter.string(Int64(payload.data.count))) only")
            }
            ScrollView([.vertical, .horizontal]) {
                Text(Self.hexDump(payload.data))
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(8)
            }
        }
    }

    private func imageView(_ payload: ViewerPayload) -> some View {
        ScrollView([.vertical, .horizontal]) {
            if let image = NSImage(data: payload.data) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 1600)
                    .padding(12)
            } else {
                Text("Cannot decode this image").padding()
            }
        }
    }

    private func infoView(_ payload: ViewerPayload) -> some View {
        let item = FileSystemService.makeItem(url: url)
        return ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                if let item {
                    Text(item.name).font(.headline)
                    Text(item.tooltip)
                        .font(.system(size: 11.5, design: .monospaced))
                        .textSelection(.enabled)
                }
                if let detected = Self.describe(data: payload.data) {
                    Divider()
                    Text("Detected content: \(detected)")
                        .font(.system(size: 11.5, design: .monospaced))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
    }

    private func banner(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle").font(.system(size: 10))
            Text(text).font(.system(size: 11))
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.yellow.opacity(0.18))
    }

    // MARK: - Loading

    private func load() {
        errorText = nil
        payload = nil

        let target = url
        let limit = 8 * 1024 * 1024

        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<ViewerPayload, Error> in
                Result { try Self.makePayload(url: target, limit: limit) }
            }.value

            switch result {
            case .success(let payload):
                self.payload = payload
                self.mode = payload.isPDF ? .pdf : (payload.isImage ? .image : (payload.isBinary ? .hex : .text))
            case .failure(let error):
                self.errorText = error.localizedDescription
            }
        }
    }

    nonisolated static func makePayload(url: URL, limit: Int) throws -> ViewerPayload {
        var payload = ViewerPayload()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw NSError(domain: "TotalMac", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Not a readable file"])
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        payload.fileSize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0

        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw NSError(domain: "TotalMac", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot open file"])
        }
        defer { try? handle.close() }
        payload.data = (try? handle.read(upToCount: limit)) ?? Data()
        payload.truncated = payload.fileSize > Int64(payload.data.count)

        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
            ?? UTType(filenameExtension: url.pathExtension)

        payload.isPDF = type?.conforms(to: .pdf) ?? false
        payload.isImage = !payload.isPDF && (type?.conforms(to: .image) ?? false)
        payload.isBinary = payload.data.prefix(8192).contains(0)

        if !payload.isBinary {
            payload.text = String(data: payload.data, encoding: .utf8)
                ?? String(data: payload.data, encoding: .isoLatin1)
                ?? ""
        }
        return payload
    }

    nonisolated static func hexDump(_ data: Data) -> String {
        guard !data.isEmpty else { return "" }
        var lines: [String] = []
        lines.reserveCapacity(data.count / 16 + 1)
        let bytes = [UInt8](data)
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + 16, bytes.count)
            var hex = ""
            var ascii = ""
            for index in offset..<end {
                hex += String(format: "%02X ", bytes[index])
                let scalar = bytes[index]
                ascii += (scalar >= 32 && scalar < 127) ? String(UnicodeScalar(scalar)) : "."
            }
            let padded = hex.padding(toLength: 16 * 3, withPad: " ", startingAt: 0)
            lines.append(String(format: "%08X  %@ %@", offset, padded, ascii))
            offset = end
        }
        return lines.joined(separator: "\n")
    }

    nonisolated static func describe(data: Data) -> String? {
        guard data.count >= 4 else { return nil }
        let magic = [UInt8](data.prefix(8))
        func match(_ signature: [UInt8], at offset: Int = 0) -> Bool {
            guard magic.count >= offset + signature.count else { return false }
            return Array(magic[offset..<(offset + signature.count)]) == signature
        }
        if match([0x50, 0x4B, 0x03, 0x04]) { return "ZIP / Office / JAR archive" }
        if match([0x25, 0x50, 0x44, 0x46]) { return "PDF document" }
        if match([0x89, 0x50, 0x4E, 0x47]) { return "PNG image" }
        if match([0xFF, 0xD8, 0xFF]) { return "JPEG image" }
        if match([0x47, 0x49, 0x46, 0x38]) { return "GIF image" }
        if match([0x1F, 0x8B]) { return "GZIP archive" }
        if match([0x42, 0x5A, 0x68]) { return "BZIP2 archive" }
        if match([0x37, 0x7A, 0xBC, 0xAF]) { return "7z archive" }
        if match([0xCA, 0xFE, 0xBA, 0xBE]) { return "Mach-O universal binary" }
        if match([0xCF, 0xFA, 0xED, 0xFE]) { return "Mach-O 64-bit binary" }
        if match([0xCE, 0xFA, 0xED, 0xFE]) { return "Mach-O 32-bit binary" }
        if match([0x73, 0x71, 0x6C, 0x69, 0x74, 0x65]) { return "SQLite database" }
        if match([0x52, 0x49, 0x46, 0x46]) { return "RIFF container (WAV / AVI / WebP)" }
        if match([0x00, 0x00, 0x01, 0x00]) { return "ICO image" }
        if match([0x49, 0x49, 0x2A, 0x00]) || match([0x4D, 0x4D, 0x00, 0x2A]) { return "TIFF image" }
        return nil
    }
}

struct PDFKitView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.document = PDFDocument(url: url)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url {
            view.document = PDFDocument(url: url)
        }
    }
}
