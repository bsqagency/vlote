import AppKit
import Carbon.HIToolbox

struct Hotkey: Codable, Equatable {
    var keyCode: UInt32
    /// Carbon modifier mask (cmdKey | shiftKey | optionKey | controlKey).
    var modifiers: UInt32

    static func ctrlCmd(_ keyCode: Int) -> Hotkey { Hotkey(keyCode: UInt32(keyCode), modifiers: UInt32(cmdKey | controlKey)) }

    private static let names: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E", kVK_ANSI_F: "F",
        kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
        kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R",
        kVK_ANSI_S: "S", kVK_ANSI_T: "T", kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
        kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "⎋", kVK_Delete: "⌫",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
        kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".",
        kVK_ANSI_Slash: "/", kVK_ANSI_Backslash: "\\", kVK_ANSI_Grave: "`",
    ]

    private static let functionKeys: Set<Int> = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8,
                                                 kVK_F9, kVK_F10, kVK_F11, kVK_F12]

    /// Shortcuts macOS or nearly every app already owns. Refused so users can't lock themselves out of ⌘Q etc.
    private static let reserved: [(Hotkey, String)] = [
        (Hotkey(keyCode: UInt32(kVK_ANSI_Q), modifiers: UInt32(cmdKey)), "Quit"),
        (Hotkey(keyCode: UInt32(kVK_ANSI_W), modifiers: UInt32(cmdKey)), "Close Window"),
        (Hotkey(keyCode: UInt32(kVK_ANSI_H), modifiers: UInt32(cmdKey)), "Hide"),
        (Hotkey(keyCode: UInt32(kVK_ANSI_M), modifiers: UInt32(cmdKey)), "Minimize"),
        (Hotkey(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey)), "Spotlight"),
        (Hotkey(keyCode: UInt32(kVK_Tab), modifiers: UInt32(cmdKey)), "App Switcher"),
        (Hotkey(keyCode: UInt32(kVK_ANSI_Q), modifiers: UInt32(cmdKey | controlKey)), "Lock Screen"),
        (Hotkey(keyCode: UInt32(kVK_ANSI_3), modifiers: UInt32(cmdKey | shiftKey)), "macOS Screenshot"),
        (Hotkey(keyCode: UInt32(kVK_ANSI_4), modifiers: UInt32(cmdKey | shiftKey)), "macOS Screenshot"),
        (Hotkey(keyCode: UInt32(kVK_ANSI_5), modifiers: UInt32(cmdKey | shiftKey)), "macOS Screenshot"),
    ]

    static func reservedName(for hk: Hotkey) -> String? { reserved.first { $0.0 == hk }?.1 }

    /// Builds a hotkey from a key event. Needs ⌘, ⌃ or ⌥ (or a function key) so ordinary typing is never captured.
    static func from(event: NSEvent) -> Hotkey? {
        let f = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods: UInt32 = 0
        if f.contains(.command) { mods |= UInt32(cmdKey) }
        if f.contains(.control) { mods |= UInt32(controlKey) }
        if f.contains(.option) { mods |= UInt32(optionKey) }
        if f.contains(.shift) { mods |= UInt32(shiftKey) }
        let hasPrimary = mods & UInt32(cmdKey | controlKey | optionKey) != 0
        guard hasPrimary || functionKeys.contains(Int(event.keyCode)) else { return nil }
        return Hotkey(keyCode: UInt32(event.keyCode), modifiers: mods)
    }

    var keyName: String { Self.names[Int(keyCode)] ?? "Key \(keyCode)" }

    /// Single character used to show the shortcut in menus.
    var keyEquivalent: String { keyName.count == 1 ? keyName.lowercased() : "" }

    var modifierFlags: NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if modifiers & UInt32(cmdKey) != 0 { f.insert(.command) }
        if modifiers & UInt32(shiftKey) != 0 { f.insert(.shift) }
        if modifiers & UInt32(optionKey) != 0 { f.insert(.option) }
        if modifiers & UInt32(controlKey) != 0 { f.insert(.control) }
        return f
    }

    var displayString: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + keyName
    }
}

enum HotkeyAction: String, CaseIterable, Identifiable {
    case area, window, fullscreen, repeatLast, ocr, qr
    var id: String { rawValue }

    var title: String {
        switch self {
        case .area: return "Capture Area"
        case .window: return "Capture Window"
        case .fullscreen: return "Capture Fullscreen"
        case .repeatLast: return "Repeat Last Capture"
        case .ocr: return "Grab Text (OCR)"
        case .qr: return "Scan QR / Barcode"
        }
    }

    /// Defaults avoid the system's ⌘⇧3/4/5 so they never collide with macOS screenshots.
    var defaultHotkey: Hotkey {
        switch self {
        case .area: return .ctrlCmd(kVK_ANSI_4)
        case .window: return .ctrlCmd(kVK_ANSI_5)
        case .fullscreen: return .ctrlCmd(kVK_ANSI_3)
        case .repeatLast: return .ctrlCmd(kVK_ANSI_R)
        case .ocr: return .ctrlCmd(kVK_ANSI_T)
        case .qr: return .ctrlCmd(kVK_ANSI_B)
        }
    }

    private var defaultsKey: String { "hotkey." + rawValue }

    var hotkey: Hotkey {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let hk = try? JSONDecoder().decode(Hotkey.self, from: data) { return hk }
        return defaultHotkey
    }

    var isCustomized: Bool { UserDefaults.standard.data(forKey: defaultsKey) != nil }

    /// Stores a new shortcut (nil restores the default) and tells the app to re-register everything.
    func setHotkey(_ hotkey: Hotkey?) {
        if let hotkey, hotkey != defaultHotkey, let data = try? JSONEncoder().encode(hotkey) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        }
        NotificationCenter.default.post(name: .hotkeysChanged, object: nil)
    }

    static func resetAll() {
        allCases.forEach { UserDefaults.standard.removeObject(forKey: $0.defaultsKey) }
        NotificationCenter.default.post(name: .hotkeysChanged, object: nil)
    }

    enum Validation: Equatable {
        case ok
        case reserved(String)
        case duplicate(HotkeyAction)
        case unavailable
    }

    /// Checks a candidate for this action. Call with global hotkeys suspended so our own registrations
    /// don't make a free shortcut look taken.
    @MainActor
    func validate(_ candidate: Hotkey) -> Validation {
        if let name = Hotkey.reservedName(for: candidate) { return .reserved(name) }
        if candidate == FullPageController.hotkey { return .reserved("Full Page") }
        if let other = Self.allCases.first(where: { $0 != self && $0.hotkey == candidate }) { return .duplicate(other) }
        return HotkeyCenter.shared.isFree(candidate) ? .ok : .unavailable
    }
}

extension Notification.Name {
    static let hotkeysChanged = Notification.Name("snaple.hotkeysChanged")
}

/// Global hotkeys via Carbon's RegisterEventHotKey: works without Accessibility permission and
/// without a sandbox exemption, and costs nothing while idle.
@MainActor
final class HotkeyCenter {
    static let shared = HotkeyCenter()

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: () -> Void] = [:]
    private var nextID: UInt32 = 1
    private var installed = false

    @discardableResult
    func register(_ hotkey: Hotkey, handler: @escaping () -> Void) -> Bool {
        installIfNeeded()
        var ref: EventHotKeyRef?
        let id = nextID
        nextID += 1
        let status = RegisterEventHotKey(hotkey.keyCode, hotkey.modifiers,
                                         EventHotKeyID(signature: OSType(0x534E4150), id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        refs[id] = ref
        handlers[id] = handler
        return true
    }

    /// True when no other app holds this shortcut. Probes by registering and immediately releasing it.
    func isFree(_ hotkey: Hotkey) -> Bool {
        installIfNeeded()
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(hotkey.keyCode, hotkey.modifiers,
                                         EventHotKeyID(signature: OSType(0x534E4150), id: 0),
                                         GetApplicationEventTarget(), 0, &ref)
        if let ref { UnregisterEventHotKey(ref) }
        return status == noErr
    }

    func unregisterAll() {
        refs.values.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        handlers.removeAll()
    }

    fileprivate func fire(_ id: UInt32) { handlers[id]?() }

    private func installIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let hotKeyID = id.id
            MainActor.assumeIsolated { HotkeyCenter.shared.fire(hotKeyID) }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
