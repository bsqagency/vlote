import Foundation
import UniformTypeIdentifiers

enum PrefKey {
    static let copyToClipboard = "copyToClipboard"
    static let autoSave = "autoSave"
    static let saveDirectory = "saveDirectory"
    static let imageFormat = "imageFormat"
    static let showThumbnail = "showThumbnail"
    static let thumbnailSeconds = "thumbnailSeconds"
    static let includeCursor = "includeCursor"
    static let windowShadow = "windowShadow"
    static let playSound = "playSound"
    static let keepHistory = "keepHistory"
    static let historyDays = "historyDays"
    static let indexText = "indexText"
    static let autoUpload = "autoUpload"
    static let linkExpiryDays = "linkExpiryDays"
}

enum ImageFormat: String, CaseIterable, Identifiable {
    case png, jpeg
    var id: String { rawValue }
    var fileExtension: String { self == .png ? "png" : "jpg" }
    var utType: UTType { self == .png ? .png : .jpeg }
}

/// Local-only settings. Nothing here is ever transmitted; there is no analytics SDK in the app.
enum Preferences {
    static var defaultSaveDirectory: String { NSString(string: "~/Pictures/Snaple").expandingTildeInPath }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            PrefKey.copyToClipboard: true,
            PrefKey.autoSave: true,
            PrefKey.saveDirectory: defaultSaveDirectory,
            PrefKey.imageFormat: ImageFormat.png.rawValue,
            PrefKey.showThumbnail: true,
            PrefKey.thumbnailSeconds: 8,
            PrefKey.includeCursor: false,
            PrefKey.windowShadow: true,
            PrefKey.playSound: true,
            PrefKey.keepHistory: true,
            PrefKey.historyDays: 30,
            PrefKey.indexText: true,
            PrefKey.autoUpload: false,
            PrefKey.linkExpiryDays: 0,
        ])
    }

    private static var d: UserDefaults { .standard }
    static var copyToClipboard: Bool { d.bool(forKey: PrefKey.copyToClipboard) }
    static var autoSave: Bool { d.bool(forKey: PrefKey.autoSave) }
    static var showThumbnail: Bool { d.bool(forKey: PrefKey.showThumbnail) }
    static var thumbnailSeconds: Double { d.double(forKey: PrefKey.thumbnailSeconds) }
    static var includeCursor: Bool { d.bool(forKey: PrefKey.includeCursor) }
    static var windowShadow: Bool { d.bool(forKey: PrefKey.windowShadow) }
    static var playSound: Bool { d.bool(forKey: PrefKey.playSound) }
    static var keepHistory: Bool { d.bool(forKey: PrefKey.keepHistory) }
    static var historyDays: Int { d.integer(forKey: PrefKey.historyDays) }
    static var indexText: Bool { d.bool(forKey: PrefKey.indexText) }
    /// Off by default: nothing is uploaded unless the user asks, or turns this on.
    static var autoUpload: Bool { d.bool(forKey: PrefKey.autoUpload) }
    /// 0 = links never expire.
    static var linkExpiryDays: Int? { let v = d.integer(forKey: PrefKey.linkExpiryDays); return v > 0 ? v : nil }
    static var imageFormat: ImageFormat { ImageFormat(rawValue: d.string(forKey: PrefKey.imageFormat) ?? "") ?? .png }
    static var saveDirectoryURL: URL {
        URL(fileURLWithPath: d.string(forKey: PrefKey.saveDirectory) ?? defaultSaveDirectory, isDirectory: true)
    }
}
