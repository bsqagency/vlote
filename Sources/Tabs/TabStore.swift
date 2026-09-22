import AppKit
import Combine

/// A named snapshot of tabs you can bring back later.
struct SavedSession: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var createdAt: Date
    var urls: [String]
    var titles: [String]
}

/// The tab side of the app: what is open, what is duplicated, and what the user
/// has stashed for later.
@MainActor
final class TabStore: ObservableObject {
    static let shared = TabStore()

    @Published private(set) var tabs: [TabRef] = []
    @Published private(set) var sessions: [SavedSession] = []
    @Published private(set) var isLoading = false
    @Published var lastError: String?
    @Published var search = ""

    private init() { sessions = Self.loadSessions() }

    // MARK: - Derived views

    var filtered: [TabRef] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return tabs }
        return tabs.filter {
            $0.title.lowercased().contains(q) || $0.url.lowercased().contains(q)
        }
    }

    /// Tabs grouped by page, keeping only groups with more than one member.
    /// Sorted by group size so the worst offenders are at the top.
    var duplicateGroups: [[TabRef]] {
        Dictionary(grouping: tabs, by: \.dedupeKey)
            .values
            .filter { $0.count > 1 }
            .sorted { $0.count > $1.count }
    }

    /// Every duplicate except one survivor per page — i.e. exactly what "close
    /// duplicates" should close.
    var redundantTabs: [TabRef] {
        duplicateGroups.flatMap { $0.dropFirst() }
    }

    var tabsByBrowser: [(name: String, count: Int)] {
        Dictionary(grouping: tabs, by: \.browserName)
            .map { (name: $0.key, count: $0.value.count) }
            .sorted { $0.count > $1.count }
    }

    // MARK: - Actions

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        lastError = nil

        BrowserBridge.allTabs { [weak self] tabs, errors in
            guard let self else { return }
            self.tabs = tabs.sorted {
                ($0.browserName, $0.windowIndex, $0.tabIndex) <
                ($1.browserName, $1.windowIndex, $1.tabIndex)
            }
            self.lastError = errors.first?.localizedDescription
            self.isLoading = false
        }
    }

    func close(_ toClose: [TabRef]) {
        guard !toClose.isEmpty else { return }
        let ids = Set(toClose.map(\.id))
        // Drop them from the list immediately; indices in the remaining tabs are
        // now stale anyway, and the refresh below replaces the whole snapshot.
        tabs.removeAll { ids.contains($0.id) }

        BrowserBridge.close(toClose) { [weak self] errors in
            guard let self else { return }
            if let first = errors.first { self.lastError = first.localizedDescription }
            self.refresh()
        }
    }

    func closeDuplicates() { close(redundantTabs) }

    // MARK: - Sessions

    func saveSession(named name: String, tabs source: [TabRef]? = nil) {
        let picked = source ?? tabs
        guard !picked.isEmpty else { return }

        let session = SavedSession(name: name.isEmpty ? defaultSessionName() : name,
                                   createdAt: Date(),
                                   urls: picked.map(\.url),
                                   titles: picked.map(\.title))
        sessions.insert(session, at: 0)
        persistSessions()
    }

    func restore(_ session: SavedSession) {
        guard let browser = Browser.running.first ?? Browser.all.first else { return }
        BrowserBridge.open(urls: session.urls, in: browser) { [weak self] error in
            if let error { self?.lastError = error.localizedDescription }
        }
    }

    func delete(_ session: SavedSession) {
        sessions.removeAll { $0.id == session.id }
        persistSessions()
    }

    private func defaultSessionName() -> String {
        let f = DateFormatter()
        f.dateFormat = "d MMM, HH:mm"
        return "Session \(f.string(from: Date()))"
    }

    // MARK: - Persistence

    private static var sessionsURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Macnizer", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("sessions.json")
    }

    private static func loadSessions() -> [SavedSession] {
        guard let data = try? Data(contentsOf: sessionsURL) else { return [] }
        return (try? JSONDecoder().decode([SavedSession].self, from: data)) ?? []
    }

    private func persistSessions() {
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        try? data.write(to: Self.sessionsURL, options: .atomic)
    }
}
