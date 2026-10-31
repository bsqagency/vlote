import AppKit
import SwiftUI

enum ThumbnailAction { case copy, save, upload, edit, pin, close }

/// Observable so the drag source can pick up the file URL once the background write finishes.
@MainActor
final class ThumbnailItem: ObservableObject {
    let capture: CapturedImage
    @Published var fileURL: URL?
    var savedByUser = false
    init(capture: CapturedImage) { self.capture = capture }
}

struct ThumbnailView: View {
    @ObservedObject var item: ThumbnailItem
    var onAction: (ThumbnailAction) -> Void
    var onHover: (Bool) -> Void
    @State private var hovering = false

    var body: some View {
        let image = NSImage(cgImage: item.capture.image, size: item.capture.pointSize)
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: ThumbnailController.width, maxHeight: ThumbnailController.maxHeight)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.18), lineWidth: 1)
            }
            .overlay {
                if hovering {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.45))
                        HStack(spacing: 8) {
                            button("doc.on.doc", "Copy", .copy)
                            button("square.and.arrow.down", "Save", .save)
                            button("icloud.and.arrow.up", "Upload and copy link", .upload)
                            button("pencil.tip.crop.circle", "Edit", .edit)
                            button("pin", "Pin on top", .pin)
                        }
                        VStack {
                            HStack { button("xmark", "Dismiss", .close, small: true); Spacer() }
                            Spacer()
                        }.padding(6)
                    }
                    .transition(.opacity)
                }
            }
            .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
            .padding(12)
            .onHover { inside in
                withAnimation(.easeOut(duration: 0.12)) { hovering = inside }
                onHover(inside)
            }
            .onDrag {
                if let url = item.fileURL, let provider = NSItemProvider(contentsOf: url) { return provider }
                return NSItemProvider(object: image)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Screenshot thumbnail")
    }

    private func button(_ symbol: String, _ label: String, _ action: ThumbnailAction, small: Bool = false) -> some View {
        Button { onAction(action) } label: {
            Image(systemName: symbol)
                .font(.system(size: small ? 10 : 14, weight: .semibold))
                .frame(width: small ? 20 : 30, height: small ? 20 : 30)
                .background(.regularMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Stack of floating, non-activating thumbnails in the bottom-right corner. Drag one into any app,
/// or hover for copy / save / edit / pin. Dismisses itself unless the pointer is over it.
@MainActor
final class ThumbnailController {
    static let shared = ThumbnailController()
    static let width: CGFloat = 220
    static let maxHeight: CGFloat = 170

    var handler: ((ThumbnailAction, ThumbnailItem) -> Void)?

    private struct Entry {
        let id: UUID
        let panel: NSPanel
        let item: ThumbnailItem
        var timer: Timer?
    }
    private var entries: [Entry] = []

    func show(_ item: ThumbnailItem) {
        let id = item.capture.id
        let view = ThumbnailView(
            item: item,
            onAction: { [weak self] action in self?.perform(action, id) },
            onHover: { [weak self] inside in self?.hover(inside, id) }
        )
        let host = NSHostingView(rootView: view)
        host.setFrameSize(host.fittingSize)

        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: host.fittingSize),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        entries.append(Entry(id: id, panel: panel, item: item))
        layout(animated: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.18; panel.animator().alphaValue = 1 }
        scheduleDismiss(id)
    }

    var isShowing: Bool { !entries.isEmpty }

    private func perform(_ action: ThumbnailAction, _ id: UUID) {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        if action == .close { remove(id) } else if action == .edit || action == .pin { remove(id); handler?(action, entry.item) }
        else { handler?(action, entry.item) }
    }

    private func hover(_ inside: Bool, _ id: UUID) {
        if inside { entries.first { $0.id == id }?.timer?.invalidate() } else { scheduleDismiss(id) }
    }

    private func scheduleDismiss(_ id: UUID) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].timer?.invalidate()
        let seconds = Preferences.thumbnailSeconds
        guard seconds > 0 else { return }
        entries[i].timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.remove(id) }
        }
    }

    private func remove(_ id: UUID) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        let entry = entries.remove(at: i)
        entry.timer?.invalidate()
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.18; entry.panel.animator().alphaValue = 0 },
                                             completionHandler: { entry.panel.orderOut(nil) })
        layout(animated: true)
    }

    private func layout(animated: Bool) {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        var y = screen.visibleFrame.minY + 8
        for entry in entries {
            let size = entry.panel.frame.size
            let origin = CGPoint(x: screen.visibleFrame.maxX - size.width - 4, y: y)
            if animated { entry.panel.animator().setFrameOrigin(origin) } else { entry.panel.setFrameOrigin(origin) }
            y += size.height - 8
        }
    }
}
