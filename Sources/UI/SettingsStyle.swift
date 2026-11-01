import AppKit
import SwiftUI

/// Shared look for every vlote preferences page: one window size, one sidebar, one pane, card and row style.
enum SettingsStyle {
    static let windowWidth: CGFloat = 760
    static let windowHeight: CGFloat = 560
    static let sidebarWidth: CGFloat = 170
    static let sidebarRowHeight: CGFloat = 28
    static let padding: CGFloat = 24
    static let cornerRadius: CGFloat = 10
    static let rowHeight: CGFloat = 40
    static let segmentedWidth: CGFloat = 420
    /// Light grey card fill, the same tone as the General pane.
    static let cardFill = Color.primary.opacity(0.05)
    static let hairline = Color.primary.opacity(0.1)
}

// MARK: - Sidebar

/// The one sidebar for all preference pages. Same row height and selection everywhere.
struct SettingsSidebar: View {
    @Binding var page: PreferencesPage

    var body: some View {
        List(PreferencesPage.allCases, selection: Binding<PreferencesPage?>(
            get: { page },
            set: { if let new = $0 { page = new } }
        )) { p in
            Label(p.title, systemImage: p.symbol)
                .frame(maxWidth: .infinity, minHeight: SettingsStyle.sidebarRowHeight, alignment: .leading)
                .tag(p)
        }
        .listStyle(.sidebar)
        .frame(width: SettingsStyle.sidebarWidth)
    }
}

// MARK: - Pane

/// Scrollable page container with the shared padding. Put SettingsSection blocks inside.
struct SettingsPane<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                content
            }
            .padding(SettingsStyle.padding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Bold section title above a SettingsCard.
struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .fontWeight(.bold)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Card and row

/// Rounded grey card. Put SettingsRow items in it, with SettingsDivider() between them.
struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: SettingsStyle.cornerRadius, style: .continuous)
                .fill(SettingsStyle.cardFill)
        )
        .clipShape(RoundedRectangle(cornerRadius: SettingsStyle.cornerRadius, style: .continuous))
    }
}

/// Hairline between rows inside a SettingsCard.
struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(SettingsStyle.hairline)
            .frame(height: 1)
            .padding(.leading, 14)
    }
}

/// One row: title, optional subtitle, trailing control. 40 pt minimum height.
struct SettingsRow<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: Trailing

    init(title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: SettingsStyle.rowHeight, alignment: .leading)
    }
}

// MARK: - Sub-tabs

/// Segmented control used for sub-tabs. Same size and position on every page that uses it.
struct SettingsSegmented<Option: Hashable>: View {
    let options: [Option]
    let label: (Option) -> String
    @Binding var selection: Option

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(options, id: \.self) { option in
                Text(label(option)).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: SettingsStyle.segmentedWidth)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
