import AppKit
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let menuBar = MenuBarController()
    private var trustTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBar.install()
        registerHotkeys()

        // Keep the menu bar icon in step with the pause state however it changed
        // — panel toggle, hotkey, or another window of the app.
        Settings.shared.$autoTile
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.menuBar.updateIcon() }
            .store(in: &cancellables)

        Diagnostics.shared.log("launched; accessibility trusted = \(AX.isTrusted)")

        if AX.isTrusted {
            startEngine()
        } else {
            Diagnostics.shared.log("not trusted — prompting and polling")
            requestAccessibility()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        trustTimer?.invalidate()
        WindowWatcher.shared.stop()
        DragWatcher.shared.stop()
    }

    // MARK: - Permissions

    private func requestAccessibility() {
        let alert = NSAlert()
        alert.messageText = "Macnizer needs Accessibility access"
        alert.informativeText = """
        To move and resize windows, macOS requires Macnizer to be enabled under \
        Privacy & Security › Accessibility.

        Click Open Settings, switch Macnizer on, and it will start arranging \
        straight away — no restart needed.
        """
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")
        alert.alertStyle = .informational

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            AX.requestTrust()
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
        waitForTrust()
    }

    /// There is no notification for "Accessibility was just granted", so poll.
    /// Cheap, and it means the app starts working the moment the user flips the
    /// switch rather than requiring a relaunch.
    private func waitForTrust() {
        trustTimer?.invalidate()
        trustTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            guard AX.isTrusted else { return }
            Diagnostics.shared.log("accessibility granted — starting engine")
            timer.invalidate()
            self?.trustTimer = nil
            self?.startEngine()
        }
    }

    private func startEngine() {
        WindowWatcher.shared.start()
        DragWatcher.shared.start()
        Diagnostics.shared.engineRunning = true
        Diagnostics.shared.log("engine started")
    }

    // MARK: - Hotkeys

    private func registerHotkeys() {
        let hk = HotkeyManager.shared

        hk.register(HotkeyManager.toggleAuto) {
            Settings.shared.autoTile.toggle()
            if Settings.shared.autoTile { Tiler.shared.retile() }
        }
        hk.register(HotkeyManager.cycleLayout) {
            Tiler.shared.cycleLayout()
        }
        hk.register(HotkeyManager.columns) {
            Settings.shared.layout = .columns
            Tiler.shared.applyPreset()
        }
        hk.register(HotkeyManager.retileNow) {
            Tiler.shared.retile()
        }
        hk.register(HotkeyManager.openPanel) { [weak self] in
            self?.menuBar.showPopover()
        }
    }
}
