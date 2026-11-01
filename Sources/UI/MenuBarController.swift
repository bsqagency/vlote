import AppKit
import SwiftUI

/// The menu bar item and the popover it owns.
final class MenuBarController: NSObject, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var monitor: Any?

    /// Lets other windows anchor to the status icon (e.g. the clipboard panel).
    private(set) static weak var instance: MenuBarController?

    /// Screen frame of the status item's window, or nil before install.
    var buttonWindowFrame: NSRect? { statusItem?.button?.window?.frame }

    /// Left and right click both open this menu. The panel is reached only from its item.
    func install(menu: NSMenu) {
        MenuBarController.instance = self
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.menu = menu

        statusItem.button?.toolTip = "Vlote"

        popover.contentSize = NSSize(width: 400, height: 560)
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        updateIcon()
    }

    /// Swaps between the filled and outlined glyph so the current mode is
    /// readable at a glance without opening anything.
    func updateIcon() {
        guard let button = statusItem?.button else { return }
        let active = Settings.shared.autoTile
        button.image = StatusIcon.image(active: active)
        button.image?.accessibilityDescription =
            active ? "Vlote, arranging" : "Vlote, paused"
        button.imagePosition = button.title.isEmpty ? .imageOnly : .imageLeading
    }

    /// Shows text next to the icon (used for the capture countdown). Empty hides it.
    func setTitle(_ title: String) {
        guard let button = statusItem?.button else { return }
        button.title = title
        button.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
    }

    func showPopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown { return }
        // A fresh hosting controller each time, so the panel's state (page, tab) starts at Home.
        popover.contentViewController = NSHostingController(rootView: PanelView())
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
