import AppKit

/// A browser Macnizer knows how to talk to.
struct Browser: Identifiable, Hashable {
    let id: String          // bundle identifier
    let name: String        // the name AppleScript expects
    let usesNameForTitle: Bool   // Safari says `name of tab`, Chrome says `title of tab`

    static let all: [Browser] = [
        Browser(id: "com.google.Chrome",       name: "Google Chrome",     usesNameForTitle: false),
        Browser(id: "com.brave.Browser",       name: "Brave Browser",     usesNameForTitle: false),
        Browser(id: "com.microsoft.edgemac",   name: "Microsoft Edge",    usesNameForTitle: false),
        Browser(id: "com.vivaldi.Vivaldi",     name: "Vivaldi",           usesNameForTitle: false),
        Browser(id: "company.thebrowser.Browser", name: "Arc",            usesNameForTitle: false),
        Browser(id: "com.apple.Safari",        name: "Safari",            usesNameForTitle: true),
    ]

    /// Only browsers that are already running — enumerating a browser that is
    /// closed would launch it, which is a rude thing for a tidying tool to do.
    static var running: [Browser] {
        let live = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return all.filter { live.contains($0.id) }
    }
}

/// One open tab.
struct TabRef: Identifiable, Hashable {
    let browserID: String
    let browserName: String
    let windowIndex: Int
    let tabIndex: Int
    let url: String
    let title: String

    var id: String { "\(browserID)#\(windowIndex)#\(tabIndex)" }

    var host: String {
        guard let h = URL(string: url)?.host else { return "" }
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    /// URL reduced to what makes two tabs "the same page" for dedupe purposes:
    /// scheme and case normalised, tracking query and fragment dropped.
    var dedupeKey: String {
        guard var comps = URLComponents(string: url) else { return url.lowercased() }
        comps.fragment = nil
        comps.queryItems = comps.queryItems?.filter { item in
            !item.name.lowercased().hasPrefix("utm_") &&
            !["fbclid", "gclid", "ref", "ref_src", "source"].contains(item.name.lowercased())
        }
        if comps.queryItems?.isEmpty == true { comps.queryItems = nil }
        var s = (comps.string ?? url).lowercased()
        if s.hasSuffix("/") { s.removeLast() }
        return s
    }
}

enum BrowserError: LocalizedError {
    case notAuthorized(String)
    case failed(String, String)
    /// "Allow JavaScript from Apple Events" is off in the browser.
    case javaScriptDisabled(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized(let app):
            return "Macnizer needs permission to control \(app). Grant it under System Settings › Privacy & Security › Automation."
        case .failed(let app, let message):
            return "\(app): \(message)"
        case .javaScriptDisabled(let app):
            return "Turn on \"Allow JavaScript from Apple Events\" in \(app) (Safari: Develop menu; Chrome: View › Developer)."
        }
    }
}

/// Reads and closes browser tabs over AppleScript.
///
/// AppleScript round-trips are slow — hundreds of milliseconds with many tabs —
/// so everything runs on a private serial queue. NSAppleScript instances are not
/// thread-safe and are never shared or reused here.
enum BrowserBridge {

    private static let queue = DispatchQueue(label: "com.brandsquare.macnizer.applescript")

    /// TCC denial. The user said no to the Automation prompt (or never saw it).
    private static let errAEEventNotPermitted = -1743

    // Field and record separators: control characters that cannot appear in a
    // URL or a window title, so no escaping is needed.
    private static let fieldSep = "\u{1F}"
    private static let recordSep = "\u{1E}"

    // MARK: - Reading

    static func allTabs(completion: @escaping ([TabRef], [Error]) -> Void) {
        queue.async {
            var tabs: [TabRef] = []
            var errors: [Error] = []

            for browser in Browser.running {
                do {
                    tabs.append(contentsOf: try read(browser))
                } catch {
                    errors.append(error)
                }
            }
            DispatchQueue.main.async { completion(tabs, errors) }
        }
    }

    private static func read(_ browser: Browser) throws -> [TabRef] {
        let titleProperty = browser.usesNameForTitle ? "name" : "title"
        let source = """
        tell application "\(browser.name)"
            set fieldSep to (character id 31)
            set recordSep to (character id 30)
            set out to ""
            set windowCount to count of windows
            repeat with i from 1 to windowCount
                try
                    set tabCount to count of tabs of window i
                    repeat with j from 1 to tabCount
                        try
                            set theTab to tab j of window i
                            set out to out & i & fieldSep & j & fieldSep & ¬
                                (URL of theTab) & fieldSep & (\(titleProperty) of theTab) & recordSep
                        end try
                    end repeat
                end try
            end repeat
            return out
        end tell
        """

        let raw = try run(source, browser: browser)
        return parse(raw, browser: browser)
    }

    private static func parse(_ raw: String, browser: Browser) -> [TabRef] {
        raw.components(separatedBy: recordSep).compactMap { record in
            guard !record.isEmpty else { return nil }
            let fields = record.components(separatedBy: fieldSep)
            guard fields.count == 4,
                  let windowIndex = Int(fields[0].trimmingCharacters(in: .whitespacesAndNewlines)),
                  let tabIndex = Int(fields[1].trimmingCharacters(in: .whitespacesAndNewlines)),
                  !fields[2].isEmpty
            else { return nil }

            return TabRef(browserID: browser.id,
                          browserName: browser.name,
                          windowIndex: windowIndex,
                          tabIndex: tabIndex,
                          url: fields[2],
                          title: fields[3])
        }
    }

    // MARK: - Closing

    /// Closes the given tabs.
    ///
    /// Tab indices shift as soon as one closes, so every browser's tabs are
    /// closed in descending (window, tab) order inside a single script run —
    /// that way an earlier close can never invalidate a later index.
    static func close(_ tabs: [TabRef], completion: @escaping ([Error]) -> Void) {
        queue.async {
            var errors: [Error] = []
            let byBrowser = Dictionary(grouping: tabs, by: \.browserID)

            for (browserID, group) in byBrowser {
                guard let browser = Browser.all.first(where: { $0.id == browserID }) else { continue }

                let ordered = group.sorted {
                    ($0.windowIndex, $0.tabIndex) > ($1.windowIndex, $1.tabIndex)
                }
                let statements = ordered
                    .map { "    try\n        close tab \($0.tabIndex) of window \($0.windowIndex)\n    end try" }
                    .joined(separator: "\n")

                let source = """
                tell application "\(browser.name)"
                \(statements)
                end tell
                """

                do { _ = try run(source, browser: browser) }
                catch { errors.append(error) }
            }
            DispatchQueue.main.async { completion(errors) }
        }
    }

    /// Opens a set of URLs as new tabs in a fresh window.
    static func open(urls: [String], in browser: Browser, completion: @escaping (Error?) -> Void) {
        guard !urls.isEmpty else { completion(nil); return }
        queue.async {
            let escaped = urls.map { $0.replacingOccurrences(of: "\"", with: "\\\"") }
            let makeTabs = escaped.dropFirst()
                .map { "    tell newWindow to make new tab with properties {URL:\"\($0)\"}" }
                .joined(separator: "\n")

            let source = """
            tell application "\(browser.name)"
                activate
                set newWindow to make new window
                set URL of active tab of newWindow to "\(escaped[0])"
            \(makeTabs)
            end tell
            """

            var thrown: Error?
            do { _ = try run(source, browser: browser) } catch { thrown = error }
            DispatchQueue.main.async { completion(thrown) }
        }
    }

    // MARK: - Execution

    private static func run(_ source: String, browser: Browser) throws -> String {
        guard let script = NSAppleScript(source: source) else {
            throw BrowserError.failed(browser.name, "could not compile script")
        }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)

        if let errorInfo {
            let code = errorInfo[NSAppleScript.errorNumber] as? Int ?? 0
            if code == errAEEventNotPermitted {
                throw BrowserError.notAuthorized(browser.name)
            }
            let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "AppleScript error \(code)"
            let lower = message.lowercased()
            if lower.contains("javascript") && (lower.contains("apple events") || lower.contains("turned off")) {
                throw BrowserError.javaScriptDisabled(browser.name)
            }
            throw BrowserError.failed(browser.name, message)
        }
        return result.stringValue ?? ""
    }

    // MARK: - Page JavaScript

    /// Runs JavaScript in the active tab of the browser's front window and returns its string result.
    /// The script must be synchronous and return a string (Apple Events do not await promises).
    static func executeJavaScript(_ js: String, in browser: Browser) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try runJavaScript(js, in: browser)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static func runJavaScript(_ js: String, in browser: Browser) throws -> String {
        // Escape for an AppleScript string literal. Scripts are written on one line.
        let literal = js
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")

        let statement = browser.id == "com.apple.Safari"
            ? "(do JavaScript \"\(literal)\" in current tab of front window)"
            : "(execute active tab of front window javascript \"\(literal)\")"

        let source = """
        tell application "\(browser.name)"
            return \(statement)
        end tell
        """
        return try run(source, browser: browser)
    }
}
