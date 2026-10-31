import AppKit
import SwiftUI

@MainActor
final class LibraryWindowController: NSWindowController, NSWindowDelegate {
    static let shared = LibraryWindowController()
    private let model = LibraryModel()

    private init() {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 960, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Snaple Library"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: LibraryView(model: model))
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(signIn: Bool = false) {
        if window?.isVisible != true { ActivationPolicy.windowOpened() }
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        Task { await model.refresh() }
        if signIn && !CloudSession.shared.isSignedIn { model.showSignIn = true }
    }

    func windowWillClose(_ notification: Notification) { ActivationPolicy.windowClosed() }
}
