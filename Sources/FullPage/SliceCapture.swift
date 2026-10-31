import AppKit
import ScreenCaptureKit

/// One viewport capture, cropped to the page viewport, with the scroll offset it was taken at.
struct CapturedSlice {
    let image: CGImage
    /// Actual scrollY when captured (CSS px).
    let scrollY: Double
}

/// Step 3: scroll to each offset, capture the browser window, crop to the viewport.
enum SliceCapture {

    private static let settleDelay: UInt64 = 250_000_000

    /// The frontmost on-screen, normal-layer window of the browser.
    static func findWindow(for browser: Browser) async throws -> SCWindow {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let match = content.windows.first { window in
            window.owningApplication?.bundleIdentifier == browser.id
                && window.windowLayer == 0
                && window.isOnScreen
                && window.frame.width > 200
                && window.frame.height > 200
        }
        guard let window = match else { throw FullPageError.noWindow }
        fpLog("window \(window.windowID) frame=\(window.frame)")
        return window
    }

    /// Scroll offsets: 0, vh, 2vh, … and the last one aligned to the bottom (scrollHeight - vh).
    static func offsets(scrollHeight: Double, viewportHeight: Double) -> [Double] {
        let maxY = max(0, scrollHeight - viewportHeight)
        var out: [Double] = []
        var y = 0.0
        while y < maxY - 0.5 {
            out.append(y)
            y += viewportHeight
        }
        out.append(maxY)
        return out
    }

    /// Captures every offset in order. Fixed/sticky elements are visible only in the first slice.
    /// `progress(done, total)` is called before each slice (done = 1-based slice number).
    /// Throws `FullPageError.cancelled` if the browser or its window loses focus mid-capture.
    static func captureAll(browser: Browser, probe: PageProbe, window: SCWindow,
                           progress: ((Int, Int) -> Void)? = nil) async throws -> [CapturedSlice] {
        let targets = offsets(scrollHeight: probe.scrollHeight, viewportHeight: probe.innerHeight)
        fpLog("capturing \(targets.count) slices")

        var slices: [CapturedSlice] = []
        for (index, target) in targets.enumerated() {
            try await ensureStillFocused(browser: browser, window: window)
            progress?(index + 1, targets.count)

            if index == 0 { try await PagePrep.setOverlaysShown(browser, true) }
            if index == 1 { try await PagePrep.setOverlaysShown(browser, false) }

            let (actual, _) = try await PagePrep.scroll(browser, to: target)
            try await Task.sleep(nanoseconds: settleDelay)

            let image = try await captureViewport(window: window, probe: probe)
            slices.append(CapturedSlice(image: image, scrollY: actual))
            fpLog("slice \(index + 1)/\(targets.count) at scrollY \(Int(actual)) size \(image.width)x\(image.height)")
        }
        return slices
    }

    /// The browser must still be the frontmost app and show the same window as at the start.
    private static func ensureStillFocused(browser: Browser, window: SCWindow) async throws {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == browser.id else {
            throw FullPageError.cancelled
        }
        let current = try? await findWindow(for: browser)
        guard current?.windowID == window.windowID else { throw FullPageError.cancelled }
    }

    /// Captures the window at native scale and crops it to the page viewport.
    /// Viewport origin = window outer origin + browser chrome (outer minus inner size).
    private static func captureViewport(window: SCWindow, probe: PageProbe) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        let frame = window.frame

        let cfg = SCStreamConfiguration()
        cfg.width = max(1, Int((frame.width * scale).rounded()))
        cfg.height = max(1, Int((frame.height * scale).rounded()))
        cfg.showsCursor = false
        cfg.colorSpaceName = CGColorSpace.displayP3
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.captureResolution = .best
        cfg.ignoreShadowsSingleWindow = true

        let full = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)

        // Points per captured pixel, measured from the image itself.
        let s = CGFloat(full.width) / max(frame.width, 1)
        let originX = (probe.screenX + (probe.outerWidth - probe.innerWidth) / 2) - Double(frame.minX)
        let originY = (probe.screenY + (probe.outerHeight - probe.innerHeight)) - Double(frame.minY)

        let rect = CGRect(x: CGFloat(originX) * s,
                          y: CGFloat(originY) * s,
                          width: CGFloat(probe.innerWidth) * s,
                          height: CGFloat(probe.innerHeight) * s)
        let clipped = rect.integral.intersection(CGRect(x: 0, y: 0, width: full.width, height: full.height))
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1,
              let cropped = full.cropping(to: clipped)
        else { throw FullPageError.cropFailed }
        return cropped
    }
}
