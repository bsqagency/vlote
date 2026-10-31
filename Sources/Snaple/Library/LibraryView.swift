import AppKit
import SwiftUI

struct LibraryView: View {
    @ObservedObject var model: LibraryModel
    @ObservedObject private var session = CloudSession.shared
    @State private var renaming: LibraryItem?
    @State private var renameText = ""
    @State private var deleting: LibraryItem?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.visible.isEmpty { empty } else { grid }
            if let error = model.error {
                Divider()
                Text(error).font(.footnote).foregroundStyle(.orange).padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 760, minHeight: 480)
        .task { await model.refresh() }
        .sheet(isPresented: $model.showSignIn) {
            CloudSignInView { model.showSignIn = false; Task { await model.refresh() } }
                .padding(24).frame(width: 400)
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") { if let item = renaming { Task { await model.rename(item, to: renameText) } }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .confirmationDialog("Delete “\(deleting?.name ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { item in
            if item.isLocal && item.isCloud {
                Button("Delete from This Mac", role: .destructive) { Task { await model.delete(item, scope: .mac) } }
                Button("Delete from Cloud (links stop working)", role: .destructive) { Task { await model.delete(item, scope: .cloud) } }
                Button("Delete Everywhere", role: .destructive) { Task { await model.delete(item, scope: .everywhere) } }
            } else if item.isCloud {
                Button("Delete from Cloud (links stop working)", role: .destructive) { Task { await model.delete(item, scope: .cloud) } }
            } else {
                Button("Delete from This Mac", role: .destructive) { Task { await model.delete(item, scope: .mac) } }
            }
        } message: { _ in Text("This can't be undone.") }
    }

    private var header: some View {
        HStack(spacing: 12) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search names and text inside screenshots", text: $model.query).textFieldStyle(.plain)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            Picker("", selection: $model.filter) { ForEach(LibraryModel.Filter.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).frame(width: 220).labelsHidden()
            Spacer(minLength: 0)
            if session.isSignedIn {
                Text(ByteCountFormatter.string(fromByteCount: model.cloudBytes, countStyle: .file) + " in cloud")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .help("Refresh").disabled(model.loading)
            Button { model.showSignIn = true } label: {
                Label(session.email ?? "Sign In", systemImage: session.isSignedIn ? "person.crop.circle.fill" : "person.crop.circle")
            }
        }
        .padding(12)
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: model.loading ? "hourglass" : "photo.on.rectangle.angled").font(.system(size: 40)).foregroundStyle(.tertiary)
            Text(model.loading ? "Loading…" : (model.query.isEmpty ? "No captures yet" : "No matches")).font(.headline)
            if !model.loading && model.query.isEmpty {
                Text("Press ⌃⌘4 to capture an area.").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 16)], spacing: 16) {
                ForEach(model.visible) { item in
                    LibraryCell(item: item)
                        .onTapGesture(count: 2) { Task { await model.open(item) } }
                        .contextMenu { menu(for: item) }
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder private func menu(for item: LibraryItem) -> some View {
        Button("Open in Editor") { Task { await model.open(item) } }
        Button("Copy Image") { Task { await model.copyImage(item) } }
        if item.isLocal { Button("Show in Finder") { model.showInFinder(item) } }
        Divider()
        if item.shareURL != nil {
            Button("Copy Link") { model.copyLink(item) }
            Button("Stop Sharing") { Task { await model.unshare(item) } }
        } else if session.isSignedIn {
            Menu("Create Share Link") {
                Button("Never expires") { Task { await model.share(item, days: nil) } }
                Button("Expires in 1 day") { Task { await model.share(item, days: 1) } }
                Button("Expires in 7 days") { Task { await model.share(item, days: 7) } }
                Button("Expires in 30 days") { Task { await model.share(item, days: 30) } }
            }
        }
        if !item.isCloud && session.isSignedIn { Button("Upload to Cloud") { Task { await model.upload(item) } } }
        if !session.isSignedIn { Button("Sign In to Share…") { model.showSignIn = true } }
        Divider()
        Button("Rename…") { renameText = item.name; renaming = item }
        Button("Delete…", role: .destructive) { deleting = item }
    }
}

struct LibraryCell: View {
    let item: LibraryItem
    @State private var image: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 6)).padding(4)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(height: 130)
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 4) {
                    if item.isLocal { badge("internaldrive") }
                    if item.isCloud { badge("icloud.fill") }
                    if item.shareURL != nil { badge("link") }
                }.padding(6)
            }
            Text(item.name).font(.callout).lineLimit(1)
            Text("\(item.width) × \(item.height) · \(item.createdAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.name), \(item.width) by \(item.height)")
        .task(id: item.id) { image = await loadThumbnail() }
    }

    private func badge(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 9, weight: .semibold)).padding(4)
            .background(.regularMaterial, in: Circle())
    }

    private func loadThumbnail() async -> NSImage? {
        if item.isLocal {
            let id = item.id
            let cg = await Task.detached(priority: .userInitiated) { CaptureStore.shared.thumbnail(for: id) }.value
            if let cg { return NSImage(cgImage: cg, size: NSSize(width: cg.width / 2, height: cg.height / 2)) }
        }
        if let path = item.cloud?.thumbPath, let data = try? await CloudAPI.shared.download(path: path) { return NSImage(data: data) }
        return nil
    }
}
