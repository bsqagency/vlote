import AppKit
import ScreenCaptureKit

/// Errors from the full-page capture flow.
enum FullPageError: LocalizedError {
    case notABrowser
    case noWindow
    case badProbe(String)
    case noSlices
    case cropFailed
    case bitmapFailed
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notABrowser: return "Open a page in Chrome or Safari first."
        case .noWindow: return "Could not find the browser window. Make sure it is visible."
        case .badProbe(let detail): return "Could not read the page (\(detail))."
        case .noSlices: return "No slices were captured."
        case .cropFailed: return "Could not crop the browser window."
        case .bitmapFailed: return "Could not create the full-page image. The page may be too tall."
        case .cancelled: return "Capture cancelled"
        }
    }
}

/// Debug log, visible in Console.app. Filter on "vlote-fp".
func fpLog(_ message: String) {
    NSLog("vlote-fp: %@", message)
}

/// Full-page screenshot of the active tab in a browser window: probe, prep, slice, stitch, restore.
enum FullPageCapture {

    /// Captures the whole page of the active tab in the browser's front window.
    /// `progress(done, total)` reports slices; `(0, 0)` means the page is being prepared.
    /// The page scroll position and the injected style are restored before returning or throwing.
    static func run(browser: Browser, progress: ((Int, Int) -> Void)? = nil) async throws -> CGImage {
        fpLog("start in \(browser.name)")
        progress?(0, 0)

        let window = try await SliceCapture.findWindow(for: browser)
        let original = try await PageProbe.read(browser)
        fpLog("probe: \(original.summary)")

        // Async cleanup stands in for `defer`, which cannot await. It runs on success and on error.
        do {
            let image = try await capture(browser: browser, window: window, original: original, progress: progress)
            await PagePrep.finish(browser, restoreScrollY: original.scrollY)
            return image
        } catch {
            await PagePrep.finish(browser, restoreScrollY: original.scrollY)
            throw error
        }
    }

    private static func capture(browser: Browser, window: SCWindow, original: PageProbe,
                                progress: ((Int, Int) -> Void)?) async throws -> CGImage {
        let prepared = try await PagePrep.prepare(browser, probe: original)
        fpLog("probe after prep: \(prepared.summary)")

        let dpr = CGFloat(prepared.devicePixelRatio)
        let totalHeight = Int((prepared.scrollHeight * prepared.devicePixelRatio).rounded())

        // Slices are held only until the stitch is done, so the page is never in memory twice.
        var slices: [CapturedSlice]? = try await SliceCapture.captureAll(browser: browser, probe: prepared,
                                                                         window: window, progress: progress)
        let count = slices?.count ?? 0
        let image = try Stitcher.stitch(slices ?? [], totalHeight: totalHeight, dpr: dpr)
        slices = nil
        fpLog("stitched \(image.width)x\(image.height) px from \(count) slices")
        return image
    }
}
