import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    private static var open: [UUID: EditorWindowController] = [:]

    let model: EditorModel

    static func present(_ capture: CapturedImage, state: DocumentState? = nil) {
        if let existing = open[capture.id] {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let wc = EditorWindowController(capture: capture, state: state)
        open[capture.id] = wc
        ActivationPolicy.windowOpened()
        wc.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private init(capture: CapturedImage, state: DocumentState?) {
        model = EditorModel(capture: capture, state: state)

        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let content = capture.pointSize
        let size = CGSize(width: min(max(content.width + 40, 1040), max(1040, screen.width * 0.9)),
                          height: min(max(content.height + 90, 520), screen.height * 0.9))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Snaple — " + capture.createdAt.formatted(date: .abbreviated, time: .standard)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: EditorView(
            model: model,
            onSaveAs: { [weak self] in self?.saveAs() },
            onUpload: { [weak self] in self?.upload() },
            onDone: { [weak self] in self?.done() }
        ))
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc func saveDocument(_ sender: Any?) { saveAs() }

    private func saveAs() {
        guard let window, let image = model.exportImage() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.nameFieldStringValue = Output.fileName(for: model.capture.createdAt) + ".png"
        panel.directoryURL = Preferences.saveDirectoryURL
        panel.beginSheetModal(for: window) { [scale = model.capture.scale] response in
            guard response == .OK, let url = panel.url else { return }
            let format: ImageFormat = url.pathExtension.lowercased().hasPrefix("jp") ? .jpeg : .png
            do {
                guard let data = ImageEncoder.data(for: image, scale: scale, format: format) else { throw CaptureError.failed("Could not encode image.") }
                try data.write(to: url, options: .atomic)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    /// Uploads the flattened result, so redactions are baked in and annotations aren't recoverable from the cloud copy.
    private func upload() {
        guard let image = model.exportImage() else { return }
        let c = model.capture
        Task { await CloudUploader.upload(image: image, scale: c.scale, id: c.id, createdAt: c.createdAt) }
    }

    private func done() {
        Output.copyToPasteboard(model.exportImage(), scale: model.capture.scale)
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        CaptureStore.shared.saveState(model.state, for: model.capture.id)
        Self.open[model.capture.id] = nil
        ActivationPolicy.windowClosed()
    }
}

/// The app lives in the menu bar (`.accessory`). While an editor or settings window is open it becomes a
/// regular app so the menu bar and ⌘-shortcuts work, then returns to the menu bar when the last one closes.
@MainActor
enum ActivationPolicy {
    private static var count = 0
    static func windowOpened() {
        count += 1
        NSApp.setActivationPolicy(.regular)
    }
    static func windowClosed() {
        count = max(0, count - 1)
        if count == 0 { NSApp.setActivationPolicy(.accessory) }
    }
}
