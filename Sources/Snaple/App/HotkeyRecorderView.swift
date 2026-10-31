import AppKit
import SwiftUI

/// One row of the Shortcuts tab: click the pill, press the new combination.
/// Esc cancels, ⌫ restores the default. Global hotkeys are suspended while recording so pressing the
/// current shortcut doesn't fire a capture.
struct HotkeyRow: View {
    let action: HotkeyAction
    @State private var recording = false
    @State private var shown: Hotkey
    @State private var message: String?
    @State private var monitor: Any?

    init(action: HotkeyAction) {
        self.action = action
        _shown = State(initialValue: action.hotkey)
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            LabeledContent(action.title) {
                HStack(spacing: 8) {
                    if action.isCustomized && !recording {
                        Button("Reset") { action.setHotkey(nil); shown = action.hotkey; message = nil }
                            .buttonStyle(.link).font(.footnote)
                    }
                    Button(recording ? "Type shortcut…" : shown.displayString) { recording ? stop() : start() }
                        .buttonStyle(.bordered)
                        .tint(recording ? .accentColor : nil)
                        .frame(minWidth: 110)
                        .accessibilityLabel("\(action.title) shortcut, \(shown.displayString)")
                        .accessibilityHint("Activate, then press the new key combination")
                }
            }
            if let message {
                Text(message).font(.footnote).foregroundStyle(.orange)
            }
        }
        .onDisappear { if recording { stop() } }
    }

    private func start() {
        message = nil
        recording = true
        HotkeyCenter.shared.unregisterAll()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch event.keyCode {
            case 53: stop(); return nil                                                  // esc
            case 51, 117: action.setHotkey(nil); shown = action.hotkey; stop(); return nil   // delete → default
            default: break
            }
            guard let candidate = Hotkey.from(event: event) else {
                message = "Include ⌘, ⌃ or ⌥ so normal typing isn't captured."
                return nil
            }
            switch action.validate(candidate) {
            case .ok:
                action.setHotkey(candidate)
                shown = action.hotkey
                stop(); return nil
            case .reserved(let name): message = "\(candidate.displayString) is used by \(name)."
            case .duplicate(let other): message = "Already used by “\(other.title)”."
            case .unavailable: message = "\(candidate.displayString) is taken by another app."
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        shown = action.hotkey
        NotificationCenter.default.post(name: .hotkeysChanged, object: nil)   // re-registers everything
    }
}
