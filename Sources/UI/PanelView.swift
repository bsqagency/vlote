import SwiftUI

enum PanelTab: String, CaseIterable {
    case windows = "Windows"
    case tabs = "Tabs"
    case sessions = "Sessions"
}

struct PanelView: View {
    @ObservedObject var settings = Settings.shared
    @ObservedObject var store = TabStore.shared

    @State private var tab: PanelTab = .windows
    @State private var windowCount = 0
    @State private var sessionName = ""
    @State private var trusted = AX.isTrusted

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

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
                case .sessions: sessionsPane
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            footer
        }
        .frame(width: 400, height: 560)
        .onAppear { trusted = AX.isTrusted; refreshWindowCount() }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            trusted = AX.isTrusted
        }
        .onChange(of: tab) { _, newTab in
            if newTab == .tabs && store.tabs.isEmpty { store.refresh() }
            if newTab == .windows { refreshWindowCount() }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.grid.3x3.topleft.filled")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(settings.autoTile ? Color.accentColor : .secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text("Macnizer").font(.system(size: 13, weight: .semibold))
                Text(settings.autoTile ? "Arranging automatically" : "Paused")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle("", isOn: $settings.autoTile)
                .toggleStyle(.switch)
                .labelsHidden()
                .onChange(of: settings.autoTile) { _, isOn in
                    if isOn { WindowWatcher.shared.scheduleRetile(delay: 0.05) }
                }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
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
                Text("Macnizer can see your windows but cannot move them.")
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
                        ForEach(LayoutKind.allCases) { kind in
                            layoutButton(kind)
                        }
                    }
                }

                section("Arrange by hand") {
                    Label {
                        Text("Drag any window onto another to split that tile. Drop on the **top or bottom** half for rows, the **left or right** half for columns. Drop again to add a third.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "hand.draw")
                            .foregroundStyle(.secondary)
                    }
                    Toggle(isOn: $settings.snapBack) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Snap windows back").font(.system(size: 11))
                            Text("A window knocked out of place returns to its tile.")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)

                    Button("Back to this layout") { Tiler.shared.applyPreset() }
                        .controlSize(.small)
                }

                section("Spacing") {
                    slider("Between windows", value: $settings.gap, range: 0...32, unit: "pt")
                    slider("Screen edge", value: $settings.outerGap, range: 0...48, unit: "pt")
                    if settings.layout == .masterStack {
                        slider("Main window width", value: $settings.masterRatio,
                               range: 0.3...0.8, unit: "%", isRatio: true, rebuild: true)
                    }
                }

                section("Ignore") {
                    Text("Windows smaller than \(Int(settings.minWindowSize))pt stay where they are.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    slider("Minimum size", value: $settings.minWindowSize, range: 120...500, unit: "pt")

                    if let front = frontmostApp() {
                        Button {
                            settings.toggleFloat(bundleID: front.id)
                            Tiler.shared.retile()
                            refreshWindowCount()
                        } label: {
                            Label(settings.isFloated(bundleID: front.id)
                                  ? "Start arranging \(front.name)"
                                  : "Leave \(front.name) alone",
                                  systemImage: settings.isFloated(bundleID: front.id)
                                  ? "checkmark.square" : "minus.square")
                        }
                        .controlSize(.small)
                    }

                    if !settings.floatedApps.isEmpty {
                        Text("\(settings.floatedApps.count) apps ignored")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(14)
        }
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

    // MARK: - Sessions

    private var sessionsPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                TextField("Name this session", text: $sessionName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                Button("Save") {
                    store.saveSession(named: sessionName)
                    sessionName = ""
                }
                .controlSize(.small)
                .disabled(store.tabs.isEmpty)
            }
            .padding(10)

            if store.sessions.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "tray.full").font(.system(size: 26)).foregroundStyle(.tertiary)
                    Text("Saved sessions let you close everything\nand bring it back later.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
            } else {
                List {
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
                        .padding(.vertical, 2)
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
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

            Spacer()

            Menu {
                Text("Toggle arranging  \(HotkeyManager.toggleAuto.label)")
                Text("Next layout  \(HotkeyManager.cycleLayout.label)")
                Text("Arrange now  \(HotkeyManager.retileNow.label)")
                Divider()
                Button("Reset to layout") { Tiler.shared.resetOrder() }
                Button("Rescan tabs") { store.refresh() }
                Divider()
                Button("Quit Macnizer") { NSApp.terminate(nil) }
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

    private func frontmostApp() -> (id: String, name: String)? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let id = app.bundleIdentifier,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return nil }
        return (id, app.localizedName ?? id)
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

    private func slider(_ label: String,
                        value: Binding<CGFloat>,
                        range: ClosedRange<CGFloat>,
                        unit: String,
                        isRatio: Bool = false,
                        rebuild: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 11)).frame(width: 118, alignment: .leading)
            Slider(value: Binding(
                get: { Double(value.wrappedValue) },
                set: {
                    value.wrappedValue = CGFloat($0)
                    if rebuild { Tiler.shared.applyPreset() } else { Tiler.shared.retile() }
                }
            ), in: Double(range.lowerBound)...Double(range.upperBound))
            Text(isRatio ? "\(Int(value.wrappedValue * 100))\(unit)"
                         : "\(Int(value.wrappedValue))\(unit)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
    }
}
