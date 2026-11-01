import Foundation
import Combine

/// One ignore list for all of vlote. Apps in `ignoredBundleIDs` are never tiled
/// and never recorded by CopyClips. Windows smaller than `minimumWindowSize` are never tiled.
/// Keys are prefixed "ignore." (the old keys are read once, for migration only).
final class UniversalIgnore: ObservableObject {
    static let shared = UniversalIgnore()

    static let idsKey = "ignore.bundleIDs"
    static let minSizeKey = "ignore.minimumWindowSize"
    static let migratedKey = "ignore.migrated"
    static let defaultMinimumWindowSize = 220.0
    static let sizeRange = 200.0...600.0

    private let d: UserDefaults

    @Published var ignoredBundleIDs: Set<String> {
        didSet { d.set(ignoredBundleIDs.sorted(), forKey: Self.idsKey) }
    }
    @Published var minimumWindowSize: Double {
        didSet { d.set(minimumWindowSize, forKey: Self.minSizeKey) }
    }

    init(defaults: UserDefaults = .standard) {
        d = defaults
        if !d.bool(forKey: Self.migratedKey) {
            // Old Organize list (floatedApps, falls back to its default) plus old CopyClips list.
            let organize = d.stringArray(forKey: "floatedApps") ?? Settings.defaultFloated
            let clip = d.stringArray(forKey: "clip.ignoredBundleIDs") ?? []
            let ids = Self.migratedIDs(organize: organize, clip: clip)
            d.set(ids.sorted(), forKey: Self.idsKey)
            if d.object(forKey: "minWindowSize") != nil {
                d.set(d.double(forKey: "minWindowSize"), forKey: Self.minSizeKey)
            }
            d.set(true, forKey: Self.migratedKey)
        }
        ignoredBundleIDs = Set(d.stringArray(forKey: Self.idsKey) ?? [])
        let stored = d.object(forKey: Self.minSizeKey) != nil
            ? d.double(forKey: Self.minSizeKey)
            : Self.defaultMinimumWindowSize
        minimumWindowSize = min(max(stored, Self.sizeRange.lowerBound), Self.sizeRange.upperBound)
    }

    /// Union of the two old lists.
    static func migratedIDs(organize: [String], clip: [String]) -> Set<String> {
        Set(organize).union(clip)
    }

    func isIgnored(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return ignoredBundleIDs.contains(bundleID)
    }

    /// True when either side is below the minimum. Equal to the minimum is allowed.
    func isTooSmall(_ size: CGSize) -> Bool {
        size.width < minimumWindowSize || size.height < minimumWindowSize
    }
}
