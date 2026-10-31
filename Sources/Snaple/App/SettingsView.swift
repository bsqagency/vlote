import AppKit
import SwiftUI

struct SettingsView: View {
    @AppStorage(PrefKey.copyToClipboard) private var copyToClipboard = true
    @AppStorage(PrefKey.autoSave) private var autoSave = true
    @AppStorage(PrefKey.saveDirectory) private var saveDirectory = Preferences.defaultSaveDirectory
    @AppStorage(PrefKey.imageFormat) private var imageFormat = ImageFormat.png.rawValue
    @AppStorage(PrefKey.showThumbnail) private var showThumbnail = true
    @AppStorage(PrefKey.thumbnailSeconds) private var thumbnailSeconds = 8.0
    @AppStorage(PrefKey.includeCursor) private var includeCursor = false
    @AppStorage(PrefKey.windowShadow) private var windowShadow = true
    @AppStorage(PrefKey.playSound) private var playSound = true
    @AppStorage(PrefKey.keepHistory) private var keepHistory = true
    @AppStorage(PrefKey.historyDays) private var historyDays = 30
    @AppStorage(PrefKey.indexText) private var indexText = true
    @AppStorage(PrefKey.autoUpload) private var autoUpload = false
    @AppStorage(PrefKey.linkExpiryDays) private var linkExpiryDays = 0

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            shortcuts.tabItem { Label("Shortcuts", systemImage: "keyboard") }
            cloud.tabItem { Label("Cloud", systemImage: "icloud") }
            privacy.tabItem { Label("Privacy", systemImage: "hand.raised") }
        }
        .frame(width: 520, height: 420)
    }

    private var general: some View {
        Form {
            Section("After capture") {
                Toggle("Copy to clipboard", isOn: $copyToClipboard)
                Toggle("Save to folder", isOn: $autoSave)
                HStack {
                    Text(saveDirectory).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    Spacer()
                    Button("Choose…") { chooseFolder() }
                }
                .disabled(!autoSave)
                Picker("Format", selection: $imageFormat) {
                    ForEach(ImageFormat.allCases) { Text($0.rawValue.uppercased()).tag($0.rawValue) }
                }
                Toggle("Show floating thumbnail", isOn: $showThumbnail)
                Stepper("Dismiss after \(Int(thumbnailSeconds)) s", value: $thumbnailSeconds, in: 2...30)
                    .disabled(!showThumbnail)
            }
            Section("Capture") {
                Toggle("Include mouse cursor", isOn: $includeCursor)
                Toggle("Add shadow to window captures", isOn: $windowShadow)
                Toggle("Play shutter sound", isOn: $playSound)
            }
        }
        .formStyle(.grouped)
    }

    private var shortcuts: some View {
        Form {
            Section("Global shortcuts") {
                ForEach(HotkeyAction.allCases) { HotkeyRow(action: $0) }
            }
            Section {
                HStack {
                    Text("Click a shortcut, then press the new keys. Esc cancels, ⌫ restores the default.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset All") { HotkeyAction.resetAll() }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var cloud: some View {
        Form {
            Section("Account") { CloudSignInView().frame(maxWidth: .infinity, alignment: .leading) }
            Section("Uploading") {
                Toggle("Upload every capture automatically", isOn: $autoUpload)
                Picker("Share links expire", selection: $linkExpiryDays) {
                    Text("Never").tag(0); Text("After 1 day").tag(1); Text("After 7 days").tag(7); Text("After 30 days").tag(30)
                }
                Text("Nothing is uploaded unless you click Upload (or turn on automatic upload). Uploaded images are the final edited version, with redactions baked in. Anyone with a link can view that image until you stop sharing or it expires.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Open Library…") { LibraryWindowController.shared.show() }
            }
        }
        .formStyle(.grouped)
    }

    private var privacy: some View {
        Form {
            Section("History") {
                Toggle("Keep capture history on this Mac", isOn: $keepHistory)
                Toggle("Make text inside screenshots searchable (on-device OCR)", isOn: $indexText)
                Stepper("Delete after \(historyDays) days", value: $historyDays, in: 1...365)
                    .disabled(!keepHistory)
                Text("History keeps each original so edits stay re-openable. Redactions are applied to exported files only — turn history off if you capture sensitive content.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Data") {
                Text("Snaple has no analytics or tracking. It only contacts the network when you sign in to or use Snaple Cloud.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Show History Folder in Finder") { NSWorkspace.shared.activateFileViewerSelecting([CaptureStore.shared.root]) }
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { saveDirectory = url.path }
    }
}
