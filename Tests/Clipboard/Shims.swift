import Foundation

// Test-only stand-in for ClipWindowController. The real one is a floating AppKit panel
// that depends on the whole app, so test.sh does not compile it.
// Keep in step with the original's `shared` and `close()`.

final class ClipWindowController {
    static let shared = ClipWindowController()
    func close() {}
}
