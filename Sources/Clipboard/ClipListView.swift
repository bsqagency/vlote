import AppKit
import SwiftUI
import Combine

/// Drives the history list: the search text, the visible rows, and the selection.
/// Key handling lives in ClipWindowController; this model only holds state.
final class ClipListModel: ObservableObject {
    @Published var query = "" { didSet { selection = 0 } }
    @Published private(set) var rows: [Clip] = []
    @Published var selection = 0
    /// Bumped each time the panel opens so the search field can take focus.
    @Published var focusToken = UUID()

    private var cancellables = Set<AnyCancellable>()

    init() {
        Publishers.CombineLatest3(ClipStore.shared.$clips, $query, ClipPreferences.shared.$displayCount)
            .receive(on: DispatchQueue.main)   // read the store after its @Published value has been set
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
    }

    private func refresh() {
        let prefs = ClipPreferences.shared
        let limit = max(1, min(prefs.displayCount, prefs.historySize))
        rows = Array(ClipStore.shared.search(query).prefix(limit))
        selection = min(selection, max(rows.count - 1, 0))
    }

    func reset() {
        query = ""
        selection = 0
        focusToken = UUID()
    }

    func move(by delta: Int) {
        guard !rows.isEmpty else { return }
        selection = min(max(selection + delta, 0), rows.count - 1)
    }

    var selectedClip: Clip? { clip(at: selection) }

    func clip(at index: Int) -> Clip? {
        rows.indices.contains(index) ? rows[index] : nil
    }
}

/// Clip history list shown in the floating panel.
struct ClipListView: View {
    @ObservedObject var model: ClipListModel
    var onSelect: (Clip) -> Void

    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()

            if model.rows.isEmpty {
                Spacer()
                Text(model.query.isEmpty ? "No clips yet" : "No matches")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, clip in
                                row(index: index, clip: clip)
                                    .id(clip.id)
                                    .onTapGesture {
                                        model.selection = index
                                        onSelect(clip)
                                    }
                            }
                        }
                        .padding(6)
                    }
                    .onChange(of: model.selection) { _, new in
                        if let id = model.clip(at: new)?.id { proxy.scrollTo(id) }
                    }
                }
            }

            Divider()
            Text("⌘0–9 pick · ⏎ paste · ⇧⏎ plain · ⌘P pin · ⌫ delete · esc")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(0.1)))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onChange(of: model.focusToken) { _, _ in searchFocused = true }
        .onAppear { searchFocused = true }
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search clips", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searchFocused)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Rows

    private func row(index: Int, clip: Clip) -> some View {
        let selected = index == model.selection
        return HStack(spacing: 8) {
            Text(index < 10 ? "\(index)" : "")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(selected ? Color.white.opacity(0.9) : .secondary)
                .frame(width: 16, alignment: .trailing)

            VStack(alignment: .leading, spacing: 2) {
                content(for: clip)
                meta(for: clip, selected: selected)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if clip.pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(selected ? Color.white.opacity(0.9) : .secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(selected ? Color.accentColor : Color.clear)
        )
        .foregroundStyle(selected ? Color.white : Color.primary)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func content(for clip: Clip) -> some View {
        switch clip.kind {
        case .text:
            Text(preview(clip.text ?? ""))
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .image:
            if let file = clip.imageFile, let image = NSImage(contentsOf: file) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("Image")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// One line: newlines and runs of whitespace collapsed to single spaces.
    private func preview(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private func meta(for clip: Clip, selected: Bool) -> some View {
        let time = Self.relative.localizedString(for: clip.date, relativeTo: Date())
        let text = [clip.sourceApp, time].compactMap { $0 }.joined(separator: " · ")
        return Text(text)
            .font(.system(size: 10))
            .foregroundStyle(selected ? Color.white.opacity(0.85) : .secondary)
            .lineLimit(1)
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()
}
