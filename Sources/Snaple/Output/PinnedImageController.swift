import AppKit

/// Always-on-top reference image. Drag to move; right-click for opacity / copy / close; double-click closes.
@MainActor
final class PinnedImageController {
    static let shared = PinnedImageController()
    private var panels: [NSPanel] = []

    func pin(_ capture: CapturedImage) {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        var size = capture.pointSize
        let limit = CGSize(width: screen.visibleFrame.width * 0.6, height: screen.visibleFrame.height * 0.6)
        let factor = min(1, limit.width / size.width, limit.height / size.height)
        size = CGSize(width: size.width * factor, height: size.height * factor)

        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        let view = PinView(capture: capture, owner: self, panel: panel)
        view.frame = CGRect(origin: .zero, size: size)
        panel.contentView = view
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.contentAspectRatio = size
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let offset = CGFloat(panels.count % 6) * 24
        panel.setFrameOrigin(CGPoint(x: screen.visibleFrame.midX - size.width / 2 + offset, y: screen.visibleFrame.midY - size.height / 2 - offset))
        panel.orderFrontRegardless()
        panels.append(panel)
    }

    fileprivate func close(_ panel: NSPanel) {
        panel.orderOut(nil)
        panels.removeAll { $0 === panel }
    }
}

private final class PinView: NSView {
    let capture: CapturedImage
    unowned let owner: PinnedImageController
    unowned let panel: NSPanel
    private let imageView = NSImageView()

    init(capture: CapturedImage, owner: PinnedImageController, panel: NSPanel) {
        self.capture = capture; self.owner = owner; self.panel = panel
        super.init(frame: .zero)
        imageView.image = NSImage(cgImage: capture.image, size: capture.pointSize)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.autoresizingMask = [.width, .height]
        addSubview(imageView)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() { super.layout(); imageView.frame = bounds }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { MainActor.assumeIsolated { owner.close(panel) } } else { super.mouseDown(with: event) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        for pct in [100, 75, 50, 25] {
            let item = NSMenuItem(title: "Opacity \(pct)%", action: #selector(setOpacity(_:)), keyEquivalent: "")
            item.tag = pct; item.target = self; item.state = Int(panel.alphaValue * 100) == pct ? .on : .off
            m.addItem(item)
        }
        m.addItem(.separator())
        m.addItem(withTitle: "Copy", action: #selector(copyImage), keyEquivalent: "").target = self
        m.addItem(withTitle: "Close", action: #selector(closePin), keyEquivalent: "").target = self
        return m
    }

    @objc private func setOpacity(_ sender: NSMenuItem) { panel.alphaValue = CGFloat(sender.tag) / 100 }
    @objc private func copyImage() { Output.copyToPasteboard(capture.image, scale: capture.scale) }
    @objc private func closePin() { MainActor.assumeIsolated { owner.close(panel) } }
}
