import AppKit

/// The Accessibility API and Cocoa disagree about where the origin is.
///
/// - Cocoa: origin is the BOTTOM-left of the primary screen, y grows upward.
/// - Accessibility: origin is the TOP-left of the primary screen, y grows downward.
///
/// Every rect that crosses that boundary has to be flipped. The conversion is its
/// own inverse, so one function would do, but two names keep call sites readable.
enum Geometry {

    /// Height of the primary screen (the one owning the menu bar). This is the
    /// pivot for the flip — NOT the union of all screens.
    static var primaryHeight: CGFloat {
        NSScreen.screens.first?.frame.maxY ?? 0
    }

    static func cocoaToAX(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX,
               y: primaryHeight - rect.maxY,
               width: rect.width,
               height: rect.height)
    }

    static func axToCocoa(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX,
               y: primaryHeight - rect.maxY,
               width: rect.width,
               height: rect.height)
    }

    /// The screen a window "belongs" to: whichever screen contains its centre.
    /// Falls back to the screen with the largest overlap, then to primary, so a
    /// window dragged half off-screen still lands somewhere sane.
    static func screen(containing rect: CGRect) -> NSScreen? {
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        if let hit = NSScreen.screens.first(where: { $0.frame.contains(centre) }) {
            return hit
        }
        return NSScreen.screens.max { a, b in
            a.frame.intersection(rect).area < b.frame.intersection(rect).area
        } ?? NSScreen.screens.first
    }
}

extension CGRect {
    var area: CGFloat { isNull || isEmpty ? 0 : width * height }

    /// Rounded to whole pixels. Apps quantise their own frames anyway; doing it
    /// up front keeps our "did this actually move?" comparisons honest.
    var rounded: CGRect {
        CGRect(x: x_round(minX), y: x_round(minY), width: x_round(width), height: x_round(height))
    }

    private func x_round(_ v: CGFloat) -> CGFloat { (v).rounded() }

    func nearlyEquals(_ other: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(minX - other.minX) <= tolerance &&
        abs(minY - other.minY) <= tolerance &&
        abs(width - other.width) <= tolerance &&
        abs(height - other.height) <= tolerance
    }
}
