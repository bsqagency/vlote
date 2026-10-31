import AppKit
import Combine

extension Notification.Name {
    /// Posted by the panel to open Snaple's Settings window.
    static let openSnapleSettings = Notification.Name("vlote.openSnapleSettings")
    /// Posted by the panel's Capture tab; userInfo["action"] is a HotkeyAction raw value.
    static let snapleAction = Notification.Name("vlote.snapleAction")
    /// Posted by the panel's Capture tab to open Snaple's Library.
    static let openSnapleLibrary = Notification.Name("vlote.openSnapleLibrary")
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let menuBar = MenuBarController()
    private let snaple = AppController()
    private var trustTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBar.install()

        // Snaple's capture actions share Macnizer's one status item: right-click opens its menu,
        // and the countdown shows on the same icon.
        snaple.start()
        snaple.setStatusTitle = { [weak self] title in self?.menuBar.setTitle(title) }
        menuBar.secondaryMenu = { [weak self] in self?.snaple.makeMenu() ?? NSMenu() }
        NotificationCenter.default.addObserver(forName: .hotkeysChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.registerSnapleHotkeys() }
        }

        NotificationCenter.default.addObserver(forName: .openSnapleSettings, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.snaple.showSettings() }
        }

        NotificationCenter.default.addObserver(forName: .snapleAction, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?["action"] as? String
            MainActor.assumeIsolated {
                guard let raw, let action = HotkeyAction(rawValue: raw) else { return }
                // Let the popover dismiss before the screen is frozen, as Snaple's menu does.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    MainActor.assumeIsolated { self?.snaple.perform(action) }
                }
            }
        }

        NotificationCenter.default.addObserver(forName: .openSnapleLibrary, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { LibraryWindowController.shared.show() }
        }

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

    /// Snaple's Settings window closing must not quit the app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// `snaple://capture/...` URLs go to Snaple.
    func application(_ application: NSApplication, open urls: [URL]) {
        snaple.application(application, open: urls)
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

        registerSnapleHotkeys()
    }

    /// Snaple's shortcuts (⌃⌘…) use Snaple's HotkeyCenter, separate from Macnizer's Carbon registrations.
    /// Re-registered whenever Snaple's shortcuts change.
    private func registerSnapleHotkeys() {
        HotkeyCenter.shared.unregisterAll()
        var failed: [String] = []
        for action in HotkeyAction.allCases {
            let ok = HotkeyCenter.shared.register(action.hotkey) { [weak self] in self?.snaple.perform(action) }
            if !ok { failed.append("\(action.title) (\(action.hotkey.displayString))") }
        }
        // Full Page (⌃⌘F). Registered here because unregisterAll() above would drop it on every change.
        // Skipped if a Snaple action already holds the same key; HotkeyAction.validate refuses that key too.
        let fullPage = FullPageController.hotkey
        if HotkeyAction.allCases.contains(where: { $0.hotkey == fullPage }) {
            failed.append("Full Page (\(fullPage.displayString))")
        } else if !HotkeyCenter.shared.register(fullPage, handler: { FullPageController.shared.start() }) {
            failed.append("Full Page (\(fullPage.displayString))")
        }
        if !failed.isEmpty { NSLog("vlote: could not register shortcuts already in use: \(failed.joined(separator: ", "))") }
    }
}
