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
        menuBar.install(menu: buildStatusMenu())

        // Snaple's capture actions share Macnizer's one status item; the countdown shows on the same icon.
        snaple.start()
        snaple.setStatusTitle = { [weak self] title in self?.menuBar.setTitle(title) }
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
            .sink { [weak self] on in
                self?.menuBar.updateIcon()
                self?.arrangingItem?.state = on ? .on : .off
            }
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

        hk.register(HotkeyManager.toggleAuto) { [weak self] in self?.toggleArranging() }
        hk.register(HotkeyManager.cycleLayout) { [weak self] in self?.nextLayout() }
        hk.register(HotkeyManager.columns) { [weak self] in self?.columnsLayout() }
        hk.register(HotkeyManager.retileNow) { [weak self] in self?.arrangeNow() }
        hk.register(HotkeyManager.openPanel) { [weak self] in
            self?.menuBar.showPopover()
        }
        _ = ClipStore.shared  // start recording clipboard history at launch
        hk.register(HotkeyManager.clipboard) { [weak self] in self?.toggleClipboard() }

        registerSnapleHotkeys()
    }

    // MARK: - Actions (shared by hotkeys and the status menu)

    private func toggleArranging() {
        Settings.shared.autoTile.toggle()
        if Settings.shared.autoTile { Tiler.shared.retile() }
    }

    private func nextLayout() { Tiler.shared.cycleLayout() }

    private func columnsLayout() {
        Settings.shared.layout = .columns
        Tiler.shared.applyPreset()
    }

    private func arrangeNow() { Tiler.shared.retile() }

    private func toggleClipboard() { ClipWindowController.shared.toggle() }

    // MARK: - Status menu

    private weak var arrangingItem: NSMenuItem?

    /// The one menu behind the status item. Each item calls the same action as its hotkey or panel control.
    private func buildStatusMenu() -> NSMenu {
        let menu = NSMenu()
        @discardableResult
        func add(_ into: NSMenu, _ title: String, _ shortcut: String = "", _ action: Selector, key: String = "") -> NSMenuItem {
            let item = NSMenuItem(title: shortcut.isEmpty ? title : "\(title)    \(shortcut)",
                                  action: action, keyEquivalent: key)
            item.target = self
            into.addItem(item)
            return item
        }
        func capture(_ into: NSMenu, _ title: String, _ action: HotkeyAction, _ shortcut: String? = nil) {
            let item = add(into, title, shortcut ?? action.hotkey.displayString, #selector(runCapture(_:)))
            item.representedObject = action
        }
        func submenu(_ title: String) -> NSMenu {
            NSMenu(title: title)
        }
        func attach(_ title: String, _ sub: NSMenu) {
            let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            parent.submenu = sub
            menu.addItem(parent)
        }

        // Open Vlote: opens the panel
        add(menu, "Open Vlote", "", #selector(menuOpenPanel))
        menu.addItem(.separator())

        // Tabs ▸ window tiling
        let tabs = submenu("Tabs")
        arrangingItem = add(tabs, "Toggle Arranging", HotkeyManager.toggleAuto.label, #selector(menuToggleArranging))
        arrangingItem?.state = Settings.shared.autoTile ? .on : .off
        add(tabs, "Arrange Now", HotkeyManager.retileNow.label, #selector(menuArrangeNow))
        add(tabs, "Next Layout", HotkeyManager.cycleLayout.label, #selector(menuNextLayout))
        add(tabs, "Columns", HotkeyManager.columns.label, #selector(menuColumns))
        attach("Tabs", tabs)

        // Snaps ▸ Snaple capture
        let snaps = submenu("Snaps")
        capture(snaps, "Capture Area", .area)
        capture(snaps, "Capture Window", .window)
        capture(snaps, "Capture Fullscreen", .fullscreen)
        capture(snaps, "Repeat Last", .repeatLast)
        capture(snaps, "Grab Text", .ocr)
        capture(snaps, "Scan QR", .qr)
        add(snaps, "Full Page", FullPageController.shortcutLabel, #selector(menuFullPage))
        add(snaps, "Library…", "", #selector(menuLibrary))
        attach("Snaps", snaps)

        // Clips ▸ clipboard history
        let clips = submenu("Clips")
        add(clips, "Clipboard History", HotkeyManager.clipboard.label, #selector(menuClipboard))
        add(clips, "Delete All History", "", #selector(menuDeleteAllHistory))
        add(clips, "Clipboard Preferences…", "", #selector(menuClipPreferences))
        attach("Clips", clips)

        menu.addItem(.separator())

        let about = add(menu, "About Vlote", "", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        about.target = NSApp
        let quit = add(menu, "Quit Vlote", "", #selector(NSApplication.terminate(_:)), key: "q")
        quit.target = NSApp
        return menu
    }

    /// Menu items close the menu on click. Work starts after it has gone, so a capture
    /// does not freeze the menu into the screenshot, and a window does not fight the menu for focus.
    private func afterMenuCloses(_ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            MainActor.assumeIsolated { work() }
        }
    }

    @objc private func menuToggleArranging() { afterMenuCloses { self.toggleArranging() } }
    @objc private func menuArrangeNow() { afterMenuCloses { self.arrangeNow() } }
    @objc private func menuNextLayout() { afterMenuCloses { self.nextLayout() } }
    @objc private func menuColumns() { afterMenuCloses { self.columnsLayout() } }

    @objc private func runCapture(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? HotkeyAction else { return }
        afterMenuCloses { self.snaple.perform(action) }
    }

    @objc private func menuFullPage() { afterMenuCloses { FullPageController.shared.start() } }
    @objc private func menuLibrary() { afterMenuCloses { LibraryWindowController.shared.show() } }
    @objc private func menuClipboard() { afterMenuCloses { self.toggleClipboard() } }
    @objc private func menuDeleteAllHistory() { afterMenuCloses { ClipStore.shared.confirmDeleteAll() } }
    @objc private func menuClipPreferences() { afterMenuCloses { PreferencesWindow.shared.show(page: .copyClips) } }
    @objc private func menuOpenPanel() { afterMenuCloses { self.menuBar.showPopover() } }

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
