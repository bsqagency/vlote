import AppKit
import CoreGraphics

@MainActor
enum Permissions {
    /// Returns true when capture can proceed. A missing permission opens the single setup window
    /// instead of a separate prompt.
    static func ensureScreenRecording() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        showDeniedAlert()
        return false
    }

    static func showDeniedAlert() {
        OnboardingWindow.show()
    }
}
