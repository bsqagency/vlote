import AppKit
import ApplicationServices

/// Thin, non-throwing wrappers over the C Accessibility API.
///
/// Every call here can fail for perfectly ordinary reasons (the app quit mid-scan,
/// the window closed, the app is a hostile Electron build), so the whole surface
/// returns optionals rather than errors. Callers skip what they can't read.
enum AX {

    // MARK: - Private SPI

    private typealias GetWindowFn =
        @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    /// `_AXUIElementGetWindow` maps an AXUIElement to the CGWindowID that the
    /// window server knows it by. It is unexported SPI, so we resolve it at
    /// runtime instead of linking it. Without this there is no reliable way to
    /// tell "this window is on the current Space" from "this window exists
    /// somewhere" — AX happily reports windows on other Spaces with stale frames.
    private static let getWindowFn: GetWindowFn? = {
        guard let handle = dlopen(nil, RTLD_NOW),
              let sym = dlsym(handle, "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(sym, to: GetWindowFn.self)
    }()

    static func windowID(_ element: AXUIElement) -> CGWindowID? {
        guard let fn = getWindowFn else { return nil }
        var id: CGWindowID = 0
        return fn(element, &id) == .success ? id : nil
    }

    // MARK: - Attribute reads

    static func raw(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        raw(element, attribute) as? String
    }

    static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        raw(element, attribute) as? Bool
    }

    static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        raw(element, attribute) as? [AXUIElement] ?? []
    }

    static func point(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        guard let value = raw(element, attribute) else { return nil }
        var out = CGPoint.zero
        // The runtime type is AXValue; CFGetTypeID guards against a surprise.
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        guard AXValueGetValue(value as! AXValue, .cgPoint, &out) else { return nil }
        return out
    }

    static func size(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        guard let value = raw(element, attribute) else { return nil }
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var out = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &out) else { return nil }
        return out
    }

    // MARK: - Attribute writes

    @discardableResult
    static func setPoint(_ element: AXUIElement, _ attribute: String, _ p: CGPoint) -> Bool {
        var v = p
        guard let value = AXValueCreate(.cgPoint, &v) else { return false }
        return AXUIElementSetAttributeValue(element, attribute as CFString, value) == .success
    }

    @discardableResult
    static func setSize(_ element: AXUIElement, _ attribute: String, _ s: CGSize) -> Bool {
        var v = s
        guard let value = AXValueCreate(.cgSize, &v) else { return false }
        return AXUIElementSetAttributeValue(element, attribute as CFString, value) == .success
    }

    // MARK: - Trust

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system "grant Accessibility access" prompt. Returns the trust
    /// state as of right now — the user answering the dialog happens later, so a
    /// `false` here is normal, not an error.
    @discardableResult
    static func requestTrust() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
}
