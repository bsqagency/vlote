import AppKit
import Carbon.HIToolbox

/// Two quick presses of Tab (no modifiers) run "Arrange now" from anywhere.
///
/// Watching keys system-wide needs Input Monitoring, which the setup window asks for.
/// Does nothing until that permission is granted.
final class DoubleTabWatcher {
    static let shared = DoubleTabWatcher()
    private init() {}

    var onDoubleTap: (() -> Void)?

    private var monitors: [Any] = []
    private var lastTab: TimeInterval = 0
    private let window: TimeInterval = 0.35

    func start() {
        guard monitors.isEmpty else { return }
        guard CGPreflightListenEventAccess() else { return }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] in self?.handle($0) }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            self?.handle(event)
            return event
        }) {
            monitors.append(local)
        }
    }

    private func handle(_ event: NSEvent) {
        guard event.keyCode == UInt16(kVK_Tab), !event.isARepeat,
              event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
        else { return }

        let now = event.timestamp
        if now - lastTab <= window {
            lastTab = 0
            DispatchQueue.main.async { [weak self] in self?.onDoubleTap?() }
        } else {
            lastTab = now
        }
    }
}
