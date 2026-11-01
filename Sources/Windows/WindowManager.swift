import AppKit
import ApplicationServices

/// One tileable window, snapshotted at scan time.
struct ManagedWindow: Identifiable, Hashable {
    let element: AXUIElement
    let id: CGWindowID
    let pid: pid_t
    let appName: String
    let bundleID: String?
    let title: String
    /// Cocoa coordinates (bottom-left origin), matching NSScreen.
    let frame: CGRect

    static func == (a: ManagedWindow, b: ManagedWindow) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

enum WindowManager {

    /// Windows we should never touch even if they pass every other test.
    private static let alwaysSkip: Set<String> = [
        "com.apple.dock",
        "com.apple.notificationcenterui",
        "com.apple.controlcenter",
        "com.apple.WindowManager",
        "com.apple.loginwindow",
        "com.apple.Spotlight",
    ]

    /// CGWindowIDs currently composited on the active Space.
    ///
    /// This is the Space filter. Only window IDs, bounds and owner PIDs are
    /// returned without Screen Recording permission — which is all we read — so
    /// this deliberately never touches kCGWindowName.
    private static func onScreenIDs() -> Set<CGWindowID> {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]]
        else { return [] }

        var ids = Set<CGWindowID>()
        for entry in info {
            // Layer 0 is the normal window layer. Anything else is a panel,
            // menu, shadow helper or the desktop itself.
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                  let number = entry[kCGWindowNumber as String] as? CGWindowID
            else { continue }
            ids.insert(number)
        }
        return ids
    }

    /// Every window that is a candidate for tiling, on the current Space.
    static func tileableWindows() -> [ManagedWindow] {
        guard AX.isTrusted else { return [] }

        let onScreen = onScreenIDs()
        let selfPID = ProcessInfo.processInfo.processIdentifier

        var result: [ManagedWindow] = []

        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular,
                  app.processIdentifier != selfPID,
                  !app.isHidden
            else { continue }

            let bundleID = app.bundleIdentifier
            if let bundleID, alwaysSkip.contains(bundleID) { continue }
            if UniversalIgnore.shared.isIgnored(bundleID: bundleID) { continue }

            let appElement = AXUIElementCreateApplication(app.processIdentifier)

            for window in AX.elements(appElement, kAXWindowsAttribute) {
                guard let win = inspect(window,
                                        pid: app.processIdentifier,
                                        appName: app.localizedName ?? "App",
                                        bundleID: bundleID,
                                        onScreen: onScreen)
                else { continue }
                result.append(win)
            }
        }
        return result
    }

    /// Validates a single AX window and snapshots it, or returns nil if it is
    /// not something we should be moving.
    private static func inspect(_ window: AXUIElement,
                                pid: pid_t,
                                appName: String,
                                bundleID: String?,
                                onScreen: Set<CGWindowID>) -> ManagedWindow? {

        // Sheets, drawers, popovers and palettes all report a non-standard
        // subrole. Only real document/app windows tile well.
        guard AX.string(window, kAXSubroleAttribute) == (kAXStandardWindowSubrole as String)
        else { return nil }

        if AX.bool(window, kAXMinimizedAttribute) == true { return nil }
        // A window in native fullscreen owns its own Space; leave it alone.
        if AX.bool(window, "AXFullScreen") == true { return nil }

        guard let id = AX.windowID(window), onScreen.contains(id) else { return nil }

        guard let origin = AX.point(window, kAXPositionAttribute),
              let size = AX.size(window, kAXSizeAttribute)
        else { return nil }

        // Tiny windows are nearly always inspectors, HUDs or find bars.
        guard !UniversalIgnore.shared.isTooSmall(size) else { return nil }

        let axFrame = CGRect(origin: origin, size: size)

        return ManagedWindow(
            element: window,
            id: id,
            pid: pid,
            appName: appName,
            bundleID: bundleID,
            title: AX.string(window, kAXTitleAttribute) ?? "",
            frame: Geometry.axToCocoa(axFrame)
        )
    }

    /// Re-reads a window's position and size right now. Used during a drag to
    /// tell a real window move from a click inside the window.
    static func currentFrame(of window: ManagedWindow) -> CGRect? {
        guard let origin = AX.point(window.element, kAXPositionAttribute),
              let size = AX.size(window.element, kAXSizeAttribute)
        else { return nil }
        return Geometry.axToCocoa(CGRect(origin: origin, size: size))
    }

    /// Moves and resizes a window to a Cocoa-space rect.
    ///
    /// The set-size / set-position / set-size dance is not superstition: many
    /// apps clamp a new size against the *old* position (so a move-then-resize
    /// near a screen edge gets truncated), and some refuse to shrink before
    /// they have moved. Writing size, then position, then size again converges
    /// for every app tested. A window with a hard minimum size simply keeps it.
    /// `force` skips the no-op check. `window.frame` is a snapshot from the last
    /// scan, so after a drag it still holds the window's OLD tile position — which
    /// is exactly the rect we are trying to restore. Without `force`, a drift
    /// correction would look like a no-op and be skipped.
    @discardableResult
    static func place(_ window: ManagedWindow, at cocoaRect: CGRect, force: Bool = false) -> Bool {
        let target = Geometry.cocoaToAX(cocoaRect).rounded
        if !force, window.frame.rounded.nearlyEquals(cocoaRect.rounded) { return true }

        AX.setSize(window.element, kAXSizeAttribute, target.size)
        AX.setPoint(window.element, kAXPositionAttribute, target.origin)
        AX.setSize(window.element, kAXSizeAttribute, target.size)
        return true
    }
}
