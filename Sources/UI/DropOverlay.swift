import AppKit

/// Translucent highlight showing where a dragged window will land.
///
/// Borderless, click-through and on every Space, so it can float over whatever
/// app you are dragging without ever intercepting the drag itself.
final class DropOverlay {
    private var window: NSWindow?

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: .zero,
                              styleMask: .borderless,
                              backing: .buffered,
                              defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.contentView = HighlightView()
        return window
    }

    func show(_ rect: CGRect) {
        let window = self.window ?? makeWindow()
        self.window = window

        guard rect.width > 1, rect.height > 1 else { hide(); return }
        window.setFrame(rect, display: true)
        if !window.isVisible { window.orderFront(nil) }
    }

    func hide() {
        window?.orderOut(nil)
    }

    private final class HighlightView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            let inset = bounds.insetBy(dx: 2, dy: 2)
            let path = NSBezierPath(roundedRect: inset, xRadius: 8, yRadius: 8)

            NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
            path.fill()

            NSColor.controlAccentColor.withAlphaComponent(0.9).setStroke()
            path.lineWidth = 3
            path.stroke()
        }
    }
}
