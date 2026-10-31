import Foundation

/// Step 2: lazy-load pass, image wait, and hiding fixed/sticky elements, plus the cleanup.
enum PagePrep {

    static let styleID = "vlote-fp"
    private static let imageTimeout: TimeInterval = 5

    /// Scrolls top to bottom so lazy content loads, waits for images, returns to the top,
    /// and injects the hide style. Returns a fresh probe taken after prep.
    static func prepare(_ browser: Browser, probe: PageProbe) async throws -> PageProbe {
        let step = max(1, probe.innerHeight * 0.8)
        var y = 0.0
        var height = probe.scrollHeight
        var rounds = 0
        while rounds < 500 {
            rounds += 1
            let (_, h) = try await scroll(browser, to: y)
            height = h
            try await Task.sleep(nanoseconds: 150_000_000)
            if y + probe.innerHeight >= height { break }
            y += step
        }
        fpLog("lazy scroll: \(rounds) steps, height \(Int(height))")

        try await waitForImages(browser)

        _ = try await scroll(browser, to: 0)
        try await Task.sleep(nanoseconds: 300_000_000)

        let tagged = try await BrowserBridge.executeJavaScript(injectScript, in: browser)
        fpLog("hid \(tagged) fixed/sticky elements")

        return try await PageProbe.read(browser)
    }

    /// Scrolls to `y` (instant) and returns the actual scrollY and the page's scrollHeight.
    static func scroll(_ browser: Browser, to y: Double) async throws -> (scrollY: Double, height: Double) {
        let js = """
        (function () { window.scrollTo({ top: \(Int(y.rounded())), left: 0, behavior: 'instant' }); var body = document.body; var h = Math.max(document.documentElement.scrollHeight, body ? body.scrollHeight : 0); return window.scrollY + '|' + h; })()
        """
        let raw = try await BrowserBridge.executeJavaScript(js, in: browser)
        let parts = raw.split(separator: "|")
        guard parts.count == 2, let sy = Double(parts[0]), let h = Double(parts[1]) else {
            throw FullPageError.badProbe("scroll result \(raw)")
        }
        return (sy, h)
    }

    /// Shows (true) or hides (false) the fixed/sticky elements. The style is enabled by default;
    /// disabling it reveals them, which is only done for the first slice.
    static func setOverlaysShown(_ browser: Browser, _ shown: Bool) async throws {
        let js = """
        (function () { var s = document.getElementById('\(styleID)'); if (s) { s.disabled = \(shown ? "true" : "false"); } return s ? 'ok' : 'missing'; })()
        """
        _ = try await BrowserBridge.executeJavaScript(js, in: browser)
    }

    /// Restores the scroll position and removes the style and tags. Never throws: each step is
    /// attempted even if an earlier one failed, and failures are logged.
    static func finish(_ browser: Browser, restoreScrollY: Double) async {
        do {
            _ = try await scroll(browser, to: restoreScrollY)
        } catch {
            fpLog("restore scroll failed: \(error.localizedDescription)")
        }
        do {
            _ = try await BrowserBridge.executeJavaScript(cleanupScript, in: browser)
        } catch {
            fpLog("cleanup failed: \(error.localizedDescription)")
        }
        fpLog("restored scrollY \(Int(restoreScrollY)), removed style")
    }

    // MARK: - Private

    /// Polls until every image has finished loading, or the timeout passes.
    private static func waitForImages(_ browser: Browser) async throws {
        let deadline = Date().addingTimeInterval(imageTimeout)
        var last = "?"
        repeat {
            last = try await BrowserBridge.executeJavaScript(imagesScript, in: browser)
            let pending = last.split(separator: "/").first.flatMap { Int($0) } ?? -1
            if pending == 0 { break }
            try await Task.sleep(nanoseconds: 250_000_000)
        } while Date() < deadline
        fpLog("images pending/total: \(last)")
    }

    private static let imagesScript = """
    (function () { var im = document.images; var n = 0; for (var i = 0; i < im.length; i++) { if (!im[i].complete) { n++; } } return n + '/' + im.length; })()
    """

    /// Adds the hide style once, and tags each fixed/sticky element for it.
    private static let injectScript = """
    (function () { var s = document.getElementById('\(styleID)'); if (!s) { s = document.createElement('style'); s.id = '\(styleID)'; s.textContent = '[data-vlote-fp]{visibility:hidden !important}'; (document.head || document.documentElement).appendChild(s); } s.disabled = false; var all = document.querySelectorAll('*'); var n = 0; for (var i = 0; i < all.length; i++) { var p = getComputedStyle(all[i]).position; if (p === 'fixed' || p === 'sticky') { all[i].setAttribute('data-vlote-fp', ''); n++; } } return String(n); })()
    """

    private static let cleanupScript = """
    (function () { var s = document.getElementById('\(styleID)'); if (s) { s.remove(); } var all = document.querySelectorAll('[data-vlote-fp]'); for (var i = 0; i < all.length; i++) { all[i].removeAttribute('data-vlote-fp'); } return 'ok'; })()
    """
}
