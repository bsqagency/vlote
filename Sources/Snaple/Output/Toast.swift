import AppKit
import SwiftUI

/// Small non-activating HUD for confirmations ("Copied 42 characters"). Never steals focus.
@MainActor
enum Toast {
    private static var panel: NSPanel?
    private static var dismiss: DispatchWorkItem?

    static func show(_ message: String, symbol: String = "checkmark.circle.fill") {
        dismiss?.cancel()
        panel?.orderOut(nil)

        let host = NSHostingView(rootView:
            HStack(spacing: 8) {
                Image(systemName: symbol).imageScale(.large)
                Text(message).lineLimit(2)
            }
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 16).padding(.vertical, 11)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(.primary.opacity(0.1)))
            .padding(10)
        )
        host.setFrameSize(host.fittingSize)

        let p = NSPanel(contentRect: CGRect(origin: .zero, size: host.fittingSize),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.contentView = host
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
        p.level = .statusBar; p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let screen = NSScreen.main ?? NSScreen.screens[0]
        p.setFrameOrigin(CGPoint(x: screen.frame.midX - p.frame.width / 2, y: screen.frame.maxY - 90 - p.frame.height))
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; p.animator().alphaValue = 1 }
        panel = p

        let work = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; p.animator().alphaValue = 0 },
                                                 completionHandler: { p.orderOut(nil) })
        }
        dismiss = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }
}
