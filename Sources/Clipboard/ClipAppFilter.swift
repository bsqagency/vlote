import Foundation

/// Pure filter for the Ignored Apps list. No AppKit, so tests can compile it alone.
enum ClipAppFilter {
    static let helperKeywords = ["Helper", "Service", "Agent", "UIService"]

    /// True when a name (display name or file name) looks like a helper process, e.g. "QuickLookUIService".
    static func isHelperName(_ name: String) -> Bool {
        helperKeywords.contains { name.contains($0) }
    }

    /// True when an .app bundle should appear in the Ignored Apps list.
    static func isListable(displayName: String, fileName: String, uiElement: Bool, backgroundOnly: Bool) -> Bool {
        if uiElement || backgroundOnly { return false }
        return !isHelperName(displayName) && !isHelperName(fileName)
    }
}
