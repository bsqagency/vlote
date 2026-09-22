import AppKit

/// The menu bar glyph: the same main-plus-stack motif as the app icon.
///
/// Drawn in code rather than shipped as an asset so it stays crisp at any
/// scale factor, and marked as a template image so macOS recolours it for
/// light, dark and the highlighted (clicked) state automatically. Template
/// images must be drawn in flat black — the system derives everything else
/// from the alpha channel.
enum StatusIcon {

    /// Menu bar glyphs live in roughly an 18x18 box, with the drawn content a
    /// little shorter so it optically centres against the menu bar text.
    private static let size = NSSize(width: 18, height: 15)

    /// Filled while arranging, outlined while paused. A dimmed version of the
    /// same shape is easy to miss; a hollow one reads as "off" at a glance.
    static func image(active: Bool) -> NSImage {
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
