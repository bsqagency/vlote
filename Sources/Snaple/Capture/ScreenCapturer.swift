import AppKit
import ScreenCaptureKit

/// One display's frozen pixels, in the form the selection overlay needs.
struct DisplayFrame {
    let displayID: CGDirectDisplayID
    let image: CGImage
    /// Device pixels per point.
    let scale: CGFloat
    let screen: NSScreen
    /// Global display bounds in CoreGraphics space (top-left origin, points).
    let bounds: CGRect
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

/// Thin ScreenCaptureKit wrapper. `SCScreenshotManager` is a one-shot capture (no stream to spin up),
/// which is what keeps hotkey-to-pixels well inside the 100 ms budget.
@MainActor
final class ScreenCapturer {
    static let shared = ScreenCapturer()

    private var displays: [CGDirectDisplayID: SCDisplay] = [:]
    private var ownApp: SCRunningApplication?

    /// Refreshes the shareable-content cache. Called lazily — never at launch, so the permission
    /// prompt appears only when the user first asks for a capture.
    func refresh() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        displays = Dictionary(uniqueKeysWithValues: content.displays.map { ($0.displayID, $0) })
        let pid = ProcessInfo.processInfo.processIdentifier
        ownApp = content.applications.first { $0.processID == pid }
    }

    /// Our own thumbnails/editor must not appear in captures. They are only a concern while visible,
    /// so the (slower) cache refresh is skipped on the common no-windows path.
    private var hasOwnWindowsOnScreen: Bool {
        NSApp.windows.contains { $0.isVisible && $0.level != .statusBar && !($0 is OverlayWindow) }
    }

    private func prepare() async throws {
        if displays.isEmpty || hasOwnWindowsOnScreen { try await refresh() }
    }

    private func filter(for display: SCDisplay) -> SCContentFilter {
        SCContentFilter(display: display, excludingApplications: ownApp.map { [$0] } ?? [], exceptingWindows: [])
    }

    private func configuration(width: CGFloat, height: CGFloat, scale: CGFloat, cursor: Bool) -> SCStreamConfiguration {
        let cfg = SCStreamConfiguration()
        cfg.width = max(1, Int((width * scale).rounded()))
        cfg.height = max(1, Int((height * scale).rounded()))
        cfg.showsCursor = cursor
        cfg.colorSpaceName = CGColorSpace.displayP3
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.captureResolution = .best
        return cfg
    }

    /// Captures all displays in parallel for the freeze-frame selection overlay.
    func captureAllDisplays(includeCursor: Bool) async throws -> [DisplayFrame] {
        try await prepare()
        let screens = NSScreen.screens.compactMap { s in s.displayID.map { ($0, s) } }
        guard !screens.isEmpty else { throw CaptureError.noDisplay }

        return try await withThrowingTaskGroup(of: DisplayFrame?.self) { group in
            for (id, screen) in screens {
                guard let display = displays[id] else { continue }
                let f = filter(for: display)
                let scale = CGFloat(f.pointPixelScale)
                let cfg = configuration(width: CGFloat(display.width), height: CGFloat(display.height), scale: scale, cursor: includeCursor)
                let bounds = CGDisplayBounds(id)
                group.addTask {
                    let image = try await SCScreenshotManager.captureImage(contentFilter: f, configuration: cfg)
                    return DisplayFrame(displayID: id, image: image, scale: scale, screen: screen, bounds: bounds)
                }
            }
            var out: [DisplayFrame] = []
            for try await frame in group { if let frame { out.append(frame) } }
            guard !out.isEmpty else { throw CaptureError.noDisplay }
            return out
        }
    }

    /// Live capture of a display, or of a sub-rectangle (`sourceRect`: display-local points, top-left origin).
    func captureDisplay(id: CGDirectDisplayID, sourceRect: CGRect?, includeCursor: Bool) async throws -> (image: CGImage, scale: CGFloat) {
        try await prepare()
        guard let display = displays[id] else { throw CaptureError.noDisplay }
        let f = filter(for: display)
        let scale = CGFloat(f.pointPixelScale)
        let rect = sourceRect ?? CGRect(x: 0, y: 0, width: CGFloat(display.width), height: CGFloat(display.height))
        let cfg = configuration(width: rect.width, height: rect.height, scale: scale, cursor: includeCursor)
        if sourceRect != nil { cfg.sourceRect = rect }
        let image = try await SCScreenshotManager.captureImage(contentFilter: f, configuration: cfg)
        return (image, scale)
    }

    /// Captures one window by ID. Works for occluded windows, and the system shadow is excluded —
    /// a consistent synthesized shadow is added afterwards when the user wants one.
    func captureWindow(id: CGWindowID) async throws -> (image: CGImage, scale: CGFloat) {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == id }) else { throw CaptureError.windowNotFound }
        let f = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(f.pointPixelScale)
        let rect = f.contentRect
        let cfg = configuration(width: rect.width, height: rect.height, scale: scale, cursor: false)
        cfg.ignoreShadowsSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: f, configuration: cfg)
        return (image, scale)
    }
}
