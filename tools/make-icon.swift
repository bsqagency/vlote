import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Draws the app icon at each size macOS wants, then hands off to iconutil.
/// Rendering every size directly (rather than downscaling one big image) keeps
/// the 16pt version legible instead of a grey smudge.

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Macnizer.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func render(_ px: Int) -> CGImage? {
    let s = CGFloat(px)
    guard let ctx = CGContext(data: nil, width: px, height: px,
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }

    // macOS icons sit inside the canvas with a margin rather than filling it.
    let inset = s * 0.055
    let plate = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = plate.width * 0.2237      // Big Sur squircle approximation

    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: plate, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.clip()

    let colors = [
        CGColor(red: 0.36, green: 0.42, blue: 0.95, alpha: 1),
        CGColor(red: 0.30, green: 0.24, blue: 0.78, alpha: 1),
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 colors: colors, locations: [0, 1]) {
        ctx.drawLinearGradient(gradient,
                               start: CGPoint(x: plate.minX, y: plate.maxY),
                               end: CGPoint(x: plate.maxX, y: plate.minY),
                               options: [])
    }
    ctx.restoreGState()

    // The motif is the app's whole idea: one main tile, two stacked beside it.
    let pad = plate.width * 0.20
    let area = plate.insetBy(dx: pad, dy: pad)
    let gap = max(area.width * 0.055, s * 0.012)
    let tileRadius = max(area.width * 0.055, 1)

    let leftWidth = (area.width - gap) * 0.54
    let rightWidth = area.width - gap - leftWidth
    let rightHeight = (area.height - gap) / 2

    let tiles = [
        CGRect(x: area.minX, y: area.minY, width: leftWidth, height: area.height),
        CGRect(x: area.minX + leftWidth + gap, y: area.midY + gap / 2,
               width: rightWidth, height: rightHeight),
        CGRect(x: area.minX + leftWidth + gap, y: area.minY,
               width: rightWidth, height: rightHeight),
    ]

    for (index, tile) in tiles.enumerated() {
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: index == 0 ? 0.97 : 0.80))
        ctx.addPath(CGPath(roundedRect: tile, cornerWidth: tileRadius,
                           cornerHeight: tileRadius, transform: nil))
        ctx.fillPath()
    }
    return ctx.makeImage()
}

let sizes: [(String, Int)] = [
    ("icon_16x16", 16),    ("icon_16x16@2x", 32),
    ("icon_32x32", 32),    ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for (name, px) in sizes {
    guard let image = render(px) else { print("failed \(name)"); exit(1) }
    let url = URL(fileURLWithPath: "\(outDir)/\(name).png")
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { print("failed dest \(name)"); exit(1) }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}
print("rendered \(sizes.count) sizes into \(outDir)")
