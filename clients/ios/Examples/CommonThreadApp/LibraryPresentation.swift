import SwiftUI
import CommonThreadKit

private func sampleAsset(for item: SavedItem) -> String? {
    guard item.client == "sample" else { return nil }
    switch item.id {
    case "sample-reading": return "reading-corner"
    case "sample-lamp": return "sculptural-lamp"
    case "sample-balcony": return "balcony"
    case "sample-ceramics": return "ceramics"
    default: return nil
    }
}

private struct SourceStyle {
    let symbol: String
    let color: Color
    init(_ source: String) {
        switch source.lowercased() {
        case "instagram": symbol = "camera"; color = .pink
        case "pinterest": symbol = "pin"; color = .red
        case "article": symbol = "doc.text"; color = .orange
        case "product": symbol = "bag"; color = .green
        default: symbol = "globe"; color = .blue
        }
    }
}

struct SavedContentCard: View {
    let item: SavedItem
    var compact = false
    var connection: SharedEnvironment?
    private var style: SourceStyle { SourceStyle(item.source) }
    private var domain: String {
        if let host = URL(string: item.originalUrl)?.host { return host }
        return item.hasImage ? "Photo" : item.selectedText.isEmpty ? "File" : "Note"
    }
    var body: some View {
        Group {
            if compact {
                HStack(alignment: .top, spacing: 14) {
                    if let asset = sampleAsset(for: item) {
                        Image(asset).resizable().scaledToFill().frame(width: 64, height: 80)
                            .clipShape(RoundedRectangle(cornerRadius: 15)).accessibilityHidden(true)
                    } else if item.hasImage {
                        FindImage(item: item, connection: connection).frame(width: 64, height: 80).clipShape(RoundedRectangle(cornerRadius: 15))
                    } else { sourceIcon(size: 50) }
                    content
                    Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary).padding(.top, 6)
                }.padding(18)
            } else if let asset = sampleAsset(for: item) {
                VStack(alignment: .leading, spacing: 0) {
                    Image(asset).resizable().aspectRatio(2.0 / 3.0, contentMode: .fit).accessibilityHidden(true)
                    content.padding(16)
                }
            } else if item.hasImage {
                VStack(alignment: .leading, spacing: 0) {
                    FindImage(item: item, connection: connection)
                    content.padding(16)
                }
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    HStack { sourceIcon(size: 52); Spacer(); Image(systemName: "bookmark.fill").font(.caption).foregroundStyle(style.color.opacity(0.55)) }
                    content
                    Text(item.capturedDate, style: .date).font(.caption2).foregroundStyle(.secondary)
                }.padding(18)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(compact ? NativeTheme.surface : style.color.opacity(0.075), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .accessibilityElement(children: .combine)
    }
    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.client == "sample" ? "Sample find" : domain).font(.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
            Text(item.title).font(.headline.bold()).foregroundStyle(.primary).lineLimit(compact ? 2 : 4).multilineTextAlignment(.leading)
            if !item.note.isEmpty {
                Text(item.note).font(.subheadline).foregroundStyle(.secondary).lineLimit(compact ? 2 : 3).multilineTextAlignment(.leading)
            } else if !item.selectedText.isEmpty {
                Text(item.selectedText).font(.subheadline).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func sourceIcon(size: CGFloat) -> some View {
        Image(systemName: style.symbol).font(.title3.weight(.semibold)).foregroundStyle(style.color)
            .frame(width: size, height: size).background(style.color.opacity(0.13), in: RoundedRectangle(cornerRadius: 17))
            .accessibilityHidden(true)
    }
}

struct LibraryEmptyState: View {
    let symbol: String
    let title: String
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Image(systemName: symbol).font(.system(size: 38, weight: .medium)).foregroundStyle(NativeTheme.accent)
                .frame(width: 88, height: 88).background(NativeTheme.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 30))
                .accessibilityHidden(true)
            Text(title).font(.largeTitle.bold()).fixedSize(horizontal: false, vertical: true)
            Text(detail).font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 26)
    }
}

struct SavedContentView: View {
    let item: SavedItem
    let stillSaved: Bool
    var localOnly = false
    var connection: SharedEnvironment? = nil
    var onChanged: () -> Void = {}
    @State private var metadata = LocalFindMetadata()
    @State private var showingEditor = false
    @State private var latestItem: SavedItem?
    private var displayed: SavedItem { latestItem ?? item }
    let onDelete: (String, MutationKey) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsDelete = false
    @State private var deleting = false
    @State private var deleteKey: MutationKey?
    @State private var errorMessage: String?
    @State private var deletionFailed = false
    @State private var updating = false
    private var style: SourceStyle { SourceStyle(item.source) }
    private var originalURL: URL? {
        guard item.client != "sample" else { return nil }
        guard let url = URL(string: item.originalUrl), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
        return url
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 20) {
                    if let asset = sampleAsset(for: item) {
                        Image(asset).resizable().aspectRatio(2.0 / 3.0, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 28)).accessibilityHidden(true)
                        Label("Sample find", systemImage: "bookmark").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    } else if item.hasImage {
                        FindImage(item: item, connection: connection).clipShape(RoundedRectangle(cornerRadius: 28))
                    } else {
                        Image(systemName: style.symbol).font(.system(size: 36, weight: .medium)).foregroundStyle(style.color)
                            .frame(width: 86, height: 86).background(style.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 28))
                            .accessibilityHidden(true)
                    }
                    Text(displayed.title).font(.largeTitle.bold()).fixedSize(horizontal: false, vertical: true)
                    if item.client == "sample" {
                        Text("An example to explore your library. The image is illustrative.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 8) {
                            Text(originalURL?.host ?? (item.hasImage ? "Photo" : item.selectedText.isEmpty ? "File" : "Note")).lineLimit(1)
                            Text("·")
                            Text(item.capturedDate, style: .date)
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                    if let originalURL {
                        Link(destination: originalURL) {
                            HStack { Text("Open original").font(.headline); Spacer(); Image(systemName: "arrow.up.right") }
                                .foregroundStyle(NativeTheme.bg).padding(20).background(Color.primary, in: Capsule())
                        }.accessibilityIdentifier("openOriginal")
                    }
                }
                if !displayed.note.isEmpty { contentSection(item.client == "sample" ? "A little context" : "Why you saved it", text: displayed.note, symbol: "quote.opening") }
                if !displayed.selectedText.isEmpty { contentSection("Saved text", text: displayed.selectedText, symbol: "text.alignleft") }
                if displayed.note.isEmpty && displayed.selectedText.isEmpty {
                    Text("Saved in your library, ready whenever you need it.").font(.body).foregroundStyle(.secondary)
                }
                if localOnly {
                    HStack(spacing: 12) {
                        Button { showingEditor = true } label: { Label("Edit note", systemImage: "square.and.pencil") }
                        Spacer()
                        Button { Task { await toggleFavorite() } } label: {
                            Image(systemName: metadata.isFavorite ? "heart.fill" : "heart")
                        }.accessibilityLabel(metadata.isFavorite ? "Remove favorite" : "Favorite find")
                    }.buttonStyle(.bordered).disabled(deleting || updating)
                    if !metadata.attachments.isEmpty { AttachmentGallery(attachments: metadata.attachments) }
                }
                SavedIntelligenceSection(item: displayed, connection: connection, onChanged: onChanged)
                if let errorMessage {
                    Text(errorMessage).font(.subheadline).foregroundStyle(.red).accessibilityIdentifier("savedFindError")
                    if deletionFailed {
                        Button("Retry removal") { Task { await delete() } }.disabled(deleting || updating)
                    } else {
                        Button("Refresh find") { Task { await reloadLocal() } }.disabled(deleting || updating)
                    }
                }
                if deleting { ProgressView("Removing from your library") }
                if updating { ProgressView("Updating your find") }
            }.padding(24)
        }
        .background(NativeTheme.bg).navigationTitle("Your find").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    if localOnly {
                        Button { showingEditor = true } label: { Label("Edit find or voice note", systemImage: "square.and.pencil") }
                        Button { Task { await toggleFavorite() } } label: { Label(metadata.isFavorite ? "Unfavorite" : "Favorite", systemImage: metadata.isFavorite ? "heart.slash" : "heart") }
                        Button { Task { await toggleArchive() } } label: { Label(metadata.isArchived ? "Move to library" : "Archive", systemImage: "archivebox") }
                    }
                    if !displayed.note.isEmpty { ShareLink(item: displayed.note) { Label("Share note", systemImage: "text.bubble") } }
                    if let originalURL { ShareLink(item: originalURL) { Label("Share original link", systemImage: "square.and.arrow.up") } }
                    Button(role: .destructive) { confirmsDelete = true } label: { Label("Remove from library", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis") }.accessibilityLabel("Saved item options").disabled(deleting || updating)
            }
        }
        .confirmationDialog("Remove this find?", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("Remove from library", role: .destructive) { Task { await delete() } }
            Button("Keep it", role: .cancel) {}
        } message: { Text(localOnly ? "This removes the find and its note from this iPhone." : "This removes the link and its note from your library on all connected devices.") }
        .task { await reloadLocal() }
        .sheet(isPresented: $showingEditor) { EditFindSheet(item: displayed) { onChanged(); Task { await reloadLocal() } } }
        .onChange(of: stillSaved) { _, present in if !present { dismiss() } }
    }
    private func reloadLocal() async {
        guard localOnly else { return }
        errorMessage = nil; deletionFailed = false
        do {
            metadata = try await LocalLibrary.shared.metadata()[item.id] ?? LocalFindMetadata()
            latestItem = try await LocalLibrary.shared.collection().first { $0.id == item.id }
        } catch { errorMessage = error.localizedDescription }
    }
    private func toggleFavorite() async {
        guard !updating, !deleting else { return }
        updating = true; errorMessage = nil; deletionFailed = false
        defer { updating = false }
        do { try await LocalLibrary.shared.setFavorite(item.id, !metadata.isFavorite); metadata.isFavorite.toggle(); FindsHaptics.selection(); onChanged() }
        catch { errorMessage = error.localizedDescription }
    }
    private func toggleArchive() async {
        guard !updating, !deleting else { return }
        updating = true; errorMessage = nil; deletionFailed = false
        defer { updating = false }
        do {
            try await LocalLibrary.shared.setArchived(item.id, !metadata.isArchived)
            metadata.isArchived.toggle(); FindsHaptics.selection(); onChanged(); dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
    private func contentSection(_ title: String, text: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: symbol).font(.headline.bold())
            Text(text).font(.body).lineSpacing(4).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }.padding(22).background(NativeTheme.surface, in: RoundedRectangle(cornerRadius: 26))
    }
    @MainActor private func delete() async {
        guard !deleting, !updating else { return }
        deleting = true; errorMessage = nil; deletionFailed = false; defer { deleting = false }
        let key = deleteKey ?? MutationKey(); deleteKey = key
        do { try await onDelete(item.id, key); dismiss() }
        catch { errorMessage = error.localizedDescription; deletionFailed = true }
    }
}
