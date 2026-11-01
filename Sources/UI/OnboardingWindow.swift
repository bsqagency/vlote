import AppKit
import SwiftUI

/// Every permission Vlote needs, asked for together from one window.
/// Shown once after first launch, and whenever a feature finds one missing.
enum OnboardingPermissions {
    static let browsers = ["com.google.Chrome", "com.apple.Safari"]

    /// Automation is per browser. Checking without `prompt` never shows a dialog.
    static func automationGranted(prompt: Bool) -> Bool {
        browsers.reduce(false) { granted, id in
            guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil else { return granted }
            let target = NSAppleEventDescriptor(bundleIdentifier: id)
            let ok = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, prompt) == noErr
            return granted || ok
        }
    }
}

@MainActor
final class OnboardingModel: ObservableObject {
    @Published var accessibility = AX.isTrusted
    @Published var inputMonitoring = CGPreflightListenEventAccess()
    @Published var screenRecording = CGPreflightScreenCaptureAccess()
    @Published var automation = false
    @Published var busy = false

    var allGranted: Bool { accessibility && inputMonitoring && screenRecording && automation }

    func refresh() {
        accessibility = AX.isTrusted
        inputMonitoring = CGPreflightListenEventAccess()
        screenRecording = CGPreflightScreenCaptureAccess()
        if inputMonitoring { DoubleTabWatcher.shared.start() }
        Task {
            let ok = await Task.detached { OnboardingPermissions.automationGranted(prompt: false) }.value
            automation = ok
        }
    }

    /// One click asks for everything, in order. macOS shows each system dialog once.
    func allowAll() {
        busy = true
        _ = AX.requestTrust()
        _ = CGRequestListenEventAccess()
        _ = CGRequestScreenCaptureAccess()
        Task {
            let ok = await Task.detached { OnboardingPermissions.automationGranted(prompt: true) }.value
            automation = ok
            busy = false
            refresh()
        }
    }
}

@MainActor
enum OnboardingWindow {
    private static var window: NSWindow?
    private static var timer: Timer?
    private static let model = OnboardingModel()

    static func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 380),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Set Up Vlote"
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: OnboardingView(model: model) { close() })
        w.center()
        window = w

        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        model.refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            Task { @MainActor in model.refresh() }
        }
    }

    static func close() {
        timer?.invalidate()
        timer = nil
        window?.close()
        window = nil
    }
}

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Set up Vlote").font(.system(size: 20, weight: .semibold))
            Text("Vlote needs these four permissions. Click Allow All once and macOS will ask for each one in turn.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                row("Accessibility", "Move and resize windows", model.accessibility)
                Divider()
                row("Input Monitoring", "Double-tap Tab to arrange", model.inputMonitoring)
                Divider()
                row("Screen Recording", "Snaps and Full Page captures", model.screenRecording)
                Divider()
                row("Automation for Chrome or Safari", "Tab titles and URLs for Tabs. Open the browser first.", model.automation)
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))

            Spacer(minLength: 0)

            HStack {
                Spacer()
                if model.allGranted {
                    Button("Done") { done() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Later") { done() }
                    Button("Allow All") { model.allowAll() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.busy)
                }
            }
        }
        .padding(22)
        .frame(width: 460, height: 380)
    }

    private func row(_ title: String, _ detail: String, _ ok: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 16))
                .foregroundStyle(ok ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}
