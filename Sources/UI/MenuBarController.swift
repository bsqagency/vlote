import AppKit
import SwiftUI

/// The menu bar item and the popover it owns.
final class MenuBarController: NSObject, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var monitor: Any?

    /// Supplies the secondary (right-click) menu, e.g. Snaple's capture actions.
    var secondaryMenu: (() -> NSMenu)?

    func install() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.action = #selector(togglePopover)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "vlote"
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
            active ? "vlote, arranging" : "vlote, paused"
    }

    /// Shows text next to the icon (used for the capture countdown). Empty hides it.
    func setTitle(_ title: String) {
        guard let button = statusItem?.button else { return }
        button.title = title
        button.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
    }

    @objc func togglePopover() {
        if NSApp.currentEvent?.type == .rightMouseUp, let menu = secondaryMenu?() {
            if popover.isShown { popover.performClose(nil) }
            statusItem.popUpMenu(menu)
            return
        }
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
