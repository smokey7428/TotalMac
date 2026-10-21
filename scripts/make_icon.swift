// Generates the TotalMac app icon as a .iconset directory.
// Usage: swift scripts/make_icon.swift <output.iconset>
import AppKit
import Foundation

func makeImage(pixelSize: Int) -> NSBitmapImageRep {
    let size = CGFloat(pixelSize)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let context = NSGraphicsContext.current!.cgContext
    context.setShouldAntialias(true)

    // Rounded background
    let inset = size * 0.055
    let backgroundRect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let background = NSBezierPath(roundedRect: backgroundRect, xRadius: size * 0.215, yRadius: size * 0.215)
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.20, green: 0.24, blue: 0.31, alpha: 1),
        NSColor(calibratedRed: 0.08, green: 0.10, blue: 0.14, alpha: 1)
    ])!
    gradient.draw(in: background, angle: -90)

    // Two panes
    let margin = size * 0.115
    let gap = size * 0.035
    let paneWidth = (size - margin * 2 - gap) / 2
    let paneRect = NSRect(x: 0, y: margin, width: paneWidth, height: size - margin * 2)

    let accents: [NSColor] = [
        NSColor(calibratedRed: 0.36, green: 0.62, blue: 0.98, alpha: 1),
        NSColor(calibratedRed: 0.40, green: 0.78, blue: 0.55, alpha: 1),
        NSColor(calibratedRed: 0.98, green: 0.72, blue: 0.32, alpha: 1),
        NSColor(calibratedRed: 0.90, green: 0.48, blue: 0.44, alpha: 1)
    ]

    for pane in 0..<2 {
        let originX = margin + CGFloat(pane) * (paneWidth + gap)
        let rect = NSRect(x: originX, y: paneRect.origin.y, width: paneWidth, height: paneRect.height)
        let path = NSBezierPath(roundedRect: rect, xRadius: size * 0.045, yRadius: size * 0.045)
        NSColor(calibratedWhite: 0.97, alpha: 0.94).setFill()
        path.fill()

        // Title bar of the pane
        let titleRect = NSRect(x: originX, y: rect.maxY - size * 0.085, width: paneWidth, height: size * 0.085)
        let titlePath = NSBezierPath(
            roundedRect: titleRect,
            xRadius: size * 0.045,
            yRadius: size * 0.045
        )
        NSColor(calibratedRed: 0.28, green: 0.36, blue: 0.47, alpha: 1).setFill()
        titlePath.fill()
        NSColor(calibratedWhite: 0.97, alpha: 0.94).setFill()
        NSBezierPath(rect: NSRect(x: originX, y: rect.maxY - size * 0.088,
                                  width: paneWidth, height: size * 0.02)).fill()

        // Content rows
        let rows = 6
        let topPadding = size * 0.135
        let bottomPadding = size * 0.03
        let available = rect.height - topPadding - bottomPadding
        let rowHeight = available / CGFloat(rows) * 0.62
        let rowGap = available / CGFloat(rows) * 0.38

        for row in 0..<rows {
            let y = rect.maxY - topPadding - CGFloat(row + 1) * (rowHeight + rowGap) + rowGap * 0.6
            if y < rect.minY + bottomPadding { break }
            let accent = accents[(row + pane) % accents.count]
            let swatch = NSRect(x: originX + size * 0.028, y: y, width: rowHeight, height: rowHeight)
            accent.withAlphaComponent(0.85).setFill()
            NSBezierPath(roundedRect: swatch, xRadius: rowHeight * 0.28, yRadius: rowHeight * 0.28).fill()

            let widths: [CGFloat] = [0.52, 0.66, 0.44, 0.58, 0.38, 0.62]
            let fraction = widths[(row * 2 + pane) % widths.count]
            let barWidth = (paneWidth - size * 0.06) * fraction
            let bar = NSRect(x: originX + size * 0.028 + rowHeight + size * 0.022, y: y + rowHeight * 0.22,
                             width: barWidth, height: rowHeight * 0.56)
            NSColor(calibratedWhite: 0.22, alpha: 0.55).setFill()
            NSBezierPath(roundedRect: bar, xRadius: bar.height * 0.4, yRadius: bar.height * 0.4).fill()
        }
    }

    // Centre divider
    let divider = NSRect(x: margin + paneWidth + gap * 0.35, y: margin,
                         width: gap * 0.3, height: paneRect.height)
    NSColor(calibratedRed: 0.36, green: 0.62, blue: 0.98, alpha: 0.9).setFill()
    NSBezierPath(rect: divider).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    FileHandle.standardError.write("usage: make_icon.swift <output.iconset>\n".data(using: .utf8)!)
    exit(1)
}

let outputDirectory = URL(fileURLWithPath: arguments[1])
try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

let mapping: [(Int, String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png")
]

var cache: [Int: Data] = [:]
for (pixelSize, name) in mapping {
    let data: Data
    if let cached = cache[pixelSize] {
        data = cached
    } else {
        let rep = makeImage(pixelSize: pixelSize)
        guard let encoded = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write("cannot encode \(name)\n".data(using: .utf8)!)
            exit(1)
        }
        cache[pixelSize] = encoded
        data = encoded
    }
    try data.write(to: outputDirectory.appendingPathComponent(name))
}

print("wrote \(mapping.count) icon files to \(outputDirectory.path)")
