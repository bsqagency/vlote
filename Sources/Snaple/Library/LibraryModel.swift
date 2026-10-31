import AppKit
import SwiftUI

struct LibraryItem: Identifiable {
    let id: UUID
    var createdAt: Date
    var name: String
    var width: Int
    var height: Int
    var local: CaptureMeta?
    var cloud: CloudCapture?
    var searchText: String

    var isLocal: Bool { local != nil }
    var isCloud: Bool { cloud != nil }
    var shareURL: URL? { cloud?.shareURL }
}

@MainActor
final class LibraryModel: ObservableObject {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", mac = "This Mac", cloud = "Cloud"
        var id: String { rawValue }
    }

    @Published private(set) var items: [LibraryItem] = []
    @Published var query = ""
    @Published var filter: Filter = .all
    @Published var loading = false
    @Published var error: String?
    @Published var showSignIn = false

    private let store = CaptureStore.shared

    var visible: [LibraryItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return items.filter { item in
            switch filter {
            case .all: break
            case .mac: if !item.isLocal { return false }
            case .cloud: if !item.isCloud { return false }
            }
            return q.isEmpty || item.searchText.contains(q)
        }
    }

    var cloudBytes: Int64 { items.compactMap { $0.cloud?.bytes }.reduce(0, +) }

    /// Merges this Mac's history with the cloud library. Captures share an ID, so an uploaded capture
    /// appears once, badged as being in both places.
    func refresh() async {
        loading = true
        error = nil
        defer { loading = false }

        var byID: [UUID: LibraryItem] = [:]
        for meta in await Task.detached(priority: .userInitiated, operation: { CaptureStore.shared.list() }).value {
            byID[meta.id] = LibraryItem(id: meta.id, createdAt: meta.createdAt, name: meta.name ?? Output.fileName(for: meta.createdAt),
                                        width: meta.width, height: meta.height, local: meta, cloud: nil,
                                        searchText: ((meta.name ?? "") + " " + (meta.ocrText ?? "")).lowercased())
        }
        if CloudSession.shared.isSignedIn {
            do {
                for c in try await CloudAPI.shared.list() {
                    var item = byID[c.id] ?? LibraryItem(id: c.id, createdAt: c.createdAt, name: c.name, width: c.width, height: c.height,
                                                          local: nil, cloud: nil, searchText: "")
                    item.cloud = c
                    if item.local == nil { item.name = c.name }
                    item.searchText += " " + c.name.lowercased() + " " + (c.ocrText ?? "").lowercased()
                    byID[c.id] = item
                }
            } catch {
                self.error = "Cloud: \(error.localizedDescription)"
            }
        }
        items = byID.values.sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: Actions

    func open(_ item: LibraryItem) async {
        if let (capture, state) = store.load(id: item.id) {
            EditorWindowController.present(capture, state: state)
        } else if let c = item.cloud, let image = await cloudImage(c) {
            EditorWindowController.present(CapturedImage(id: c.id, image: image, scale: CGFloat(c.scale), createdAt: c.createdAt))
        }
    }

    func copyImage(_ item: LibraryItem) async {
        if let (capture, state) = store.load(id: item.id) {
            Output.copyToPasteboard(flattened(capture, state), scale: capture.scale)
        } else if let c = item.cloud, let image = await cloudImage(c) {
            Output.copyToPasteboard(image, scale: CGFloat(c.scale))
        } else { return }
        Toast.show("Image copied", symbol: "doc.on.doc.fill")
    }

    func upload(_ item: LibraryItem) async {
        guard let (capture, state) = store.load(id: item.id), let image = flattened(capture, state) else { return }
        await CloudUploader.upload(image: image, scale: capture.scale, id: capture.id, createdAt: capture.createdAt, makeLink: false)
        await refresh()
    }

    func share(_ item: LibraryItem, days: Int?) async {
        do {
            if !item.isCloud { await upload(item) }
            let url = try await CloudAPI.shared.share(id: item.id, expiresInDays: days)
            Output.copyText(url.absoluteString)
            Toast.show("Link copied", symbol: "link")
            await refresh()
        } catch { Toast.show("Could not share: \(error.localizedDescription)", symbol: "exclamationmark.triangle.fill") }
    }

    func copyLink(_ item: LibraryItem) {
        guard let url = item.shareURL else { return }
        Output.copyText(url.absoluteString)
        Toast.show("Link copied", symbol: "link")
    }

    func unshare(_ item: LibraryItem) async {
        do { try await CloudAPI.shared.unshare(id: item.id); Toast.show("Link disabled", symbol: "link.badge.plus"); await refresh() }
        catch { Toast.show("Could not stop sharing: \(error.localizedDescription)", symbol: "exclamationmark.triangle.fill") }
    }

    func rename(_ item: LibraryItem, to name: String) async {
        let clean = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        guard !clean.isEmpty else { return }
        if item.isLocal { store.updateMeta(item.id) { $0.name = clean }; store.flush() }
        if item.isCloud { try? await CloudAPI.shared.rename(id: item.id, to: clean) }
        await refresh()
    }

    enum DeleteScope { case mac, cloud, everywhere }

    func delete(_ item: LibraryItem, scope: DeleteScope) async {
        do {
            if scope != .mac, let c = item.cloud { try await CloudAPI.shared.delete(c) }
            if scope != .cloud, item.isLocal { store.delete(id: item.id); store.flush() }
        } catch { Toast.show("Could not delete: \(error.localizedDescription)", symbol: "exclamationmark.triangle.fill") }
        await refresh()
    }

    func showInFinder(_ item: LibraryItem) {
        guard item.isLocal else { return }
        NSWorkspace.shared.activateFileViewerSelecting([store.originalURL(for: item.id)])
    }

    // MARK: Helpers

    private func flattened(_ capture: CapturedImage, _ state: DocumentState?) -> CGImage? {
        guard let state, state != DocumentState() else { return capture.image }
        return AnnotationRenderer(base: capture.image, scale: capture.scale).export(state.annotations, crop: state.cropRect) ?? capture.image
    }

    private func cloudImage(_ c: CloudCapture) async -> CGImage? {
        guard let data = try? await CloudAPI.shared.download(path: c.storagePath),
              let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}

import ImageIO
