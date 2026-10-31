import AppKit
import Combine

enum LayoutKind: String, CaseIterable, Identifiable {
    case bsp
    case masterStack
    case columns
    case rows
    case grid

    var id: String { rawValue }

    var label: String {
        switch self {
        case .bsp:         return "Split"
        case .masterStack: return "Main + Stack"
        case .columns:     return "Columns"
        case .rows:        return "Rows"
        case .grid:        return "Grid"
        }
    }

    var symbol: String {
        switch self {
        case .bsp:         return "rectangle.split.2x2"
        case .masterStack: return "sidebar.squares.left"
        case .columns:     return "rectangle.split.3x1"
        case .rows:        return "rectangle.split.1x2"
        case .grid:        return "square.grid.2x2"
        }
    }
}

/// UserDefaults-backed preferences. Every mutation republishes so the menu bar
/// UI and the tiler both react without extra plumbing.
final class Settings: ObservableObject {
    static let shared = Settings()

    private let d = UserDefaults.standard

    @Published var autoTile: Bool          { didSet { d.set(autoTile, forKey: "autoTile") } }
    @Published var snapBack: Bool          { didSet { d.set(snapBack, forKey: "snapBack") } }
    @Published var layout: LayoutKind      { didSet { d.set(layout.rawValue, forKey: "layout") } }
    @Published var gap: CGFloat            { didSet { d.set(Double(gap), forKey: "gap") } }
    @Published var outerGap: CGFloat       { didSet { d.set(Double(outerGap), forKey: "outerGap") } }
    @Published var masterRatio: CGFloat    { didSet { d.set(Double(masterRatio), forKey: "masterRatio") } }
    @Published var minWindowSize: CGFloat  { didSet { d.set(Double(minWindowSize), forKey: "minWindowSize") } }
    @Published var floatedApps: [String]   { didSet { d.set(floatedApps, forKey: "floatedApps") } }
    @Published var fullPageSetupDone: Bool { didSet { d.set(fullPageSetupDone, forKey: "fullPageSetupDone") } }

    /// Apps that are worse off tiled: modal-heavy utilities, media players,
    /// anything whose windows are deliberately small. Users can edit this list.
    static let defaultFloated = [
        "com.apple.systempreferences",
        "com.apple.finder",
        "com.apple.ActivityMonitor",
        "com.apple.calculator",
        "com.apple.Stickies",
        "com.apple.QuickTimePlayerX",
        "com.apple.PhotoBooth",
        "com.apple.ScreenSharing",
        "com.apple.Preview",
        "com.apple.iCal",
        "com.colliderli.iina",
        "com.spotify.client",
    ]

    private init() {
        d.register(defaults: [
            "autoTile": true,
            "snapBack": true,
            "layout": LayoutKind.bsp.rawValue,
            "gap": 2.0,
            "outerGap": 2.0,
            "masterRatio": 0.6,
            "minWindowSize": 220.0,
            "floatedApps": Settings.defaultFloated,
            "fullPageSetupDone": false,
        ])
        autoTile      = d.bool(forKey: "autoTile")
        snapBack      = d.bool(forKey: "snapBack")
        layout        = LayoutKind(rawValue: d.string(forKey: "layout") ?? "") ?? .bsp
        gap           = CGFloat(d.double(forKey: "gap"))
        outerGap      = CGFloat(d.double(forKey: "outerGap"))
        masterRatio   = CGFloat(d.double(forKey: "masterRatio"))
        minWindowSize = CGFloat(d.double(forKey: "minWindowSize"))
        floatedApps   = d.stringArray(forKey: "floatedApps") ?? Settings.defaultFloated
        fullPageSetupDone = d.bool(forKey: "fullPageSetupDone")
    }

    func isFloated(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return floatedApps.contains(bundleID)
    }

    func toggleFloat(bundleID: String) {
        if let i = floatedApps.firstIndex(of: bundleID) {
            floatedApps.remove(at: i)
        } else {
            floatedApps.append(bundleID)
        }
    }
}
