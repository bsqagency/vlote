import AppKit

/// The menu bar glyph: the vlote logo, shipped as a template image so macOS
/// recolours it for light, dark and the highlighted (clicked) state.
///
/// Falls back to the drawn main-plus-stack glyph if the bundled PNGs are
/// missing, so the menu bar never shows an empty icon.
enum StatusIcon {

    private static let iconSize = NSSize(width: 18, height: 14)

    /// Loaded once. The 1x and 2x files are added as representations of one
    /// 18x14 image, so Retina displays pick the sharp 36x28px bitmap.
    private static let bundled: NSImage? = {
        guard let low = Bundle.main.url(forResource: "StatusIcon", withExtension: "png"),
              let high = Bundle.main.url(forResource: "StatusIcon@2x", withExtension: "png"),
              let lowRep = NSImageRep(contentsOf: low),
              let highRep = NSImageRep(contentsOf: high) else { return nil }
        lowRep.size = iconSize
        highRep.size = iconSize
        let image = NSImage(size: iconSize)
        image.addRepresentation(lowRep)
        image.addRepresentation(highRep)
        image.isTemplate = true
        return image
    }()

    /// Always full strength (black template, macOS recolours it). The `active`
    /// flag is kept for callers but does not change the icon look.
    static func image(active: Bool) -> NSImage {
        guard let logo = bundled else { return drawnGlyph(active: active) }
        return logo
    }

    /// Menu bar glyphs live in roughly an 18x18 box, with the drawn content a
    /// little shorter so it optically centres against the menu bar text.
    private static let size = NSSize(width: 18, height: 15)

    /// Filled while arranging, outlined while paused. A dimmed version of the
    /// same shape is easy to miss; a hollow one reads as "off" at a glance.
    private static func drawnGlyph(active: Bool) -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            let gap: CGFloat = 2
            let radius: CGFloat = 1.6
            let bounds = CGRect(origin: .zero, size: size)

            let leftWidth = (bounds.width - gap) * 0.52
            let rightWidth = bounds.width - gap - leftWidth
            let rightHeight = (bounds.height - gap) / 2
            let rightX = bounds.minX + leftWidth + gap

            let tiles = [
                CGRect(x: bounds.minX, y: bounds.minY, width: leftWidth, height: bounds.height),
                CGRect(x: rightX, y: bounds.maxY - rightHeight, width: rightWidth, height: rightHeight),
                CGRect(x: rightX, y: bounds.minY, width: rightWidth, height: rightHeight),
            ]

            NSColor.black.setFill()
            NSColor.black.setStroke()

            for tile in tiles {
                if active {
                    NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius).fill()
                } else {
                    // Inset by half the line width so the stroke stays inside
                    // the tile and the gaps do not visually close up.
                    let line: CGFloat = 1.3
                    let path = NSBezierPath(roundedRect: tile.insetBy(dx: line / 2, dy: line / 2),
                                            xRadius: radius, yRadius: radius)
                    path.lineWidth = line
                    path.stroke()
                }
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
