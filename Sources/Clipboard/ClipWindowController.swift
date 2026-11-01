import AppKit
import SwiftUI
import Carbon.HIToolbox

/// Borderless floating panel. Accepts key focus so it can take keyboard input,
/// and closes itself when it loses focus.
final class ClipPanel: NSPanel {
    /// Return true to consume the key event.
    var onKeyDown: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onKeyDown?(event) == true { return }
        super.sendEvent(event)
    }

    override func resignKey() {
        super.resignKey()
        orderOut(nil)
    }
}

/// Shows the clipboard history panel under the menu bar (⌥⌘V or the status item).
final class ClipWindowController: NSObject {
    static let shared = ClipWindowController()

    private static let size = NSSize(width: 360, height: 420)

    private var panel: ClipPanel?
    private let model = ClipListModel()

    private override init() { super.init() }

    var isVisible: Bool { panel?.isVisible == true }

    func toggle(fromStatusItem: Bool = false) {
        if isVisible { close() } else { show(fromStatusItem: fromStatusItem) }
    }

    func show(fromStatusItem: Bool = false) {
        // Remember where ⌘V should go before our panel becomes active.
        let front = NSWorkspace.shared.frontmostApplication
        ClipStore.shared.pasteTarget = front?.processIdentifier == getpid() ? nil : front

        model.reset()
        let p = panel ?? makePanel()
        panel = p
        let anchor = fromStatusItem ? MenuBarController.instance?.buttonWindowFrame : nil
        position(p, anchor: anchor)

        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
        // Give the search field focus once the window is key.
        DispatchQueue.main.async { [model] in model.focusToken = UUID() }
    }

    func close() {
        panel?.orderOut(nil)
    }

    // MARK: - Setup

    private func makePanel() -> ClipPanel {
        let p = ClipPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        p.isReleasedWhenClosed = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.hidesOnDeactivate = false   // resignKey closes it instead
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.onKeyDown = { [weak self] event in self?.handleKey(event) ?? false }

        let host = NSHostingView(rootView: ClipListView(model: model) { clip in
            ClipStore.shared.select(clip)
        })
        host.frame = NSRect(origin: .zero, size: Self.size)
        p.contentView = host
        return p
    }

    /// Pins the panel just below the menu bar on the screen under the mouse.
    /// Centred under the status icon when `anchor` is given, otherwise centred on the screen.
    private func position(_ p: ClipPanel, anchor: NSRect?) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens[0]
        let area = screen.visibleFrame
        let size = Self.size

        let centreX = anchor?.midX ?? area.midX
        var x = centreX - size.width / 2
        x = min(max(x, area.minX + 8), area.maxX - size.width - 8)
        let y = area.maxY - 6 - size.height
        p.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }

    // MARK: - Keys

    /// Returns true when the key was handled. Everything else goes to the search field.
    private func handleKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if mods == .shift, Int(event.keyCode) == kVK_Return || Int(event.keyCode) == kVK_ANSI_KeypadEnter {
            if let clip = model.selectedClip { ClipStore.shared.select(clip, plainText: true) }
            return true
        }
        if mods == .command, event.charactersIgnoringModifiers == "p" {
            if let clip = model.selectedClip { ClipStore.shared.togglePin(clip) }
            return true
        }
        if mods.contains(.command) {
            guard let key = event.charactersIgnoringModifiers, key.count == 1,
                  let digit = Int(key), (0...9).contains(digit) else { return false }
            if let clip = model.clip(at: digit) { ClipStore.shared.select(clip) }
            return true
        }
        guard mods.subtracting(.capsLock).isEmpty else { return false }

        switch Int(event.keyCode) {
        case kVK_UpArrow:
            model.move(by: -1)
            return true
        case kVK_DownArrow:
            model.move(by: 1)
            return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if let clip = model.selectedClip { ClipStore.shared.select(clip) }
            return true
        case kVK_Escape:
            close()
            return true
        case kVK_Delete:
            // Only when the search field is empty; otherwise ⌫ edits the query.
            guard model.query.isEmpty, let clip = model.selectedClip else { return false }
            ClipStore.shared.delete(clip)
            return true
        default:
            return false
        }
    }
}
