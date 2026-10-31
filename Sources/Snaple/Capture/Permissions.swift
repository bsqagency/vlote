import AppKit
import CoreGraphics

@MainActor
enum Permissions {
    private static let askedKey = "askedScreenRecording"

    /// Returns true when capture can proceed. The first call shows the system prompt; later calls
    /// explain how to enable it, since macOS will not prompt twice.
    static func ensureScreenRecording() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        if UserDefaults.standard.bool(forKey: askedKey) {
            showDeniedAlert()
        } else {
            UserDefaults.standard.set(true, forKey: askedKey)
            CGRequestScreenCaptureAccess()
        }
        return false
    }

    static func showDeniedAlert() {
        let alert = NSAlert()
        alert.messageText = "Snaple needs Screen Recording access"
        alert.informativeText = "Enable Snaple under System Settings → Privacy & Security → Screen & System Audio Recording, then relaunch Snaple. Captures stay on your Mac."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
