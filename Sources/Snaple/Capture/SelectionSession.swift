import AppKit

struct WindowInfo {
    let id: CGWindowID
    /// Global CoreGraphics bounds (top-left origin).
    let bounds: CGRect
}

enum SelectionResult {
    case region(DisplayFrame, CGRect)   // rect in the display's view points, top-left origin
    case window(CGWindowID)
    case color(String)
    case cancelled
}

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Freeze-frame selection: the screen is captured once up front, then shown full-bleed on every display.
/// Choosing a region is a crop of those frozen pixels — instant, tear-free, and it captures exactly what
/// you saw when you pressed the hotkey (menus, hover states, video frames included).
@MainActor
final class SelectionSession {
    let frames: [DisplayFrame]
    let windows: [WindowInfo]
    var windowMode: Bool {
        didSet { views.forEach { $0.needsDisplay = true } }
    }

    private var panels: [OverlayWindow] = []
    private var views: [OverlayView] = []
    private var monitor: Any?
    private var completion: ((SelectionResult) -> Void)?

    init(frames: [DisplayFrame], windowMode: Bool) {
        self.frames = frames
        self.windowMode = windowMode
        self.windows = Self.onScreenWindows()
    }

    /// Front-to-back list of normal app windows, excluding our own.
    private static func onScreenWindows() -> [WindowInfo] {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        return list.compactMap { d in
            guard (d[kCGWindowLayer as String] as? Int) == 0,
                  let number = (d[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (d[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid != me,
                  let dict = d[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict as CFDictionary),
                  bounds.width > 40, bounds.height > 40,
                  ((d[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0.01 else { return nil }
            return WindowInfo(id: number, bounds: bounds)
        }
    }

    func window(atGlobal p: CGPoint) -> WindowInfo? { windows.first { $0.bounds.contains(p) } }

    func begin(completion: @escaping (SelectionResult) -> Void) {
        self.completion = completion
        for frame in frames {
            let panel = OverlayWindow(contentRect: frame.screen.frame, styleMask: .borderless,
                                      backing: .buffered, defer: false, screen: frame.screen)
            panel.setFrame(frame.screen.frame, display: false)
            panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.isReleasedWhenClosed = false
            panel.acceptsMouseMovedEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            let view = OverlayView(frame: CGRect(origin: .zero, size: frame.screen.frame.size), display: frame, session: self)
            panel.contentView = view
            panels.append(panel)
            views.append(view)
        }

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            switch event.keyCode {
            case 53: self.finish(.cancelled); return nil                    // esc
            case 49: self.windowMode.toggle(); return nil                   // space: area ⇄ window
            case 8: if let hex = self.hexUnderCursor() { self.finish(.color(hex)) }; return nil   // C
            default: return event
            }
        }

        NSApp.activate(ignoringOtherApps: true)
        panels.forEach { $0.makeKeyAndOrderFront(nil) }
        views.forEach { $0.syncCursorFromMouse() }
    }

    func finish(_ result: SelectionResult) {
        guard let completion else { return }
        self.completion = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll(); views.removeAll()
        NSCursor.arrow.set()
        completion(result)
    }

    func cursorMoved(on active: OverlayView) {
        for v in views where v !== active { v.clearCursor() }
    }

    private func hexUnderCursor() -> String? {
        let m = NSEvent.mouseLocation
        guard let f = frames.first(where: { $0.screen.frame.contains(m) }) else { return nil }
        let px = Int(((m.x - f.screen.frame.minX) * f.scale).rounded(.down))
        let py = Int(((f.screen.frame.maxY - m.y) * f.scale).rounded(.down))
        guard let c = ImageOps.pixelColor(in: f.image, x: px, y: py) else { return nil }
        return String(format: "#%02X%02X%02X", c.r, c.g, c.b)
    }
}

final class OverlayView: NSView {
    private let display: DisplayFrame
    private unowned let session: SelectionSession
    private var cursor: CGPoint?
    private var dragStart: CGPoint?
    private var selection: CGRect?
    private var hoverWindow: CGRect?
    private var hoverWindowID: CGWindowID?

    init(frame: NSRect, display: DisplayFrame, session: SelectionSession) {
        self.display = display
        self.session = session
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    func syncCursorFromMouse() {
        let m = NSEvent.mouseLocation
        let f = display.screen.frame
        guard f.contains(m) else { return }
        cursor = CGPoint(x: m.x - f.minX, y: f.maxY - m.y)
        updateHover()
        needsDisplay = true
    }

    func clearCursor() { cursor = nil; hoverWindow = nil; needsDisplay = true }

    private func updateHover() {
        guard session.windowMode, let cursor else { hoverWindow = nil; hoverWindowID = nil; return }
        let global = CGPoint(x: display.bounds.minX + cursor.x, y: display.bounds.minY + cursor.y)
        if let w = session.window(atGlobal: global) {
            hoverWindowID = w.id
            hoverWindow = w.bounds.offsetBy(dx: -display.bounds.minX, dy: -display.bounds.minY).intersection(bounds)
        } else {
            hoverWindowID = nil; hoverWindow = nil
        }
    }

    // MARK: Mouse

    override func mouseMoved(with event: NSEvent) {
        cursor = convert(event.locationInWindow, from: nil)
        updateHover()
        session.cursorMoved(on: self)
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) { if dragStart == nil { clearCursor() } }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if session.windowMode {
            updateHover()
            if let id = hoverWindowID { session.finish(.window(id)) }
            return
        }
        dragStart = p
        selection = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        var p = convert(event.locationInWindow, from: nil)
        p.x = min(max(0, p.x), bounds.width); p.y = min(max(0, p.y), bounds.height)
        cursor = p
        if event.modifierFlags.contains(.shift) {
            let m = max(abs(p.x - start.x), abs(p.y - start.y))
            p = CGPoint(x: start.x + (p.x < start.x ? -m : m), y: start.y + (p.y < start.y ? -m : m))
        }
        selection = CGRect(from: start, to: p)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil }
        guard let sel = selection, sel.width >= 3, sel.height >= 3 else { selection = nil; needsDisplay = true; return }
        session.finish(.region(display, sel))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.interpolationQuality = .none
        ImageOps.drawUpright(display.image, in: bounds, ctx)

        let highlight = session.windowMode ? hoverWindow : selection
        if let h = highlight {
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.45))
            ctx.addRect(bounds); ctx.addRect(h)
            ctx.fillPath(using: .evenOdd)
            if session.windowMode {
                ctx.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor)
                ctx.fill(h)
                ctx.setStrokeColor(NSColor.controlAccentColor.cgColor); ctx.setLineWidth(3)
                ctx.stroke(h.insetBy(dx: 1.5, dy: 1.5))
            } else {
                ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.95)); ctx.setLineWidth(1)
                ctx.stroke(h.insetBy(dx: 0.5, dy: 0.5))
            }
            let px = "\(Int((h.width * display.scale).rounded())) × \(Int((h.height * display.scale).rounded()))"
            drawChip(px, anchoredBelow: h)
        } else {
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.12))
            ctx.fill(bounds)
            if session.windowMode, cursor != nil { drawChip("Click a window · Space for area · Esc to cancel", at: CGPoint(x: bounds.midX, y: 40), centered: true) }
        }

        if !session.windowMode, let cursor { drawLoupe(at: cursor, ctx) }
    }

    private func drawChip(_ text: String, anchoredBelow rect: CGRect) {
        let size = (text as NSString).size(withAttributes: chipAttrs)
        var y = rect.maxY + 8
        if y + size.height + 10 > bounds.height { y = rect.maxY - size.height - 18 }
        drawChip(text, at: CGPoint(x: min(max(rect.midX, size.width / 2 + 8), bounds.width - size.width / 2 - 8), y: y), centered: true)
    }

    private var chipAttrs: [NSAttributedString.Key: Any] {
        [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white]
    }

    private func drawChip(_ text: String, at point: CGPoint, centered: Bool) {
        let size = (text as NSString).size(withAttributes: chipAttrs)
        let rect = CGRect(x: centered ? point.x - size.width / 2 - 7 : point.x, y: point.y,
                          width: size.width + 14, height: size.height + 6)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        (text as NSString).draw(at: CGPoint(x: rect.minX + 7, y: rect.minY + 3), withAttributes: chipAttrs)
    }

    /// Pixel-exact magnifier: 15×15 device pixels, nearest-neighbour, with the centre pixel's sRGB hex.
    private func drawLoupe(at cur: CGPoint, _ ctx: CGContext) {
        let n = 15, cell: CGFloat = 8
        let size = CGFloat(n) * cell
        var origin = CGPoint(x: cur.x + 24, y: cur.y + 24)
        if origin.x + size > bounds.width - 8 { origin.x = cur.x - 24 - size }
        if origin.y + size + 26 > bounds.height - 8 { origin.y = cur.y - 24 - size - 26 }
        let box = CGRect(origin: origin, size: CGSize(width: size, height: size))

        let ix = Int((cur.x * display.scale).rounded(.down)), iy = Int((cur.y * display.scale).rounded(.down))
        let half = n / 2
        let want = CGRect(x: ix - half, y: iy - half, width: n, height: n)
        let have = want.intersection(CGRect(x: 0, y: 0, width: display.image.width, height: display.image.height))

        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: box, cornerWidth: 10, cornerHeight: 10, transform: nil))
        ctx.clip()
        ctx.setFillColor(CGColor(gray: 0.1, alpha: 1)); ctx.fill(box)
        if !have.isEmpty, let src = display.image.cropping(to: have) {
            let dest = CGRect(x: box.minX + (have.minX - want.minX) * cell, y: box.minY + (have.minY - want.minY) * cell,
                              width: have.width * cell, height: have.height * cell)
            ctx.interpolationQuality = .none
            ImageOps.drawUpright(src, in: dest, ctx)
        }
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.12)); ctx.setLineWidth(0.5)
        for i in 1..<n {
            let d = CGFloat(i) * cell
            ctx.move(to: CGPoint(x: box.minX + d, y: box.minY)); ctx.addLine(to: CGPoint(x: box.minX + d, y: box.maxY))
            ctx.move(to: CGPoint(x: box.minX, y: box.minY + d)); ctx.addLine(to: CGPoint(x: box.maxX, y: box.minY + d))
        }
        ctx.strokePath()
        let centre = CGRect(x: box.minX + CGFloat(half) * cell, y: box.minY + CGFloat(half) * cell, width: cell, height: cell)
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 1)); ctx.setLineWidth(2); ctx.stroke(centre.insetBy(dx: -1, dy: -1))
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 1)); ctx.setLineWidth(1); ctx.stroke(centre)
        ctx.restoreGState()
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.5)); ctx.setLineWidth(1)
        ctx.addPath(CGPath(roundedRect: box, cornerWidth: 10, cornerHeight: 10, transform: nil)); ctx.strokePath()

        var label = "\(ix), \(iy)"
        if let c = ImageOps.pixelColor(in: display.image, x: ix, y: iy) {
            label = String(format: "#%02X%02X%02X  ·  ", c.r, c.g, c.b) + label + "  ·  C to copy"
        }
        drawChip(label, at: CGPoint(x: box.minX, y: box.maxY + 4), centered: false)
    }
}
