import AppKit
import SwiftUI

extension Notification.Name {
    /// Posted when the preferences window is already open and should switch pages. object: PreferencesPage raw value.
    static let preferencesShowPage = Notification.Name("vlote.preferencesShowPage")
}

enum PreferencesPage: String, CaseIterable, Identifiable {
    case organize, screenshot, copyClips, ignoreApps, general

    var id: String { rawValue }

    var title: String {
        switch self {
        case .organize:   return "Tabs"
        case .screenshot: return "Snaps"
        case .copyClips:  return "Clips"
        case .ignoreApps: return "Ignore Apps"
        case .general:    return "General"
        }
    }

    var symbol: String {
        switch self {
        case .organize:   return "rectangle.split.2x2"
        case .screenshot: return "camera.viewfinder"
        case .copyClips:  return "doc.on.clipboard"
        case .ignoreApps: return "eye.slash"
        case .general:    return "gearshape"
        }
    }
}

/// One preferences window for all of vlote. Singleton so other places can open it on a given page.
@MainActor
final class PreferencesWindow: NSObject, NSWindowDelegate {
    static let shared = PreferencesWindow()

    /// UserDefaults key for the page shown last time.
    static let lastPageKey = "vlote.preferencesLastPage"

    private var window: NSWindow?

    /// Opens the window on `page`, or on the page shown last time when `page` is nil.
    func show(page: PreferencesPage? = nil) {
        let defaults = UserDefaults.standard
        let target = page
            ?? PreferencesPage(rawValue: defaults.string(forKey: Self.lastPageKey) ?? "")
            ?? .organize
        defaults.set(target.rawValue, forKey: Self.lastPageKey)

        if let w = window {
            NotificationCenter.default.post(name: .preferencesShowPage, object: target.rawValue)
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let size = NSSize(width: SettingsStyle.windowWidth, height: SettingsStyle.windowHeight)
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Vlote Preferences"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.toolbar = nil
        w.contentView = NSHostingView(rootView: PreferencesRootView())
        w.setContentSize(size)
        w.contentMinSize = size
        w.contentMaxSize = size
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        window = w
        ActivationPolicy.windowOpened()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        ActivationPolicy.windowClosed()
    }
}

struct PreferencesRootView: View {
    @AppStorage(PreferencesWindow.lastPageKey) private var storedPage = PreferencesPage.organize.rawValue

    private var page: Binding<PreferencesPage> {
        Binding(
            get: { PreferencesPage(rawValue: storedPage) ?? .organize },
            set: { storedPage = $0.rawValue }
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(page: page)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: SettingsStyle.windowWidth, height: SettingsStyle.windowHeight)
        .background(Color(nsColor: .windowBackgroundColor))
        .onReceive(NotificationCenter.default.publisher(for: .preferencesShowPage)) { note in
            if let raw = note.object as? String, let p = PreferencesPage(rawValue: raw) { storedPage = p.rawValue }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch page.wrappedValue {
        case .organize:   OrganizePreferencesPane()
        case .screenshot: SettingsView()
        case .copyClips:  ClipPreferencesView()
        case .ignoreApps: IgnoreAppsPreferencesPane()
        case .general:    GeneralPreferencesPane()
        }
    }
}

// MARK: - Organize (moved from the panel's Windows page)

private struct OrganizePreferencesPane: View {
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        SettingsPane {
            SettingsSection("Arrange by hand") {
                SettingsCard {
                    SettingsRow(title: "Snap windows back",
                                subtitle: "A window knocked out of place returns to its tile.") {
                        Toggle("Snap windows back", isOn: $settings.snapBack)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    SettingsDivider()
                    SettingsRow(title: "Back to this layout") {
                        Button("Back to this layout") { Tiler.shared.applyPreset() }
                    }
                }
            }

            SettingsSection("Spacing") {
                SettingsCard {
                    slider("Between windows", value: $settings.gap, range: 0...32)
                    SettingsDivider()
                    slider("Screen edge", value: $settings.outerGap, range: 0...48)
                    if settings.layout == .masterStack {
                        SettingsDivider()
                        slider("Main window width", value: $settings.masterRatio, range: 0.3...0.8, isRatio: true, rebuild: true)
                    }
                }
            }
        }
    }

    private func slider(_ label: String, value: Binding<CGFloat>, range: ClosedRange<CGFloat>,
                        isRatio: Bool = false, rebuild: Bool = false) -> some View {
        SettingsRow(title: label) {
            HStack(spacing: 8) {
                Slider(value: Binding(
                    get: { Double(value.wrappedValue) },
                    set: {
                        value.wrappedValue = CGFloat($0)
                        if rebuild { Tiler.shared.applyPreset() } else { Tiler.shared.retile() }
                    }
                ), in: Double(range.lowerBound)...Double(range.upperBound))
                .frame(width: 200)
                Text(isRatio ? "\(Int(value.wrappedValue * 100))%" : "\(Int(value.wrappedValue))pt")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
        }
    }
}

// MARK: - Ignore Apps (one list for tiling and CopyClips)

private struct IgnoreAppsPreferencesPane: View {
    @ObservedObject private var ignore = UniversalIgnore.shared
    @State private var apps: [ClipInstalledApp] = []
    @State private var query = ""

    private var shown: [ClipInstalledApp] {
        query.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        SettingsPane {
            SettingsSection("Minimum size") {
                SettingsCard {
                    SettingsRow(title: "Minimum window size") {
                        HStack(spacing: 8) {
                            Slider(value: $ignore.minimumWindowSize,
                                   in: UniversalIgnore.sizeRange,
                                   onEditingChanged: { editing in
                                       if !editing { Tiler.shared.retile() }
                                   })
                                .frame(width: 200)
                            Text("\(Int(ignore.minimumWindowSize))pt")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                    SettingsDivider()
                    Text("Windows smaller than this are never tiled.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            SettingsSection("Apps") {
                TextField("Search apps", text: $query)
                    .textFieldStyle(.roundedBorder)
                SettingsCard {
                    ForEach(shown.indices, id: \.self) { i in
                        if i > 0 { SettingsDivider() }
                        appRow(shown[i])
                    }
                    if shown.isEmpty {
                        SettingsRow(title: query.isEmpty ? "No apps found." : "No matching apps.") { EmptyView() }
                    }
                }
            }
        }
        .onAppear { apps = ClipInstalledApp.scan() }
    }

    private func appRow(_ app: ClipInstalledApp) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                .resizable()
                .frame(width: 20, height: 20)
            Toggle(app.name, isOn: Binding(
                get: { ignore.ignoredBundleIDs.contains(app.id) },
                set: { on in
                    if on { ignore.ignoredBundleIDs.insert(app.id) } else { ignore.ignoredBundleIDs.remove(app.id) }
                    Tiler.shared.retile()
                }
            ))
            .toggleStyle(.checkbox)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: SettingsStyle.rowHeight, alignment: .leading)
    }
}

// MARK: - General

private struct GeneralPreferencesPane: View {
    @State private var launchAtLogin = LoginItem.isEnabled

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "–"
        let build = info?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? short : "\(short) (\(build))"
    }

    var body: some View {
        SettingsPane {
            SettingsSection("Startup") {
                SettingsCard {
                    SettingsRow(title: "Open at Login") {
                        Toggle("Open at Login", isOn: Binding(
                            get: { launchAtLogin },
                            set: { on in
                                do {
                                    try LoginItem.set(on)
                                } catch {
                                    NSLog("vlote: could not change launch at login: \(error)")
                                }
                                launchAtLogin = LoginItem.isEnabled
                            }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }
                }
            }

            SettingsSection("About") {
                SettingsCard {
                    SettingsRow(title: "Name") {
                        Text("Vlote").foregroundStyle(.secondary)
                    }
                    SettingsDivider()
                    SettingsRow(title: "Version") {
                        Text(version).foregroundStyle(.secondary)
                    }
                    SettingsDivider()
                    Text("Arranges your windows, takes screenshots, and keeps a clipboard history. Everything runs from the menu bar.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}
