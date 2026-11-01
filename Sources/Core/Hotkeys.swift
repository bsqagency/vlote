import AppKit
import Carbon.HIToolbox

/// System-wide hotkeys via the Carbon hot key API.
///
/// This is still the only way to get a true global hotkey that works when the
/// app is not frontmost without asking for Input Monitoring permission — an
/// NSEvent global monitor would need it, and for a menu bar utility that is a
/// much bigger ask than it is worth.
final class HotkeyManager {
    static let shared = HotkeyManager()

    struct Shortcut {
        let keyCode: UInt32
        let modifiers: UInt32
        let label: String
    }

    // ⌥⌘ is a safe base: rarely claimed by apps, impossible to hit by accident.
    private static let optCmd = UInt32(optionKey | cmdKey)

    static let toggleAuto  = Shortcut(keyCode: UInt32(kVK_ANSI_T), modifiers: optCmd, label: "⌥⌘T")
    static let cycleLayout = Shortcut(keyCode: UInt32(kVK_Space),  modifiers: optCmd, label: "⌥⌘Space")
    static let retileNow   = Shortcut(keyCode: UInt32(kVK_ANSI_R), modifiers: optCmd, label: "⌥⌘R")
    static let openPanel   = Shortcut(keyCode: UInt32(kVK_ANSI_O), modifiers: optCmd, label: "⌥⌘O")
    static let clipboard   = Shortcut(keyCode: UInt32(kVK_ANSI_V), modifiers: optCmd, label: "⌥⌘V")
    static let columns     = Shortcut(keyCode: UInt32(kVK_ANSI_Grave), modifiers: 0, label: "`")

    private var actions: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef?] = []
    private var nextID: UInt32 = 1
    private var handlerInstalled = false

    private init() {}

    func register(_ shortcut: Shortcut, action: @escaping () -> Void) {
        installHandlerIfNeeded()

        let id = nextID
        nextID += 1

        let hotKeyID = EventHotKeyID(signature: OSType(0x4D434E5A), id: id)  // 'MCNZ'
        var ref: EventHotKeyRef?

        let status = RegisterEventHotKey(shortcut.keyCode,
                                         shortcut.modifiers,
                                         hotKeyID,
                                         GetApplicationEventTarget(),
                                         0,
                                         &ref)
        guard status == noErr else {
            NSLog("Macnizer: could not register hotkey \(shortcut.label) (status \(status))")
            return
        }
        actions[id] = action
        refs.append(ref)
    }

    fileprivate func fire(id: UInt32) {
        actions[id]?()
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))

        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            guard let event else { return OSStatus(eventNotHandledErr) }

            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event,
                                           EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID),
                                           nil,
                                           MemoryLayout<EventHotKeyID>.size,
                                           nil,
                                           &hotKeyID)
            guard status == noErr else { return status }

            DispatchQueue.main.async {
                HotkeyManager.shared.fire(id: hotKeyID.id)
            }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
