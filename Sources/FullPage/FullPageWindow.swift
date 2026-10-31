import AppKit
import SwiftUI

/// Step 5: preview window for a stitched full-page capture, with Copy and Download.
final class FullPageWindow: NSWindowController, NSWindowDelegate {
    private static var current: FullPageWindow?
    private static let lastDirectoryKey = "fullPage.lastSaveDirectory"

    private let image: CGImage
    private let pageTitle: String
    private let pageURL: String?
    private let scale: CGFloat

    /// Opens (or replaces) the preview window.
    static func show(image: CGImage, title: String, url: String? = nil) {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let controller = FullPageWindow(image: image, title: title, url: url, scale: scale)
        current?.close()
        current = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private init(image: CGImage, title: String, url: String?, scale: CGFloat) {
        self.image = image
        self.pageTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.pageURL = url
        self.scale = scale

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 720),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Full Page Screenshot"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 420, height: 360)
        window.center()
        super.init(window: window)
        window.delegate = self

        let pixelSize = "\(image.width) × \(image.height) px"
        let nsImage = NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width) / scale,
                                                           height: CGFloat(image.height) / scale))
        window.contentView = NSHostingView(rootView: FullPageView(
            image: nsImage,
            pageTitle: self.pageTitle,
            pageURL: url,
            pixelSize: pixelSize,
            onCopy: { [weak self] in self?.copy() },
            onSave: { [weak self] format in self?.save(format) }
        ))
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func windowWillClose(_ notification: Notification) {
        if FullPageWindow.current === self { FullPageWindow.current = nil }
    }

    // MARK: - Actions

    private func copy() {
        Output.copyToPasteboard(image, scale: scale)
    }

    private func save(_ format: FullPageFormat) {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.utType]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(suggestedBaseName()).\(format.fileExtension)"
        panel.directoryURL = lastDirectory()
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.write(format, to: url)
        }
    }

    private func write(_ format: FullPageFormat, to url: URL) {
        do {
            guard let data = PDFExport.data(for: image, format: format, scale: scale) else {
                throw CaptureError.failed("Could not encode the image as \(format.menuTitle).")
            }
            try data.write(to: url, options: .atomic)
            UserDefaults.standard.set(url.deletingLastPathComponent().path, forKey: Self.lastDirectoryKey)
        } catch {
            if let window {
                NSAlert(error: error).beginSheetModal(for: window, completionHandler: nil)
            }
        }
    }

    // MARK: - Naming and folders

    /// "<page title> <date>", with path-unsafe characters removed.
    private func suggestedBaseName() -> String {
        var title = pageTitle.isEmpty ? "Full Page" : pageTitle
        title = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        if title.count > 80 { title = String(title.prefix(80)).trimmingCharacters(in: .whitespaces) }

        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "\(title) \(f.string(from: Date()))"
    }

    private func lastDirectory() -> URL {
        if let path = UserDefaults.standard.string(forKey: Self.lastDirectoryKey),
           FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    }
}

// MARK: - SwiftUI view

private struct FullPageView: View {
    let image: NSImage
    let pageTitle: String
    let pageURL: String?
    let pixelSize: String
    let onCopy: () -> Void
    let onSave: (FullPageFormat) -> Void

    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Full Page Screenshot")
                    .font(.headline)
                if !pageTitle.isEmpty {
                    Text(pageTitle)
                        .font(.subheadline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if let pageURL, !pageURL.isEmpty {
                    Text(pageURL)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
                    .padding(16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.secondary.opacity(0.07))

            Divider()

            HStack(spacing: 10) {
                Text(pixelSize)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    onCopy()
                    copied = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .frame(minWidth: 70)
                }
                .buttonStyle(.bordered)
                .tint(Color.accentColor)
                .keyboardShortcut("c", modifiers: .command)

                Menu {
                    ForEach(FullPageFormat.allCases) { format in
                        Button(format.menuTitle) { onSave(format) }
                    }
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                }
                .menuStyle(.button)
                .tint(Color.accentColor)
                .fixedSize()
            }
            .padding(12)
        }
        .frame(minWidth: 420, minHeight: 360)
    }
}
