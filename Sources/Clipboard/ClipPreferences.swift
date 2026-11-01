import Foundation
import Combine

/// UserDefaults-backed clipboard history preferences. Keys are prefixed "clip."
/// so they never clash with the window tiler's keys in Settings.
final class ClipPreferences: ObservableObject {
    static let shared = ClipPreferences()

    private let d = UserDefaults.standard

    @Published var historySize: Int          { didSet { d.set(historySize, forKey: "clip.historySize") } }
    @Published var displayCount: Int         { didSet { d.set(displayCount, forKey: "clip.displayCount") } }
    @Published var pasteAutomatically: Bool  { didSet { d.set(pasteAutomatically, forKey: "clip.pasteAutomatically") } }
    @Published var clearOnQuit: Bool         { didSet { d.set(clearOnQuit, forKey: "clip.clearOnQuit") } }
    @Published var launchAtLogin: Bool       { didSet { d.set(launchAtLogin, forKey: "clip.launchAtLogin") } }
    @Published var recordHistory: Bool       { didSet { d.set(recordHistory, forKey: "clip.recordHistory") } }
    @Published var confirmDelete: Bool       { didSet { d.set(confirmDelete, forKey: "clip.confirmDelete") } }

    private init() {
        d.register(defaults: [
            "clip.historySize": 100,
            "clip.displayCount": 20,
            "clip.pasteAutomatically": true,
            "clip.clearOnQuit": false,
            "clip.launchAtLogin": false,
            "clip.recordHistory": true,
            "clip.confirmDelete": true,
        ])
        historySize       = d.integer(forKey: "clip.historySize")
        displayCount      = d.integer(forKey: "clip.displayCount")
        pasteAutomatically = d.bool(forKey: "clip.pasteAutomatically")
        clearOnQuit       = d.bool(forKey: "clip.clearOnQuit")
        launchAtLogin     = d.bool(forKey: "clip.launchAtLogin")
        recordHistory     = d.bool(forKey: "clip.recordHistory")
        confirmDelete     = d.bool(forKey: "clip.confirmDelete")
    }

    /// Display count kept within 1...historySize.
    static func clampedDisplayCount(_ count: Int, historySize: Int) -> Int {
        min(max(1, count), max(1, historySize))
    }
}
