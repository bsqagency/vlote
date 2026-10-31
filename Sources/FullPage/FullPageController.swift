import AppKit
import Carbon.HIToolbox

/// Starts a full-page capture from the ⌃⌘F hotkey or the Capture tab button.
/// Order: front-app check, first-run and permission check, capture with HUD, preview or error alert.
@MainActor
final class FullPageController {
    static let shared = FullPageController()

    /// ⌃⌘F. Uses Snaple's Hotkey type and HotkeyCenter, registered in AppDelegate.
    static let hotkey = Hotkey.ctrlCmd(kVK_ANSI_F)
    static var shortcutLabel: String { hotkey.displayString }

    /// Full Page works in these two only (the AppleScript path is tested on them).
    private static let supported = ["com.google.Chrome", "com.apple.Safari"]

    private let hud = CaptureHUD()
    private var busy = false
    /// Last Chrome or Safari that was frontmost. Lets the panel button work, since clicking it makes vlote active.
    private var lastBrowserID: String?

    private init() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated {
                if let id, FullPageController.supported.contains(id) { self?.lastBrowserID = id }
            }
        }
    }

    /// `fromPanel` is true for the Capture tab button; the hotkey path uses the real front app only.
    func start(fromPanel: Bool = false) {
        guard !busy else { return }

        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let candidate = front.flatMap { id in Self.supported.contains(id) ? id : nil }
            ?? (fromPanel ? lastBrowserID : nil)
        guard let id = candidate, let browser = Browser.all.first(where: { $0.id == id }) else {
            showAlert(title: FullPageError.notABrowser.localizedDescription)
            return
        }

        PermissionSetup.ensureReady { [weak self] in
            self?.capture(browser)
        }
    }

    private func capture(_ browser: Browser) {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            await bringToFront(browser)

            hud.show("Preparing page…")
            do {
                let image = try await FullPageCapture.run(browser: browser) { done, total in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            FullPageController.shared.hud.show(total == 0
                                ? "Preparing page…"
                                : "Capturing \(done) of \(total)…")
                        }
                    }
                }
                hud.hide()
                FullPageWindow.show(image: image, title: "Full Page")
            } catch FullPageError.cancelled {
                hud.hide()
                showAlert(title: "Capture cancelled")
            } catch {
                hud.hide()
                showAlert(title: "Full Page capture failed", detail: error.localizedDescription)
            }
        }
    }

    /// Brings the browser forward, and waits briefly for it to become frontmost.
    private func bringToFront(_ browser: Browser) async {
        let current = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard current != browser.id,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: browser.id).first else { return }
        app.activate()
        for _ in 0..<15 {
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == browser.id { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    private func showAlert(title: String, detail: String? = nil) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        if let detail { alert.informativeText = detail }
        alert.alertStyle = .informational
        alert.runModal()
    }
}

/// Small non-activating progress panel, centred on the main screen. Never takes focus,
/// so the browser stays frontmost during capture.
@MainActor
final class CaptureHUD {
    private var panel: NSPanel?
    private let label = NSTextField(labelWithString: "")

    func show(_ text: String) {
        if panel == nil { build() }
        label.stringValue = text
        guard let panel else { return }
        if let frame = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2,
                                         y: frame.midY - panel.frame.height / 2))
        }
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func build() {
        let size = NSSize(width: 240, height: 56)
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12

        let spinner = NSProgressIndicator(frame: NSRect(x: 16, y: 18, width: 20, height: 20))
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.startAnimation(nil)

        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.frame = NSRect(x: 46, y: 18, width: size.width - 56, height: 20)

        effect.addSubview(spinner)
        effect.addSubview(label)
        p.contentView = effect
        panel = p
    }
}
