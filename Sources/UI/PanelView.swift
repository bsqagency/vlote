import SwiftUI

enum PanelPage {
    case home, organize, screenshot, clipboard
}

enum PanelTab: String, CaseIterable {
    case windows = "Windows"
    case tabs = "Tabs"
}

struct PanelView: View {
    @ObservedObject var settings = Settings.shared
    @ObservedObject var store = TabStore.shared
    @ObservedObject var clipStore = ClipStore.shared
    @ObservedObject var clipPrefs = ClipPreferences.shared

    @State private var page: PanelPage = .home
    @State private var tab: PanelTab = .windows
    @State private var windowCount = 0
    @State private var sessionName = ""
    @State private var trusted = AX.isTrusted

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            Group {
                switch page {
                case .home:       homePage
                case .organize:   organizePage
                case .screenshot: capturePane
                case .clipboard:  clipboardPane
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            footer
        }
        .frame(width: 400, height: 560)
        .onAppear {
            page = .home
            trusted = AX.isTrusted
            refreshWindowCount()
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            trusted = AX.isTrusted
        }
        .onChange(of: page) { _, newPage in
            if newPage == .organize { refreshWindowCount() }
        }
        .onChange(of: tab) { _, newTab in
            if newTab == .tabs && store.tabs.isEmpty { store.refresh() }
            if newTab == .windows { refreshWindowCount() }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            if page == .home {
                Image(systemName: "square.grid.3x3.topleft.filled")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("Vlote").font(.system(size: 13, weight: .semibold))
                Spacer()
            } else {
                Button { page = .home } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)

                if page == .organize {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Tabs").font(.system(size: 13, weight: .semibold))
                        Text(settings.autoTile ? "Arranging automatically" : "Paused")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(pageTitle).font(.system(size: 13, weight: .semibold))
                }

                Spacer()

                if page == .organize {
                    Toggle("", isOn: $settings.autoTile)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .onChange(of: settings.autoTile) { _, isOn in
                            if isOn { WindowWatcher.shared.scheduleRetile(delay: 0.05) }
                        }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var pageTitle: String {
        switch page {
        case .home: return "Vlote"
        case .organize: return "Tabs"
        case .screenshot: return "Snaps"
        case .clipboard: return "Clips"
        }
    }

    // MARK: - Home

    private var homePage: some View {
        VStack(spacing: 10) {
            HomeCard(symbol: "square.grid.3x3.topleft.filled", title: "Tabs",
                     subtitle: "Arrange windows, tabs and sessions") { page = .organize }
            HomeCard(symbol: "camera.viewfinder", title: "Snaps",
                     subtitle: "Capture, edit and save") { page = .screenshot }
            HomeCard(symbol: "doc.on.clipboard", title: "Clips",
                     subtitle: "Your clipboard history") { page = .clipboard }
            HomeCard(symbol: "gearshape", title: "Vlote Preferences…",
                     subtitle: "Settings for every part of Vlote") { PreferencesWindow.shared.show() }
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Organize

    private var organizePage: some View {
        VStack(spacing: 0) {
            if !trusted { permissionBanner }

            Picker("", selection: $tab) {
                ForEach(PanelTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)

            Divider()

            Group {
                switch tab {
                case .windows:  windowsPane
                case .tabs:     tabsPane
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Shown whenever Accessibility access is missing. Without it Macnizer can
    /// see windows but cannot move any of them, so it would otherwise appear to
    /// be running perfectly while doing nothing at all.
    private var permissionBanner: some View {
        HStack(spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 13))

            VStack(alignment: .leading, spacing: 1) {
                Text("Not arranging — needs Accessibility access")
                    .font(.system(size: 11, weight: .medium))
                Text("Vlote can see your windows but cannot move them.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            Button("Open Settings") {
                AX.requestTrust()
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.orange.opacity(0.14))
    }

    // MARK: - Windows

    private var windowsPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {

                section("Layout") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
                              spacing: 8) {
                        ForEach(LayoutKind.primary) { kind in
                            layoutButton(kind)
                        }
                        moreLayoutsMenu
                    }
                    Text("Drag a window onto another to split it.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Button("Back to this layout") { Tiler.shared.applyPreset() }
                        .controlSize(.small)
                }
                .help("Gaps and screen edge: Tabs Preferences")
            }
            .padding(14)
        }
    }

    private var moreLayoutsMenu: some View {
        let selected = LayoutKind.more.contains(settings.layout)
        return Menu {
            ForEach(LayoutKind.more) { kind in
                Button(kind.label) {
                    settings.layout = kind
                    Tiler.shared.applyPreset()
                }
            }
        } label: {
            VStack(spacing: 5) {
                Image(systemName: selected ? settings.layout.symbol : "ellipsis").font(.system(size: 17, weight: .regular))
                Text(selected ? settings.layout.label : "More").font(.system(size: 10)).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(selected ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 1.5)
            )
            .foregroundStyle(selected ? Color.accentColor : .primary)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func layoutButton(_ kind: LayoutKind) -> some View {
        let selected = settings.layout == kind
        return Button {
            settings.layout = kind
            Tiler.shared.applyPreset()
        } label: {
            VStack(spacing: 5) {
                Image(systemName: kind.symbol).font(.system(size: 17, weight: .regular))
                Text(kind.label).font(.system(size: 10)).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(selected ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 1.5)
            )
            .foregroundStyle(selected ? Color.accentColor : .primary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Tabs

    private var tabsPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("Search \(store.tabs.count) tabs", text: $store.search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !store.search.isEmpty {
                    Button { store.search = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
            .padding(10)

            sessionsSection
                .padding(.horizontal, 10)
                .padding(.bottom, 6)

            if !store.duplicateGroups.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "doc.on.doc").font(.system(size: 11))
                    Text("\(store.redundantTabs.count) duplicate tabs")
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                    Button("Close them") { store.closeDuplicates() }
                        .controlSize(.small)
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Color.orange.opacity(0.12))
            }

            if store.tabs.isEmpty && !store.isLoading {
                emptyState
            } else {
                List {
                    ForEach(store.filtered) { tab in
                        tabRow(tab)
                    }
                }
                .listStyle(.inset)
                .environment(\.defaultMinListRowHeight, 34)
            }
        }
    }

    private func tabRow(_ tab: TabRef) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(tab.title.isEmpty ? tab.url : tab.title)
                    .font(.system(size: 12)).lineLimit(1)
                Text("\(tab.host) · \(tab.browserName)")
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Button { store.close([tab]) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "safari").font(.system(size: 26)).foregroundStyle(.tertiary)
            Text(store.lastError ?? "No open tabs found")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button("Scan browsers") { store.refresh() }.controlSize(.small)
            Spacer()
        }
    }

    // MARK: - Sessions (inside Tabs)

    private var sessionsSection: some View {
        DisclosureGroup("Sessions (\(store.sessions.count))") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    TextField("Name this session", text: $sessionName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                    Button("Save Tabs") {
                        store.saveSession(named: sessionName)
                        sessionName = ""
                    }
                    .controlSize(.small)
                    .disabled(store.tabs.isEmpty)
                }

                ForEach(store.sessions) { session in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(session.name).font(.system(size: 12)).lineLimit(1)
                            Text("\(session.urls.count) tabs · \(session.createdAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        Button("Open") { store.restore(session) }.controlSize(.small)
                        Button { store.delete(session) } label: {
                            Image(systemName: "trash").font(.system(size: 10))
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.top, 4)
        }
        .font(.system(size: 12, weight: .medium))
    }

    // MARK: - Capture

    private var capturePane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section("Snaps") {
                    ForEach([HotkeyAction.area, .window, .fullscreen, .repeatLast, .ocr, .qr]) { action in
                        captureRow(action.title, symbol: captureSymbol(action), shortcut: action.hotkey.displayString) {
                            NotificationCenter.default.post(name: .snapleAction, object: nil,
                                                            userInfo: ["action": action.rawValue])
                        }
                    }
                    captureRow("Full Page", symbol: "arrow.up.and.down.text.horizontal",
                               shortcut: FullPageController.shortcutLabel) {
                        FullPageController.shared.start(fromPanel: true)
                    }
                }

                section("Library & settings") {
                    captureRow("Library…", symbol: "photo.on.rectangle", shortcut: nil) {
                        NotificationCenter.default.post(name: .openSnapleLibrary, object: nil)
                    }
                    captureRow("Snaps Preferences…", symbol: "gearshape", shortcut: nil) {
                        PreferencesWindow.shared.show(page: .screenshot)
                    }
                }
            }
            .padding(14)
        }
    }

    // MARK: - Clipboard

    private var clipboardPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section("History") {
                    captureRow("Clipboard History", symbol: "doc.on.clipboard",
                               shortcut: HotkeyManager.clipboard.label) {
                        ClipWindowController.shared.toggle(fromStatusItem: true)
                    }
                    captureRow("Delete All History", symbol: "trash", shortcut: nil) {
                        ClipStore.shared.confirmDeleteAll()
                    }
                    Text("\(clipStore.clips.count) clippings saved")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }

                section("Recording") {
                    Toggle(isOn: $clipPrefs.recordHistory) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Record clipboard history").font(.system(size: 11))
                            Text("Copies made while off are not saved.")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                }

                section("Settings") {
                    captureRow("Clips Preferences…", symbol: "gearshape", shortcut: nil) {
                        PreferencesWindow.shared.show(page: .copyClips)
                    }
                }
            }
            .padding(14)
        }
    }

    private struct HomeCard: View {
        let symbol: String
        let title: String
        let subtitle: String
        let action: () -> Void
        @State private var hovered = false

        var body: some View {
            Button(action: action) {
                HStack(spacing: 12) {
                    Image(systemName: symbol)
                        .font(.system(size: 22))
                        .frame(width: 36)
                        .foregroundStyle(hovered ? Color.accentColor : .secondary)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.system(size: 14, weight: .bold))
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 4)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14).padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(.regularMaterial))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(hovered ? Color.accentColor : .clear, lineWidth: 1.5)
                )
                .contentShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
        }
    }

    private func captureRow(_ title: String, symbol: String, shortcut: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 13))
                    .frame(width: 18)
                    .foregroundStyle(.secondary)
                Text(title).font(.system(size: 12))
                Spacer(minLength: 4)
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.07)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func captureSymbol(_ action: HotkeyAction) -> String {
        switch action {
        case .area: return "rectangle.dashed"
        case .window: return "macwindow"
        case .fullscreen: return "rectangle.inset.filled"
        case .repeatLast: return "arrow.counterclockwise"
        case .ocr: return "text.viewfinder"
        case .qr: return "qrcode.viewfinder"
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if page == .organize {
                Button {
                    Tiler.shared.retile()
                    refreshWindowCount()
                } label: {
                    Label("Arrange now", systemImage: "arrow.triangle.2.circlepath")
                }
                .controlSize(.small)

                Text(tab == .tabs
                     ? "\(store.tabs.count) tabs"
                     : (trusted ? "\(windowCount) windows" : "no access"))
                    .font(.system(size: 11))
                    .foregroundStyle(trusted ? Color.secondary : Color.orange)
            }

            Spacer()

            Menu {
                Text("Arrange now  \(HotkeyManager.retileNow.label)")
                Text("Double-tap Tab  arrange now")
                Divider()
                Button("Reset to layout") { Tiler.shared.resetOrder() }
                Button("Rescan tabs") { store.refresh() }
                Divider()
                Button("Quit Vlote") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 22)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    // MARK: - Helpers

    private func refreshWindowCount() {
        windowCount = WindowManager.tileableWindows().count
    }

    @ViewBuilder
    private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }
}
