import AppKit

/// Owns the arrangement and writes it to the screen.
///
/// One `LayoutNode` tree per screen. A preset rebuilds its screen's tree from
/// scratch; opening and closing windows syncs the existing tree so everything
/// already placed stays put; a drag-and-drop mutates it.
final class Tiler {
    static let shared = Tiler()
    private init() {}

    private var trees: [Int: LayoutNode] = [:]

    /// Stable window sequence, so rebuilding a preset does not reshuffle.
    private var order: [CGWindowID] = []

    /// Where each window currently sits. The drag watcher hit-tests against
    /// this rather than re-scanning, so it stays cheap during a drag.
    private(set) var tileFrames: [CGWindowID: CGRect] = [:]
    private(set) var windowsByID: [CGWindowID: ManagedWindow] = [:]

    /// Set while writing frames, so the window observer ignores our own moves.
    private(set) var isApplying = false

    /// Drift-correction bookkeeping. Some apps refuse the frame we give them and
    /// immediately set their own back — correcting those forever would peg the
    /// CPU and make the window flicker, so each one gets a limited number of
    /// attempts before we leave it alone.
    private var driftAttempts: [CGWindowID: (count: Int, since: Date)] = [:]
    private var resisting: Set<CGWindowID> = []

    /// How far a window may stray before we count it as knocked out of place.
    /// Generous enough to ignore an app nudging itself by a pixel or two.
    private let driftTolerance: CGFloat = 8
    private let maxCorrections = 4
    private let resistWindow: TimeInterval = 3

    // MARK: - Main entry points

    @discardableResult
    func retile() -> Int { run(rebuildPreset: false) }

    /// Discards the current arrangement and lays the preset out fresh.
    @discardableResult
    func applyPreset() -> Int { run(rebuildPreset: true) }

    func cycleLayout() {
        let all = LayoutKind.allCases
        let current = Settings.shared.layout
        let index = all.firstIndex(of: current) ?? 0
        Settings.shared.layout = all[(index + 1) % all.count]
        applyPreset()
    }

    func resetOrder() {
        order.removeAll()
        trees.removeAll()
        applyPreset()
    }

    // MARK: - Drift correction

    /// Puts windows back on their tiles after something moved them — a drag that
    /// did not land on another window, an app repositioning itself, a manual
    /// resize.
    ///
    /// Only one window is touched per correction, so snapping one back never
    /// disturbs the rest of the arrangement.
    @discardableResult
    func correctDrift() -> Int {
        guard AX.isTrusted,
              Settings.shared.autoTile,
              Settings.shared.snapBack,
              !isApplying,
              !tileFrames.isEmpty
        else { return 0 }

        // A button still held means the gesture is not over. Correcting now
        // would yank the window out from under the cursor.
        guard NSEvent.pressedMouseButtons == 0, !DragWatcher.shared.isDragging else { return 0 }

        let now = Date()
        var corrected = 0

        isApplying = true
        defer { isApplying = false }

        for (id, expected) in tileFrames {
            guard !resisting.contains(id),
                  let window = windowsByID[id],
                  let actual = WindowManager.currentFrame(of: window)
            else { continue }

            guard !actual.nearlyEquals(expected, tolerance: driftTolerance) else {
                driftAttempts[id] = nil   // back where it belongs; forget its history
                continue
            }
            guard allowCorrection(of: id, now: now) else { continue }

            WindowManager.place(window, at: expected, force: true)
            corrected += 1
        }
        return corrected
    }

    /// Rate-limits corrections per window. A window that needs correcting more
    /// than `maxCorrections` times inside `resistWindow` is fighting back, so we
    /// stop until the next full retile. A quiet spell resets the count.
    private func allowCorrection(of id: CGWindowID, now: Date) -> Bool {
        var record = driftAttempts[id] ?? (count: 0, since: now)
        if now.timeIntervalSince(record.since) > resistWindow {
            record = (count: 0, since: now)
        }
        record.count += 1
        driftAttempts[id] = record

        guard record.count <= maxCorrections else {
            resisting.insert(id)
            NSLog("Macnizer: window \(id) keeps rejecting its frame — leaving it alone until the next full retile")
            return false
        }
        return true
    }

    // MARK: - Drag and drop

    /// Moves `dragged` to sit beside `target`, splitting along `axis`.
    /// This is the whole point of the tree: the target's tile subdivides and
    /// every other window keeps its place.
    func drop(_ dragged: CGWindowID,
              onto target: CGWindowID,
              axis: SplitAxis,
              before: Bool) {
        guard dragged != target else { retile(); return }

        // Pull the dragged window out of whichever screen's tree holds it.
        for (screen, tree) in trees {
            if tree.contains(dragged) { trees[screen] = tree.removing(dragged) }
        }
        // Then insert it next to the target.
        for (screen, tree) in trees where tree.contains(target) {
            trees[screen] = tree.inserting(dragged, beside: target, axis: axis, before: before)
        }

        // Keep the stable order in step so a later preset rebuild agrees.
        order.removeAll { $0 == dragged }
        if let at = order.firstIndex(of: target) {
            order.insert(dragged, at: before ? at : at + 1)
        } else {
            order.append(dragged)
        }
        retile()
    }

    /// The tile under a screen point, ignoring `excluding` (the window in hand).
    func window(at point: CGPoint, excluding: CGWindowID?) -> (id: CGWindowID, rect: CGRect)? {
        for (id, rect) in tileFrames where id != excluding && rect.contains(point) {
            return (id, rect)
        }
        return nil
    }

    // MARK: - The work

    private func run(rebuildPreset: Bool) -> Int {
        guard AX.isTrusted else {
            Diagnostics.shared.log("retile skipped — accessibility not trusted")
            return 0
        }

        let windows = WindowManager.tileableWindows()
        windowsByID = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
        Diagnostics.shared.managedCount = windows.count

        guard !windows.isEmpty else {
            trees.removeAll(); order.removeAll(); tileFrames.removeAll()
            resisting.removeAll(); driftAttempts.removeAll()
            return 0
        }

        // A full retile is a fresh start — let previously stubborn windows try again.
        resisting.removeAll()
        driftAttempts.removeAll()

        updateOrder(with: windows)

        let settings = Settings.shared
        let screens = NSScreen.screens
        let grouped = groupByScreen(windows)

        isApplying = true
        defer { isApplying = false }

        var frames: [CGWindowID: CGRect] = [:]
        var placed = 0

        for (screenIndex, group) in grouped {
            guard screens.indices.contains(screenIndex) else { continue }
            let area = screens[screenIndex].visibleFrame
                .insetBy(dx: settings.outerGap, dy: settings.outerGap)
            guard area.width > 0, area.height > 0 else { continue }

            // Preset order within this screen follows the global stable order.
            let ids = order.filter { id in group.contains { $0.id == id } }

            let tree: LayoutNode?
            if rebuildPreset {
                tree = LayoutNode.build(kind: settings.layout,
                                        ids: ids,
                                        masterRatio: settings.masterRatio)
            } else {
                tree = LayoutNode.sync(trees[screenIndex], to: ids, in: area, gap: settings.gap)
                    ?? LayoutNode.build(kind: settings.layout,
                                        ids: ids,
                                        masterRatio: settings.masterRatio)
            }
            guard let tree else { trees[screenIndex] = nil; continue }
            trees[screenIndex] = tree

            let screenFrames = tree.frames(in: area, gap: settings.gap)
            for (id, rect) in screenFrames {
                frames[id] = rect
                if let window = windowsByID[id] {
                    WindowManager.place(window, at: rect)
                    placed += 1
                }
            }
        }

        // Forget trees for screens that no longer have windows.
        for index in trees.keys where grouped[index] == nil { trees[index] = nil }

        tileFrames = frames
        Diagnostics.shared.lastRetile = Date()
        Diagnostics.shared.log("\(rebuildPreset ? "preset" : "retile"): \(windows.count) windows, placed \(placed)")
        return placed
    }

    /// Keeps known windows in their existing sequence and appends new ones,
    /// sorted so a cold start is deterministic instead of following whatever
    /// order the Accessibility API happened to return.
    private func updateOrder(with windows: [ManagedWindow]) {
        let live = Set(windows.map(\.id))
        order.removeAll { !live.contains($0) }

        let known = Set(order)
        let newcomers = windows
            .filter { !known.contains($0.id) }
            .sorted { ($0.appName, $0.id) < ($1.appName, $1.id) }
        order.append(contentsOf: newcomers.map(\.id))
    }

    private func groupByScreen(_ windows: [ManagedWindow]) -> [Int: [ManagedWindow]] {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return [:] }

        var buckets: [Int: [ManagedWindow]] = [:]
        for window in windows {
            let screen = Geometry.screen(containing: window.frame)
            let index = screen.flatMap { screens.firstIndex(of: $0) } ?? 0
            buckets[index, default: []].append(window)
        }
        return buckets
    }
}
