import AppKit

/// Turns "drag one window onto another" into a split.
///
/// Drop a window on the left or right half of another and they become columns;
/// drop it on the top or bottom half and they become rows. Do it again onto one
/// of those rows and you get three. Which half you release over is what picks
/// the direction — nearest edge wins.
final class DragWatcher {
    static let shared = DragWatcher()
    private init() {}

    private var monitors: [Any] = []
    private let overlay = DropOverlay()

    /// The window picked up at mouse-down, and where its tile was.
    private var candidate: CGWindowID?
    private var candidateTile: CGRect = .zero
    private(set) var isDragging = false
    private var lastProbe = Date.distantPast
    private var pendingDrop: (target: CGWindowID, axis: SplitAxis, before: Bool)?

    /// How far a window must actually move before we treat it as a drag rather
    /// than a click. Checked against the window's real position, not the mouse,
    /// so selecting text or dragging a scrollbar never triggers a re-layout.
    private let dragThreshold: CGFloat = 24

    /// Probing a window's live frame is an IPC round-trip, so rate-limit it.
    private let probeInterval: TimeInterval = 0.06

    func start() {
        guard monitors.isEmpty, AX.isTrusted else { return }

        add(.leftMouseDown) { [weak self] in self?.mouseDown() }
        add(.leftMouseDragged) { [weak self] in self?.mouseDragged() }
        add(.leftMouseUp) { [weak self] in self?.mouseUp() }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        reset()
    }

    private func add(_ mask: NSEvent.EventTypeMask, _ handler: @escaping () -> Void) {
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { _ in handler() }) {
            monitors.append(monitor)
        }
    }

    // MARK: - Gesture

    private func mouseDown() {
        guard Settings.shared.autoTile else { return }
        reset()

        let point = NSEvent.mouseLocation
        guard let hit = Tiler.shared.window(at: point, excluding: nil) else { return }
        candidate = hit.id
        candidateTile = hit.rect
    }

    private func mouseDragged() {
        guard let candidate,
              let window = Tiler.shared.windowsByID[candidate]
        else { return }

        if !isDragging {
            guard Date().timeIntervalSince(lastProbe) > probeInterval else { return }
            lastProbe = Date()

            // Has the window itself actually moved off its tile?
            guard let live = WindowManager.currentFrame(of: window) else { return }
            let moved = hypot(live.minX - candidateTile.minX, live.minY - candidateTile.minY)
            guard moved > dragThreshold else { return }
            isDragging = true
        }

        updatePreview(at: NSEvent.mouseLocation)
    }

    private func mouseUp() {
        defer { reset() }
        overlay.hide()

        guard isDragging, let candidate else { return }

        if let drop = pendingDrop {
            Tiler.shared.drop(candidate, onto: drop.target, axis: drop.axis, before: drop.before)
        } else {
            // Released over nothing — put it back where it belongs.
            Tiler.shared.retile()
        }
    }

    // MARK: - Drop zone

    private func updatePreview(at point: CGPoint) {
        guard let target = Tiler.shared.window(at: point, excluding: candidate) else {
            pendingDrop = nil
            overlay.hide()
            return
        }

        let zone = dropZone(point: point, in: target.rect)
        pendingDrop = (target.id, zone.axis, zone.before)
        overlay.show(zone.preview)
    }

    /// Nearest edge decides the split: compare how far the cursor is from the
    /// tile's centre horizontally versus vertically, as a fraction of each side,
    /// so the choice feels the same on a wide tile as on a tall one.
    private func dropZone(point: CGPoint, in rect: CGRect)
        -> (axis: SplitAxis, before: Bool, preview: CGRect) {

        let dx = (point.x - rect.midX) / max(rect.width, 1)
        let dy = (point.y - rect.midY) / max(rect.height, 1)

        if abs(dx) > abs(dy) {
            let left = dx < 0
            let half = CGRect(x: left ? rect.minX : rect.midX, y: rect.minY,
                              width: rect.width / 2, height: rect.height)
            return (.columns, left, half)
        } else {
            // Cocoa's y grows upward, so the upper half is the "before" child.
            let top = dy > 0
            let half = CGRect(x: rect.minX, y: top ? rect.midY : rect.minY,
                              width: rect.width, height: rect.height / 2)
            return (.rows, top, half)
        }
    }

    private func reset() {
        candidate = nil
        candidateTile = .zero
        isDragging = false
        pendingDrop = nil
    }
}
