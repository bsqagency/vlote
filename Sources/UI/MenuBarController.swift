import AppKit
import SwiftUI

/// The menu bar item and the popover it owns.
final class MenuBarController: NSObject, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var monitor: Any?

    func install() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.action = #selector(togglePopover)
            button.target = self
            button.toolTip = "Macnizer"
        }

        popover.contentSize = NSSize(width: 400, height: 560)
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: PanelView())

        updateIcon()
    }

    /// Swaps between the filled and outlined glyph so the current mode is
    /// readable at a glance without opening anything.
    func updateIcon() {
        guard let button = statusItem?.button else { return }
        let active = Settings.shared.autoTile
        button.image = StatusIcon.image(active: active)
        button.image?.accessibilityDescription =
            active ? "Macnizer, arranging" : "Macnizer, paused"
    }

    @objc func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    func showPopover() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // A popover from an accessory app does not take key focus on its own,
        // so text fields inside it would be unusable without this.
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverDidClose(_ notification: Notification) {
        updateIcon()
    }
}
