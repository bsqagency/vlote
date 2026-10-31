import Foundation

struct CaptureMeta: Codable {
    var id: UUID
    var createdAt: Date
    var scale: Double
    var width: Int
    var height: Int
    var name: String?
    /// On-device OCR text, so history is searchable by what's *in* the screenshot.
    var ocrText: String?
}

/// Capture history, one folder per capture:
///
///     ~/Library/Application Support/Snaple/Captures/<uuid>/{original.png, meta.json, edits.json}
///
/// The original is never modified; annotations live in `edits.json`, which is what makes edits
/// re-openable. NOTE: because the original is kept, redactions exist only in *exported* files. Anyone
/// handling sensitive captures should turn history off in Settings or lower the retention period.
final class CaptureStore {
    static let shared = CaptureStore()

    let root: URL
    private let queue = DispatchQueue(label: "snaple.store", qos: .utility)

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Snaple/Captures", isDirectory: true)
    }

    func directory(for id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    func originalURL(for id: UUID) -> URL { directory(for: id).appendingPathComponent("original.png") }

    /// Blocks until queued writes finish (tests, and app termination).
    func flush() { queue.sync {} }

    /// Fire-and-forget: persistence must never sit on the capture-to-thumbnail path.
    func persist(_ capture: CapturedImage) {
        queue.async { [self] in
            guard let png = ImageEncoder.data(for: capture.image, scale: capture.scale, format: .png) else { return }
            let dir = directory(for: capture.id)
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try png.write(to: originalURL(for: capture.id), options: .atomic)
                let meta = CaptureMeta(id: capture.id, createdAt: capture.createdAt, scale: Double(capture.scale),
                                       width: capture.image.width, height: capture.image.height)
                try JSONEncoder.iso.encode(meta).write(to: dir.appendingPathComponent("meta.json"), options: .atomic)
                if Preferences.indexText { indexText(of: capture) }
            } catch {
                NSLog("Snaple: could not persist capture: \(error.localizedDescription)")
            }
        }
    }

    /// Runs Vision OCR off the capture path and stores the result in meta.json. Strictly on-device.
    private func indexText(of capture: CapturedImage) {
        let id = capture.id
        Task.detached(priority: .utility) { [self] in
            guard let text = try? await Recognizer.text(in: capture.image), !text.isEmpty else { return }
            updateMeta(id) { $0.ocrText = String(text.prefix(100_000)) }
        }
    }

    func updateMeta(_ id: UUID, _ change: @escaping (inout CaptureMeta) -> Void) {
        queue.async { [self] in
            let url = directory(for: id).appendingPathComponent("meta.json")
            guard let data = try? Data(contentsOf: url), var meta = try? JSONDecoder.iso.decode(CaptureMeta.self, from: data) else { return }
            change(&meta)
            try? JSONEncoder.iso.encode(meta).write(to: url, options: .atomic)
        }
    }

    func saveState(_ state: DocumentState, for id: UUID) {
        guard Preferences.keepHistory else { return }
        queue.async { [self] in
            let dir = directory(for: id)
            guard FileManager.default.fileExists(atPath: dir.path) else { return }
            let url = dir.appendingPathComponent("edits.json")
            if state == DocumentState() { try? FileManager.default.removeItem(at: url); return }
            try? JSONEncoder().encode(state).write(to: url, options: .atomic)
        }
    }

    func loadState(for id: UUID) -> DocumentState? {
        guard let data = try? Data(contentsOf: directory(for: id).appendingPathComponent("edits.json")) else { return nil }
        return try? JSONDecoder().decode(DocumentState.self, from: data)
    }

    /// Deletes only folders this store created (UUID-named, containing meta.json) older than `days`.
    func prune(olderThanDays days: Int) {
        guard days > 0 else { return }
        queue.async { [self] in
            let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
            let fm = FileManager.default
            guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
            for dir in dirs where UUID(uuidString: dir.lastPathComponent) != nil {
                guard let data = try? Data(contentsOf: dir.appendingPathComponent("meta.json")),
                      let meta = try? JSONDecoder.iso.decode(CaptureMeta.self, from: data),
                      meta.createdAt < cutoff else { continue }
                try? fm.removeItem(at: dir)
            }
        }
    }

    /// All captures on disk, newest first.
    func list() -> [CaptureMeta] {
        flush()
        guard let dirs = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        return dirs.compactMap { dir -> CaptureMeta? in
            guard UUID(uuidString: dir.lastPathComponent) != nil,
                  let d = try? Data(contentsOf: dir.appendingPathComponent("meta.json")) else { return nil }
            return try? JSONDecoder.iso.decode(CaptureMeta.self, from: d)
        }.sorted { $0.createdAt > $1.createdAt }
    }

    func load(id: UUID) -> (CapturedImage, DocumentState?)? {
        guard let m = list().first(where: { $0.id == id }),
              let src = CGImageSourceCreateWithURL(originalURL(for: id) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return (CapturedImage(id: m.id, image: image, scale: CGFloat(m.scale), createdAt: m.createdAt), loadState(for: id))
    }

    func latest() -> (CapturedImage, DocumentState?)? {
        guard let m = list().first else { return nil }
        return load(id: m.id)
    }

    /// Decodes a downsampled preview straight from disk — never loads the full-size bitmap.
    func thumbnail(for id: UUID, maxPixel: Int = 480) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(originalURL(for: id) as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxPixel]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    func delete(id: UUID) {
        guard UUID(uuidString: id.uuidString) != nil else { return }
        queue.async { [self] in try? FileManager.default.removeItem(at: directory(for: id)) }
    }
}

import ImageIO

extension JSONEncoder {
    static var iso: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }
}
extension JSONDecoder {
    static var iso: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}
