import AppKit
import SwiftUI

/// Old entry point for clipboard preferences. Now opens the unified preferences window on CopyClips.
@MainActor
enum ClipPreferencesWindow {
    static func show() {
        PreferencesWindow.shared.show(page: .copyClips)
    }
}

/// CopyClips preferences page. Sub-tabs sit in the pane content, not in the window bar.
struct ClipPreferencesView: View {
    @State private var tab: ClipTab = .general

    private enum ClipTab: String, CaseIterable, Identifiable {
        case general, management

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general:     return "General"
            case .management:  return "Clips Management"
            }
        }
    }

    var body: some View {
        SettingsPane {
            SettingsSegmented(options: ClipTab.allCases, label: { $0.title }, selection: $tab)
            switch tab {
            case .general:     ClipGeneralTab()
            case .management:  ClipManagementTab()
            }
        }
    }
}

// MARK: - General

private struct ClipGeneralTab: View {
    @ObservedObject private var prefs = ClipPreferences.shared
    @State private var launchAtLogin = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSection("History") {
                SettingsCard {
                    SettingsRow(title: "Remember") {
                        HStack(spacing: 6) {
                            TextField("", value: $prefs.historySize, format: .number)
                                .frame(width: 60)
                                .multilineTextAlignment(.trailing)
                            Stepper("", value: $prefs.historySize, in: 10...1000, step: 10).labelsHidden()
                            Text("clippings").foregroundStyle(.secondary)
                        }
                    }
                    SettingsDivider()
                    SettingsRow(title: "Display") {
                        HStack(spacing: 6) {
                            TextField("", value: displayBinding, format: .number)
                                .frame(width: 60)
                                .multilineTextAlignment(.trailing)
                            Stepper("", value: displayBinding, in: 1...max(1, prefs.historySize)).labelsHidden()
                            Text("clippings").foregroundStyle(.secondary)
                        }
                    }
                    SettingsDivider()
                    SettingsRow(title: "Record clipboard history") {
                        Toggle("Record clipboard history", isOn: $prefs.recordHistory)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                }
            }

            SettingsSection("Options") {
                SettingsCard {
                    SettingsRow(title: "Start Vlote at system startup") {
                        Toggle("Start Vlote at system startup", isOn: Binding(
                            get: { launchAtLogin },
                            set: { setLaunchAtLogin($0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }
                    SettingsDivider()
                    SettingsRow(title: "Paste automatically") {
                        Toggle("Paste automatically", isOn: $prefs.pasteAutomatically)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    SettingsDivider()
                    SettingsRow(title: "Clear history on quit") {
                        Toggle("Clear history on quit", isOn: $prefs.clearOnQuit)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                }
            }
        }
        .onAppear { syncLaunchAtLogin() }
        .onChange(of: prefs.historySize) { _, newSize in
            prefs.historySize = min(max(newSize, 10), 1000)
            prefs.displayCount = ClipPreferences.clampedDisplayCount(prefs.displayCount, historySize: prefs.historySize)
        }
    }

    /// Display can never exceed Remember.
    private var displayBinding: Binding<Int> {
        Binding(
            get: { ClipPreferences.clampedDisplayCount(prefs.displayCount, historySize: prefs.historySize) },
            set: { prefs.displayCount = ClipPreferences.clampedDisplayCount($0, historySize: prefs.historySize) }
        )
    }

    private func syncLaunchAtLogin() {
        launchAtLogin = LoginItem.isEnabled
        prefs.launchAtLogin = launchAtLogin
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            try LoginItem.set(on)
            launchAtLogin = on
        } catch {
            NSLog("vlote: could not change launch at login: \(error)")
            launchAtLogin = false
        }
        prefs.launchAtLogin = launchAtLogin
    }
}

// MARK: - Installed apps

struct ClipInstalledApp: Identifiable {
    let id: String      // bundle identifier
    let name: String
    let url: URL

    /// Scans /Applications, ~/Applications, /System/Applications and /System/Applications/Utilities
    /// for .app bundles that have a bundle identifier. Deduplicated by bundle ID.
    static func scan() -> [ClipInstalledApp] {
        let fm = FileManager.default
        let dirs = [URL(fileURLWithPath: "/Applications"),
                    fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
                    URL(fileURLWithPath: "/System/Applications"),
                    URL(fileURLWithPath: "/System/Applications/Utilities")]
        var seen = Set<String>()
        var apps: [ClipInstalledApp] = []
        for dir in dirs {
            let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for url in items where url.pathExtension == "app" && !url.path.contains("/Contents/") {
                guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier, !seen.contains(id) else { continue }
                let info = bundle.infoDictionary
                let name = (info?["CFBundleName"] as? String)
                    ?? (info?["CFBundleDisplayName"] as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                guard ClipAppFilter.isListable(
                    displayName: name, fileName: url.lastPathComponent,
                    uiElement: info?["LSUIElement"] as? Bool == true,
                    backgroundOnly: info?["LSBackgroundOnly"] as? Bool == true) else { continue }
                seen.insert(id)
                apps.append(ClipInstalledApp(id: id, name: name, url: url))
            }
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

}

// MARK: - Clips Management

private struct ClipManagementTab: View {
    @ObservedObject private var store = ClipStore.shared
    @ObservedObject private var prefs = ClipPreferences.shared
    @State private var selected = Set<UUID>()
    @State private var query = ""

    private var rows: [Clip] { store.search(query) }
    private var allSelected: Bool { !rows.isEmpty && rows.allSatisfy { selected.contains($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSection("Clips") {
                SettingsCard {
                    SettingsRow(title: "Search") {
                        TextField("Search clips", text: $query)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 200)
                    }
                    SettingsDivider()
                    SettingsRow(title: "Confirm before deleting") {
                        Toggle("Confirm before deleting", isOn: $prefs.confirmDelete)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    SettingsDivider()
                    SettingsRow(title: "Selection") {
                        HStack(spacing: 12) {
                            Toggle("Select All", isOn: Binding(
                                get: { allSelected },
                                set: { selected = $0 ? Set(rows.map(\.id)) : [] }
                            ))
                            .toggleStyle(.checkbox)
                            .disabled(rows.isEmpty)

                            Button("Delete Selected", role: .destructive) { confirmDelete() }
                                .disabled(selected.isEmpty)
                        }
                    }
                }
            }

            SettingsSection("History") {
                Table(rows) {
                    TableColumn("") { clip in
                        Toggle("", isOn: Binding(
                            get: { selected.contains(clip.id) },
                            set: { on in
                                if on { selected.insert(clip.id) } else { selected.remove(clip.id) }
                            }
                        ))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                    }
                    .width(30)

                    TableColumn("") { clip in
                        Button {
                            store.togglePin(clip)
                        } label: {
                            Image(systemName: clip.pinned ? "pin.fill" : "pin")
                                .foregroundStyle(clip.pinned ? Color.accentColor : .secondary)
                        }
                        .buttonStyle(.borderless)
                        .help(clip.pinned ? "Unpin" : "Pin")
                    }
                    .width(30)

                    TableColumn("Clip") { clip in
                        preview(clip)
                    }

                    TableColumn("Source") { clip in
                        Text(clip.sourceApp ?? "").foregroundStyle(.secondary)
                    }
                    .width(110)

                    TableColumn("Time") { clip in
                        Text(Self.relative.localizedString(for: clip.date, relativeTo: Date()))
                            .foregroundStyle(.secondary)
                    }
                    .width(90)

                    TableColumn("") { clip in
                        Button {
                            deleteWithConfirm([clip])
                        } label: {
                            Image(systemName: "trash").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Delete")
                    }
                    .width(30)
                }
                .frame(height: 300)
                .clipShape(RoundedRectangle(cornerRadius: SettingsStyle.cornerRadius, style: .continuous))
            }
        }
        .onChange(of: store.clips) { _, clips in
            selected.formIntersection(clips.map(\.id))
        }
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    @ViewBuilder
    private func preview(_ clip: Clip) -> some View {
        switch clip.kind {
        case .text:
            Text(clip.text?.replacingOccurrences(of: "\n", with: " ") ?? "").lineLimit(1)
        case .image:
            if let file = clip.imageFile, let image = NSImage(contentsOf: file) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 24)
            } else {
                Text("Image")
            }
        }
    }

    private func confirmDelete() {
        let clips = store.clips.filter { selected.contains($0.id) }
        guard !clips.isEmpty else { return }
        deleteWithConfirm(clips)
        selected = []
    }

    /// Deletes directly, or asks first when "Confirm before deleting" is on.
    private func deleteWithConfirm(_ clips: [Clip]) {
        guard !clips.isEmpty else { return }
        if prefs.confirmDelete {
            let alert = NSAlert()
            alert.messageText = clips.count == 1
                ? "Are you sure you want to delete this clipping?"
                : "Are you sure you want to delete \(clips.count) selected clippings?"
            alert.informativeText = "This action cannot be undone."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        for clip in clips { store.delete(clip) }
        selected.subtract(clips.map(\.id))
    }
}
