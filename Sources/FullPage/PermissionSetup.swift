import AppKit
import SwiftUI

/// Result of the JavaScript-from-Apple-Events probe.
enum JSState: Equatable {
    case unknown          // no Chrome or Safari running, nothing to probe
    case enabled
    case disabled         // "Allow JavaScript from Apple Events" is off
    case failed(String)
}

/// The three conditions Full Page needs. Each check is cheap and safe to repeat.
enum PermissionChecks {
    private static let supported = ["com.google.Chrome", "com.apple.Safari"]
    private static let denied = -1743

    static func screenRecordingGranted() -> Bool { CGPreflightScreenCaptureAccess() }

    /// Running Chrome or Safari only: asking a closed app for its name would launch it.
    static func runningBrowsers() -> [Browser] {
        Browser.running.filter { supported.contains($0.id) }
    }

    /// True when at least one running Chrome or Safari accepts an Apple Event from us.
    /// The first call is what makes macOS show the Automation prompt.
    static func automationGranted() async -> Bool {
        for browser in runningBrowsers() {
            if await askName(browser) { return true }
        }
        return false
    }

    private static func askName(_ browser: Browser) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            var info: NSDictionary?
            let script = NSAppleScript(source: "tell application id \"\(browser.id)\" to get name")
            _ = script?.executeAndReturnError(&info)
            return info == nil
        }.value
    }

    /// Runs the page probe in the front Chrome or Safari, or the first one running.
    static func javaScriptState() async -> JSState {
        let running = runningBrowsers()
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard let browser = running.first(where: { $0.id == front }) ?? running.first else { return .unknown }
        do {
            _ = try await PageProbe.read(browser)
            return .enabled
        } catch let error as BrowserError {
            if case .javaScriptDisabled = error { return .disabled }
            return .failed(error.localizedDescription)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    static func openPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Holds the latest check results for the walkthrough sheet.
@MainActor
final class PermissionSetupModel: ObservableObject {
    @Published var screenOK = false
    @Published var automationOK = false
    @Published var javaScript: JSState = .unknown

    var allOK: Bool { screenOK && automationOK && javaScript == .enabled }

    func refresh() async {
        screenOK = PermissionChecks.screenRecordingGranted()
        automationOK = await PermissionChecks.automationGranted()
        javaScript = await PermissionChecks.javaScriptState()
    }
}

/// Entry point used by Full Page: shows the walkthrough when it has not been completed or a step fails.
@MainActor
enum PermissionSetup {
    static func ensureReady(onReady: @escaping () -> Void) {
        Task { @MainActor in
            let model = PermissionSetupModel()
            await model.refresh()
            if Settings.shared.fullPageSetupDone && model.allOK {
                onReady()
                return
            }
            PermissionSetupWindow.show(model: model, onReady: onReady)
        }
    }
}

// MARK: - Window

@MainActor
final class PermissionSetupWindow: NSWindowController, NSWindowDelegate {
    private static var current: PermissionSetupWindow?

    static func show(model: PermissionSetupModel, onReady: @escaping () -> Void) {
        current?.close()
        let controller = PermissionSetupWindow(model: model, onReady: onReady)
        current = controller
        controller.showWindow(nil)
        controller.window?.center()
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Closes the sheet without touching the saved flag (used by Continue and Not Now).
    static func dismiss() {
        current?.close()
        current = nil
    }

    private init(model: PermissionSetupModel, onReady: @escaping () -> Void) {
        let root = PermissionSetupView(
            model: model,
            onContinue: {
                Settings.shared.fullPageSetupDone = true
                PermissionSetupWindow.dismiss()
                onReady()
            },
            onClose: { PermissionSetupWindow.dismiss() }
        )
        let window = NSWindow(contentViewController: NSHostingController(rootView: root))
        window.title = "Set up Full Page"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func windowWillClose(_ notification: Notification) {
        if PermissionSetupWindow.current === self { PermissionSetupWindow.current = nil }
    }
}

// MARK: - View (matches the Macnizer panel: system fonts, secondary text, soft rounded rows)

struct PermissionSetupView: View {
    @ObservedObject var model: PermissionSetupModel
    let onContinue: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Set up Full Page")
                    .font(.system(size: 15, weight: .semibold))
                Text("Three one-time steps. Each turns green when it is done.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            step(1, "Screen Recording", done: model.screenOK,
                 detail: "Lets vlote capture the browser window.") {
                Button("Open Screen Recording…") {
                    _ = CGRequestScreenCaptureAccess()
                    PermissionChecks.openPane("Privacy_ScreenCapture")
                }
            }

            step(2, "Automation for Chrome or Safari", done: model.automationOK,
                 detail: "Lets vlote read the active tab. Keep Chrome or Safari open, then press the button to trigger the prompt.") {
                HStack {
                    Button("Ask Chrome / Safari") { Task { await model.refresh() } }
                    Button("Open Automation…") { PermissionChecks.openPane("Privacy_Automation") }
                }
            }

            step(3, "Allow JavaScript from Apple Events", done: model.javaScript == .enabled,
                 detail: javaScriptDetail) {
                VStack(alignment: .leading, spacing: 8) {
                    if model.javaScript == .disabled {
                        Text("Safari › Settings › Advanced › \"Show features for web developers\", then Develop › \"Allow JavaScript from Apple Events\".")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text("Chrome › View › Developer › \"Allow JavaScript from Apple Events\".")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Button("Check Again") { Task { await model.refresh() } }
                }
            }

            HStack {
                Button("Not Now", action: onClose)
                Spacer()
                Button("Continue", action: onContinue)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.allOK)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 460)
        .task { await model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refresh() }
        }
    }

    private var javaScriptDetail: String {
        switch model.javaScript {
        case .unknown: return "Open Chrome or Safari, then press Check Again."
        case .enabled: return "Allow JavaScript from Apple Events is on."
        case .disabled: return "Turn this on in the browser (menus below)."
        case .failed(let message): return message
        }
    }

    private func step<Actions: View>(_ number: Int, _ title: String, done: Bool, detail: String,
                                     @ViewBuilder actions: () -> Actions) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "\(number).circle")
                .font(.system(size: 18))
                .foregroundStyle(done ? Color.green : Color.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                actions()
                    .controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.07)))
    }
}
