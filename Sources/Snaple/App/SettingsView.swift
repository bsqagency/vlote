import AppKit
import SwiftUI

/// Screenshot preferences page. Sub-tabs sit in the pane content, not in the window bar.
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

    @State private var tab: ScreenshotTab = .general

    private enum ScreenshotTab: String, CaseIterable, Identifiable {
        case general, shortcuts, cloud, privacy

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general:   return "General"
            case .shortcuts: return "Shortcuts"
            case .cloud:     return "Cloud"
            case .privacy:   return "Privacy"
            }
        }
    }

    var body: some View {
        SettingsPane {
            SettingsSegmented(options: ScreenshotTab.allCases, label: { $0.title }, selection: $tab)
            switch tab {
            case .general:   generalPage
            case .shortcuts: shortcutsPage
            case .cloud:     cloudPage
            case .privacy:   privacyPage
            }
        }
    }

    // MARK: - General

    private var generalPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSection("After capture") {
                SettingsCard {
                    SettingsRow(title: "Copy to clipboard") {
                        Toggle("Copy to clipboard", isOn: $copyToClipboard)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    SettingsDivider()
                    SettingsRow(title: "Save to folder") {
                        Toggle("Save to folder", isOn: $autoSave)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    SettingsDivider()
                    SettingsRow(title: "Folder") {
                        HStack(spacing: 8) {
                            Text(saveDirectory)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: 240, alignment: .trailing)
                            Button("Choose…") { chooseFolder() }
                        }
                    }
                    .disabled(!autoSave)
                    SettingsDivider()
                    SettingsRow(title: "Format") {
                        Picker("Format", selection: $imageFormat) {
                            ForEach(ImageFormat.allCases) { Text($0.rawValue.uppercased()).tag($0.rawValue) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    SettingsDivider()
                    SettingsRow(title: "Show floating thumbnail") {
                        Toggle("Show floating thumbnail", isOn: $showThumbnail)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    SettingsDivider()
                    SettingsRow(title: "Dismiss after \(Int(thumbnailSeconds)) s") {
                        Stepper("Dismiss after \(Int(thumbnailSeconds)) s", value: $thumbnailSeconds, in: 2...30)
                            .labelsHidden()
                    }
                    .disabled(!showThumbnail)
                }
            }

            SettingsSection("Capture") {
                SettingsCard {
                    SettingsRow(title: "Include mouse cursor") {
                        Toggle("Include mouse cursor", isOn: $includeCursor)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    SettingsDivider()
                    SettingsRow(title: "Add shadow to window captures") {
                        Toggle("Add shadow to window captures", isOn: $windowShadow)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    SettingsDivider()
                    SettingsRow(title: "Play shutter sound") {
                        Toggle("Play shutter sound", isOn: $playSound)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                }
            }
        }
    }

    // MARK: - Shortcuts

    private var shortcutsPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSection("Global shortcuts") {
                SettingsCard {
                    let actions = HotkeyAction.allCases
                    ForEach(actions.indices, id: \.self) { i in
                        if i > 0 { SettingsDivider() }
                        HotkeyRow(action: actions[i])
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                    }
                }
            }

            SettingsSection("Reset") {
                SettingsCard {
                    HStack {
                        Text("Click a shortcut, then press the new keys. Esc cancels, ⌫ restores the default.")
                            .font(.footnote).foregroundStyle(.secondary)
                        Spacer()
                        Button("Reset All") { HotkeyAction.resetAll() }
                    }
                    .padding(14)
                }
            }
        }
    }

    // MARK: - Cloud

    private var cloudPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSection("Account") {
                SettingsCard {
                    CloudSignInView()
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            SettingsSection("Uploading") {
                SettingsCard {
                    SettingsRow(title: "Upload every capture automatically") {
                        Toggle("Upload every capture automatically", isOn: $autoUpload)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    SettingsDivider()
                    SettingsRow(title: "Share links expire") {
                        Picker("Share links expire", selection: $linkExpiryDays) {
                            Text("Never").tag(0)
                            Text("After 1 day").tag(1)
                            Text("After 7 days").tag(7)
                            Text("After 30 days").tag(30)
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    SettingsDivider()
                    note("Nothing is uploaded unless you click Upload (or turn on automatic upload). Uploaded images are the final edited version, with redactions baked in. Anyone with a link can view that image until you stop sharing or it expires.")
                    SettingsDivider()
                    SettingsRow(title: "Library") {
                        Button("Open Library…") { LibraryWindowController.shared.show() }
                    }
                }
            }
        }
    }

    // MARK: - Privacy

    private var privacyPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSection("History") {
                SettingsCard {
                    SettingsRow(title: "Keep capture history on this Mac") {
                        Toggle("Keep capture history on this Mac", isOn: $keepHistory)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    SettingsDivider()
                    SettingsRow(title: "Make text inside screenshots searchable (on-device OCR)") {
                        Toggle("Make text inside screenshots searchable (on-device OCR)", isOn: $indexText)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    SettingsDivider()
                    SettingsRow(title: "Delete after \(historyDays) days") {
                        Stepper("Delete after \(historyDays) days", value: $historyDays, in: 1...365)
                            .labelsHidden()
                    }
                    .disabled(!keepHistory)
                    SettingsDivider()
                    note("History keeps each original so edits stay re-openable. Redactions are applied to exported files only — turn history off if you capture sensitive content.")
                }
            }

            SettingsSection("Data") {
                SettingsCard {
                    note("Snaple has no analytics or tracking. It only contacts the network when you sign in to or use Snaple Cloud.")
                    SettingsDivider()
                    SettingsRow(title: "History folder") {
                        Button("Show History Folder in Finder") { NSWorkspace.shared.activateFileViewerSelecting([CaptureStore.shared.root]) }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { saveDirectory = url.path }
    }
}
