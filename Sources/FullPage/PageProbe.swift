import AppKit

/// A fixed or sticky element's box, in viewport CSS pixels.
struct FixedBox {
    let position: String
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

/// What the page and its browser window look like, read from the active tab.
struct PageProbe {
    let scrollHeight: Double
    let scrollY: Double
    let innerWidth: Double
    let innerHeight: Double
    let devicePixelRatio: Double
    let screenX: Double
    let screenY: Double
    let outerWidth: Double
    let outerHeight: Double
    let fixed: [FixedBox]

    var summary: String {
        "scrollHeight=\(Int(scrollHeight)) inner=\(Int(innerWidth))x\(Int(innerHeight)) "
            + "dpr=\(devicePixelRatio) scrollY=\(Int(scrollY)) "
            + "screen=(\(Int(screenX)),\(Int(screenY))) outer=\(Int(outerWidth))x\(Int(outerHeight)) "
            + "fixed=\(fixed.count)"
    }

    /// Reads the probe from the active tab of the browser. Throws `BrowserError.javaScriptDisabled`
    /// when "Allow JavaScript from Apple Events" is off.
    static func read(_ browser: Browser) async throws -> PageProbe {
        let raw = try await BrowserBridge.executeJavaScript(script, in: browser)
        return try parse(raw)
    }

    static func parse(_ raw: String) throws -> PageProbe {
        guard let data = raw.data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FullPageError.badProbe(String(raw.prefix(120)))
        }
        func num(_ key: String) throws -> Double {
            guard let n = obj[key] as? NSNumber else { throw FullPageError.badProbe("missing \(key)") }
            return n.doubleValue
        }
        let boxes = ((obj["fixed"] as? [[String: Any]]) ?? []).map { d in
            FixedBox(position: d["pos"] as? String ?? "",
                     x: (d["x"] as? NSNumber)?.doubleValue ?? 0,
                     y: (d["y"] as? NSNumber)?.doubleValue ?? 0,
                     width: (d["w"] as? NSNumber)?.doubleValue ?? 0,
                     height: (d["h"] as? NSNumber)?.doubleValue ?? 0)
        }
        return PageProbe(
            scrollHeight: try num("scrollHeight"),
            scrollY: try num("scrollY"),
            innerWidth: try num("innerWidth"),
            innerHeight: try num("innerHeight"),
            devicePixelRatio: try num("devicePixelRatio"),
            screenX: try num("screenX"),
            screenY: try num("screenY"),
            outerWidth: try num("outerWidth"),
            outerHeight: try num("outerHeight"),
            fixed: boxes
        )
    }

    /// One line, no comments: it is pasted into an AppleScript string literal.
    static let script = """
    (function () { var fixed = []; var all = document.querySelectorAll('*'); for (var i = 0; i < all.length && fixed.length < 200; i++) { var el = all[i]; var pos = getComputedStyle(el).position; if (pos === 'fixed' || pos === 'sticky') { var r = el.getBoundingClientRect(); if (r.width > 0 && r.height > 0) { fixed.push({ pos: pos, x: r.left, y: r.top, w: r.width, h: r.height }); } } } var body = document.body; var sh = Math.max(document.documentElement.scrollHeight, body ? body.scrollHeight : 0); return JSON.stringify({ scrollHeight: sh, scrollY: window.scrollY, innerWidth: window.innerWidth, innerHeight: window.innerHeight, devicePixelRatio: window.devicePixelRatio, screenX: window.screenX, screenY: window.screenY, outerWidth: window.outerWidth, outerHeight: window.outerHeight, fixed: fixed }); })()
    """
}
