import AppKit

// Accessory policy: menu bar only, no Dock icon, no app menu.
let app = NSApplication.shared
// Top-level code runs on the main thread, so the @MainActor delegate can be created here.
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
