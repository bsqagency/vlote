import AppKit
import SwiftUI

public enum SnapleApp {
    /// Process entry point, called from the thin `Snaple` executable (and from the Xcode app target).
    public static func run() {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let controller = AppController()
            app.delegate = controller
            app.setActivationPolicy(.accessory)
            app.run()
        }
    }
}

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let coordinator = CaptureCoordinator()
    private var settingsWindow: NSWindow?
    private var lastCapture: CapturedImage?
    private var warnedSignedOutAutoUpload = false

    /// Set by the host (vlote's AppDelegate) to show the countdown on its own status item.
    var setStatusTitle: ((String) -> Void)?

    // MARK: Lifecycle

    /// Called by the host app's launch sequence. Does not create a status item or register hotkeys;
    /// the host owns those (see `makeMenu()` and `perform(_:)`).
    func start() {
        Preferences.registerDefaults()
        buildMainMenu()

        coordinator.onCapture = { [weak self] in self?.handle($0) }
        coordinator.onCountdown = { [weak self] remaining in
            self?.setStatusTitle?(remaining.map { " \($0)" } ?? "")
        }
        ThumbnailController.shared.handler = { [weak self] action, item in self?.thumbnailAction(action, item) }

        if Preferences.keepHistory { CaptureStore.shared.prune(olderThanDays: Preferences.historyDays) }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in try? await ScreenCapturer.shared.refresh() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// `snaple://capture/<area|window|fullscreen|repeat|ocr|qr>[?delay=N]`
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "snaple" && url.host == "capture" {
            let delay = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "delay" }?.value.flatMap(Int.init) ?? 0
            switch url.pathComponents.dropFirst().first {
            case "area": coordinator.start(.area, delay: delay)
            case "window": coordinator.start(.window, delay: delay)
            case "fullscreen": coordinator.start(.fullscreen, delay: delay)
            case "repeat": coordinator.start(.repeatLast, delay: delay)
            case "ocr": coordinator.start(.ocr, delay: delay)
            case "qr": coordinator.start(.qr, delay: delay)
            default: break
            }
        }
    }

    // MARK: After capture

    private func handle(_ capture: CapturedImage) {
        lastCapture = capture
        if Preferences.copyToClipboard { Output.copyToPasteboard(capture.image, scale: capture.scale) }
        if Preferences.keepHistory { CaptureStore.shared.persist(capture) }

        let item = ThumbnailItem(capture: capture)
        if Preferences.showThumbnail { ThumbnailController.shared.show(item) }
        if Preferences.autoUpload {
            if CloudSession.shared.isSignedIn {
                Task { await CloudUploader.upload(image: capture.image, scale: capture.scale, id: capture.id, createdAt: capture.createdAt) }
            } else if !warnedSignedOutAutoUpload {
                // Never fail silently: a signed-out auto-upload would otherwise look like it worked.
                warnedSignedOutAutoUpload = true
                Toast.show("Auto-upload is on, but you're signed out. Sign in from Library.", symbol: "icloud.slash")
            }
        }

        // Encoding a 5K frame takes a while; keep it off the main thread so the thumbnail appears instantly.
        let autoSave = Preferences.autoSave, format = Preferences.imageFormat, dir = Preferences.saveDirectoryURL
        DispatchQueue.global(qos: .utility).async {
            var url: URL?
            if autoSave { url = try? Output.write(capture.image, scale: capture.scale, date: capture.createdAt, format: format, directory: dir) }
            if url == nil {
                url = try? Output.write(capture.image, scale: capture.scale, date: capture.createdAt, format: .png, directory: Output.dragCacheDirectory)
            } else {
                DispatchQueue.main.async { item.savedByUser = true }
            }
            DispatchQueue.main.async { item.fileURL = url }
        }
    }

    private func thumbnailAction(_ action: ThumbnailAction, _ item: ThumbnailItem) {
        let c = item.capture
        switch action {
        case .copy:
            Output.copyToPasteboard(c.image, scale: c.scale)
            Toast.show("Copied to clipboard", symbol: "doc.on.doc.fill")
        case .save:
            if let url = item.fileURL, item.savedByUser { NSWorkspace.shared.activateFileViewerSelecting([url]); return }
            do {
                let url = try Output.write(c.image, scale: c.scale, date: c.createdAt, format: Preferences.imageFormat, directory: Preferences.saveDirectoryURL)
                item.fileURL = url; item.savedByUser = true
                Toast.show("Saved to \((url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)", symbol: "checkmark.circle.fill")
            } catch {
                Toast.show("Could not save: \(error.localizedDescription)", symbol: "exclamationmark.triangle.fill")
            }
        case .upload:
            Task { await CloudUploader.upload(image: c.image, scale: c.scale, id: c.id, createdAt: c.createdAt) }
        case .edit: EditorWindowController.present(c, state: CaptureStore.shared.loadState(for: c.id))
        case .pin: PinnedImageController.shared.pin(c)
        case .close: break
        }
    }

    // MARK: Hotkeys

    func perform(_ action: HotkeyAction) {
        switch action {
        case .area: coordinator.start(.area)
        case .window: coordinator.start(.window)
        case .fullscreen: coordinator.start(.fullscreen)
        case .repeatLast: coordinator.start(.repeatLast)
        case .ocr: coordinator.start(.ocr)
        case .qr: coordinator.start(.qr)
        }
    }

    // MARK: Menu bar

    /// Builds Snaple's capture menu. The host shows it from its single status item,
    /// so it is rebuilt on each request and always shows the current key hints.
    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector, hotkey: HotkeyAction? = nil, tag: Int = 0) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: hotkey?.hotkey.keyEquivalent ?? "")
            if let hotkey { item.keyEquivalentModifierMask = hotkey.hotkey.modifierFlags }
            item.target = self; item.tag = tag
            menu.addItem(item)
        }
        add("Capture Area", #selector(menuCapture(_:)), hotkey: .area, tag: 0)
        add("Capture Window", #selector(menuCapture(_:)), hotkey: .window, tag: 1)
        add("Capture Fullscreen", #selector(menuCapture(_:)), hotkey: .fullscreen, tag: 2)
        add("Repeat Last Capture", #selector(menuCapture(_:)), hotkey: .repeatLast, tag: 3)
        menu.addItem(.separator())

        let timed = NSMenu()
        for s in [3, 5, 10] {
            let item = NSMenuItem(title: "Fullscreen in \(s) seconds", action: #selector(menuTimed(_:)), keyEquivalent: "")
            item.target = self; item.tag = s
            timed.addItem(item)
        }
        let timedItem = NSMenuItem(title: "Timed Capture", action: nil, keyEquivalent: "")
        timedItem.submenu = timed
        menu.addItem(timedItem)
        menu.addItem(.separator())

        add("Grab Text (OCR)", #selector(menuCapture(_:)), hotkey: .ocr, tag: 4)
        add("Scan QR / Barcode", #selector(menuCapture(_:)), hotkey: .qr, tag: 5)
        menu.addItem(.separator())
        add("Library…", #selector(showLibrary))
        add("Open Last Capture in Editor", #selector(openLast))
        add("Show Captures Folder", #selector(showFolder))
        menu.addItem(.separator())
        add("Screenshot Settings…", #selector(showSettings))
        menu.addItem(NSMenuItem(title: "Quit Snaple", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    @objc private func menuCapture(_ sender: NSMenuItem) {
        let modes: [CaptureCoordinator.Mode] = [.area, .window, .fullscreen, .repeatLast, .ocr, .qr]
        guard modes.indices.contains(sender.tag) else { return }
        // Let the menu finish dismissing before the screen is frozen, or it ends up in the capture.
        let mode = modes[sender.tag]
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.coordinator.start(mode) }
    }

    @objc private func menuTimed(_ sender: NSMenuItem) { coordinator.start(.fullscreen, delay: sender.tag) }

    @objc private func showLibrary() { LibraryWindowController.shared.show() }

    @objc private func openLast() {
        if let c = lastCapture { EditorWindowController.present(c, state: CaptureStore.shared.loadState(for: c.id)); return }
        if let (c, state) = CaptureStore.shared.latest() { EditorWindowController.present(c, state: state) }
        else { Toast.show("No captures yet", symbol: "photo") }
    }

    @objc private func showFolder() {
        let dir = Preferences.saveDirectoryURL
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    // MARK: Settings window

    @objc func showSettings() {
        if let w = settingsWindow { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Snaple Settings"
        w.contentView = NSHostingView(rootView: SettingsView())
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        settingsWindow = w
        ActivationPolicy.windowOpened()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === settingsWindow else { return }
        settingsWindow = nil
        ActivationPolicy.windowClosed()
    }

    // MARK: Main menu (visible only while a window is open; makes ⌘-shortcuts work)

    private func buildMainMenu() {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let holder = NSMenuItem(); main.addItem(holder)
            let m = NSMenu(title: title); items.forEach(m.addItem); holder.submenu = m
        }
        func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            return i
        }
        let settings = item("Settings…", #selector(showSettings), ","); settings.target = self
        submenu("Snaple", [item("About Snaple", #selector(NSApplication.orderFrontStandardAboutPanel(_:))), .separator(), settings,
                         .separator(), item("Hide Snaple", #selector(NSApplication.hide(_:)), "h"), .separator(),
                         item("Quit Snaple", #selector(NSApplication.terminate(_:)), "q")])
        submenu("File", [item("Save As…", Selector(("saveDocument:")), "s"), item("Close Window", #selector(NSWindow.performClose(_:)), "w")])
        submenu("Edit", [item("Undo", Selector(("undo:")), "z"), item("Redo", Selector(("redo:")), "z", [.command, .shift]), .separator(),
                         item("Cut", #selector(NSText.cut(_:)), "x"), item("Copy", #selector(NSText.copy(_:)), "c"),
                         item("Paste", #selector(NSText.paste(_:)), "v"), item("Delete", #selector(NSText.delete(_:)), "\u{8}", []),
                         item("Select All", #selector(NSText.selectAll(_:)), "a")])
        submenu("Window", [item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")])
        NSApp.mainMenu = main
    }
}
