import AppKit
import Carbon.HIToolbox
import Combine

enum ClipKind: String, Codable {
    case text
    case image
}

struct Clip: Codable, Identifiable, Equatable {
    let id: UUID
    let kind: ClipKind
    let text: String?
    let imageFile: URL?
    let sourceApp: String?
    let date: Date
    var pinned: Bool

    init(id: UUID, kind: ClipKind, text: String?, imageFile: URL?,
         sourceApp: String?, date: Date, pinned: Bool = false) {
        self.id = id
        self.kind = kind
        self.text = text
        self.imageFile = imageFile
        self.sourceApp = sourceApp
        self.date = date
        self.pinned = pinned
    }

    /// `pinned` is missing in clips.json written before pins existed.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(ClipKind.self, forKey: .kind)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        imageFile = try c.decodeIfPresent(URL.self, forKey: .imageFile)
        sourceApp = try c.decodeIfPresent(String.self, forKey: .sourceApp)
        date = try c.decode(Date.self, forKey: .date)
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
    }
}

/// Clipboard history. Polls NSPasteboard for changes, keeps the newest
/// `ClipPreferences.historySize` items, and persists them to Application Support.
final class ClipStore: ObservableObject {
    static let shared = ClipStore()

    @Published private(set) var clips: [Clip] = []

    /// changeCount produced by our own writes; the poller ignores it.
    private(set) var ownChangeCount: Int = -1

    private var lastChangeCount: Int
    private var timer: Timer?
    private let pasteboard: NSPasteboard
    private let frontmostBundleID: () -> String?
    private var cancellables = Set<AnyCancellable>()

    private let fm = FileManager.default
    private let supportDir: URL
    private let imagesDir: URL
    private let clipsURL: URL

    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    /// Tests pass a named pasteboard, a temp support dir, and a fake frontmost app; the app uses the defaults.
    init(pasteboard: NSPasteboard = .general,
         supportDir: URL? = nil,
         frontmostBundleID: @escaping () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
         startTimer: Bool = true) {
        self.pasteboard = pasteboard
        self.frontmostBundleID = frontmostBundleID
        let appSupport = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                      appropriateFor: nil, create: true))
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        self.supportDir = supportDir ?? appSupport.appendingPathComponent("vlote", isDirectory: true)
        imagesDir = self.supportDir.appendingPathComponent("images", isDirectory: true)
        clipsURL = self.supportDir.appendingPathComponent("clips.json")
        try? fm.createDirectory(at: imagesDir, withIntermediateDirectories: true)

        lastChangeCount = pasteboard.changeCount
        clips = load()

        ClipPreferences.shared.$historySize
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                self.trim()
                self.save()
            }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard ClipPreferences.shared.clearOnQuit else { return }
            self?.deleteAll()
        }

        if startTimer {
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                self?.poll()
            }
        }
    }

    // MARK: - Polling

    func poll() {
        let pb = pasteboard
        let count = pb.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        guard count != ownChangeCount else { return }
        guard ClipPreferences.shared.recordHistory else { return }

        let types = pb.types ?? []
        if types.contains(Self.concealedType) || types.contains(Self.transientType) { return }

        let frontBundle = frontmostBundleID()
        if UniversalIgnore.shared.isIgnored(bundleID: frontBundle) { return }

        let sourceApp = NSWorkspace.shared.frontmostApplication?.localizedName

        if let text = pb.string(forType: .string), !text.isEmpty {
            if let newest = clips.first, newest.kind == .text, newest.text == text { return }
            insert(Clip(id: UUID(), kind: .text, text: text, imageFile: nil,
                        sourceApp: sourceApp, date: Date()))
            return
        }

        if let png = pngData(from: pb) {
            if let newest = clips.first, newest.kind == .image,
               let file = newest.imageFile,
               let old = try? Data(contentsOf: file), old == png { return }
            let url = imagesDir.appendingPathComponent("\(UUID().uuidString).png")
            do { try png.write(to: url, options: .atomic) } catch { return }
            insert(Clip(id: UUID(), kind: .image, text: nil, imageFile: url,
                        sourceApp: sourceApp, date: Date()))
        }
    }

    private func pngData(from pb: NSPasteboard) -> Data? {
        if let png = pb.data(forType: .png) { return png }
        if let tiff = pb.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: tiff) {
            return rep.representation(using: .png, properties: [:])
        }
        return nil
    }

    // MARK: - Mutations

    private func insert(_ clip: Clip) {
        clips.insert(clip, at: 0)
        sortPinnedFirst()
        trim()
        save()
    }

    /// Pinned clips first; the order inside each group is kept.
    private func sortPinnedFirst() {
        clips = clips.filter(\.pinned) + clips.filter { !$0.pinned }
    }

    /// Keeps the newest `historySize` unpinned clips and deletes image files of dropped ones.
    /// Pinned clips are never trimmed.
    private func trim() {
        let limit = max(1, ClipPreferences.shared.historySize)
        let unpinned = clips.filter { !$0.pinned }
        guard unpinned.count > limit else { return }
        let dropped = Set(unpinned[limit...].map(\.id))
        for clip in clips where dropped.contains(clip.id) { removeImage(of: clip) }
        clips.removeAll { dropped.contains($0.id) }
    }

    func togglePin(_ clip: Clip) {
        guard let i = clips.firstIndex(where: { $0.id == clip.id }) else { return }
        clips[i].pinned.toggle()
        sortPinnedFirst()
        save()
    }

    /// Writes the clip to the general pasteboard and records the resulting
    /// changeCount so the poller does not re-add it.
    func copyToPasteboard(_ clip: Clip, plainText: Bool = false) {
        let pb = pasteboard
        pb.clearContents()
        switch clip.kind {
        case .text:
            pb.setString(clip.text ?? "", forType: .string)
        case .image where plainText:
            break
        case .image:
            if let file = clip.imageFile, let data = try? Data(contentsOf: file) {
                pb.setData(data, forType: .png)
                if let rep = NSBitmapImageRep(data: data),
                   let tiff = rep.tiffRepresentation {
                    pb.setData(tiff, forType: .tiff)
                }
            }
        }
        ownChangeCount = pb.changeCount
        lastChangeCount = pb.changeCount
    }

    /// App that was frontmost when the history panel opened; paste goes there.
    var pasteTarget: NSRunningApplication?

    /// Copies the clip, closes the panel, and (if enabled) pastes it into `pasteTarget`.
    /// The copy is recorded as our own write, so the poller does not add it again.
    func select(_ clip: Clip, plainText: Bool = false) {
        copyToPasteboard(clip, plainText: plainText)
        ClipWindowController.shared.close()
        guard ClipPreferences.shared.pasteAutomatically else { return }

        pasteTarget?.activate(options: [])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            let source = CGEventSource(stateID: .combinedSessionState)
            let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
            down?.flags = .maskCommand
            up?.flags = .maskCommand
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        }
    }

    func delete(_ clip: Clip) {
        guard let i = clips.firstIndex(of: clip) else { return }
        removeImage(of: clip)
        clips.remove(at: i)
        save()
    }

    func deleteAll() {
        for clip in clips { removeImage(of: clip) }
        clips = []
        save()
    }

    /// Asks before wiping history. Shared by the panel and the status menu.
    func confirmDeleteAll() {
        let alert = NSAlert()
        alert.messageText = "Delete all clipboard history?"
        alert.informativeText = "This action cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete All")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            deleteAll()
        }
    }

    private func removeImage(of clip: Clip) {
        guard let file = clip.imageFile else { return }
        try? fm.removeItem(at: file)
    }

    // MARK: - Search

    func search(_ query: String) -> [Clip] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return clips }
        return clips.filter { clip in
            guard clip.kind == .text, let text = clip.text else { return false }
            return text.localizedCaseInsensitiveContains(q)
        }
    }

    // MARK: - Persistence

    private func load() -> [Clip] {
        guard let data = try? Data(contentsOf: clipsURL),
              let decoded = try? JSONDecoder().decode([Clip].self, from: data) else { return [] }
        return decoded
    }

    private func save() {
        do {
            try fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(clips)
            try data.write(to: clipsURL, options: .atomic)
        } catch {
            NSLog("vlote: failed to save clipboard history: \(error)")
        }
    }
}
