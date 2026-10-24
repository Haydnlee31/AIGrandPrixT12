import SwiftUI
import CommonThreadKit

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
    var pinned = false
    var insight: String? = nil
    var mergedSaveCount = 1
    private var style: SourceStyle { SourceStyle(item.source) }
    private var originalURL: URL? {
        guard let url = URL(string: item.originalUrl), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
        return url
    }
    private var domain: String {
        if let host = originalURL?.host { return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host }
        return item.hasImage ? "Photo" : item.selectedText.isEmpty ? "File" : "Note"
    }
    var body: some View {
        Group {
            if compact {
                HStack(spacing: 14) {
                    thumbnail.frame(width: 68, height: 76).clipShape(RoundedRectangle(cornerRadius: 16))
                    content
                }.padding(14)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    if item.hasImage {
                        FindImage(item: item, connection: connection).clipShape(RoundedRectangle(cornerRadius: 22))
                    } else if let originalURL {
                        WebsitePreview(url: originalURL).clipShape(RoundedRectangle(cornerRadius: 22))
                    } else { sourceIcon.frame(maxWidth: .infinity).frame(height: 82) }
                    content.padding(14)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NativeTheme.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .accessibilityElement(children: .combine)
    }
    @ViewBuilder private var thumbnail: some View {
        if item.hasImage { FindImage(item: item, connection: connection) }
        else if let originalURL { WebsitePreview(url: originalURL, presentation: .thumbnail) }
        else { sourceIcon }
    }
    private var content: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(item.title).font(.headline.bold()).foregroundStyle(.primary).lineLimit(2).multilineTextAlignment(.leading)
            if let insight, !insight.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Label(insight, systemImage: "sparkles")
                    .font(.caption.weight(.medium)).foregroundStyle(.purple)
                    .lineLimit(compact ? 1 : 2).multilineTextAlignment(.leading)
            }
            HStack(spacing: 5) {
                Image(systemName: originalURL == nil ? (item.hasImage ? "photo" : "text.alignleft") : style.symbol)
                    .foregroundStyle(style.color)
                Text(item.client == "sample" ? "Sample find" : domain).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                if mergedSaveCount > 1 {
                    Label("\(mergedSaveCount)", systemImage: "square.on.square")
                        .foregroundStyle(.secondary).accessibilityLabel("\(mergedSaveCount) saves combined")
                }
                if pinned { Image(systemName: "pin.fill").foregroundStyle(.orange).accessibilityLabel("Pinned") }
            }.font(.caption)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var sourceIcon: some View {
        Image(systemName: originalURL == nil ? (item.selectedText.isEmpty ? "doc.fill" : "text.alignleft") : style.symbol)
            .font(.system(size: 25, weight: .medium)).foregroundStyle(style.color)
            .frame(width: 52, height: 52).background(style.color.opacity(0.09), in: RoundedRectangle(cornerRadius: 17))
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
    @State private var showingAttachments = false
    @State private var websiteHasImage = false
    @State private var questionFocusToken: UUID?
    @State private var refinement: IntentRefinementContext?
    #if DEBUG
    @State private var didShowDebugRefinement = false
    #endif
    @State private var latestItem: SavedItem?
    private var displayed: SavedItem { latestItem ?? item }
    let onDelete: (String, MutationKey) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .subheadline) private var questionSpace: CGFloat = 146
    @State private var confirmsDelete = false
    @State private var deleting = false
    @State private var deleteKey: MutationKey?
    @State private var errorMessage: String?
    @State private var deletionFailed = false
    @State private var updating = false
    private var style: SourceStyle { SourceStyle(item.source) }
    private var originalURL: URL? {
        guard displayed.client != "sample" else { return nil }
        guard let url = URL(string: displayed.originalUrl), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
        return url
    }
    private var hasImageQuestion: Bool {
        localOnly && (displayed.hasImage || websiteHasImage) && !(metadata.analysis?.prompts.isEmpty ?? true)
    }
    private var reservedQuestionSpace: CGFloat { hasImageQuestion && !dynamicTypeSize.isAccessibilitySize ? questionSpace : 0 }
    var body: some View {
        ScrollViewReader { scroll in
          ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 18) {
                    if displayed.hasImage || originalURL != nil {
                        hero
                            .overlay(alignment: .bottom) {
                                if hasImageQuestion, !dynamicTypeSize.isAccessibilitySize {
                                    imageQuestion(scroll: scroll).padding(12)
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 28))
                        if hasImageQuestion, dynamicTypeSize.isAccessibilitySize {
                            imageQuestion(scroll: scroll)
                        }
                    }
                    Text(displayed.title).font(.title.bold()).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 7) {
                        Image(systemName: originalURL == nil ? (displayed.hasImage ? "photo" : "text.alignleft") : style.symbol)
                            .foregroundStyle(style.color)
                        Text(originalURL?.host?.replacingOccurrences(of: "www.", with: "") ?? (displayed.hasImage ? "Photo" : "Note")).lineLimit(1)
                        Text("·")
                        Text(displayed.capturedDate, style: .date)
                        if metadata.pinned { Image(systemName: "pin.fill").foregroundStyle(.orange).accessibilityLabel("Pinned") }
                    }.font(.caption).foregroundStyle(.secondary)
                    if let originalURL {
                        Link(destination: originalURL) { Label("View original", systemImage: "arrow.up.right") }
                            .font(.subheadline.weight(.semibold)).buttonStyle(.bordered).tint(.blue)
                            .accessibilityIdentifier("openOriginal")
                    }
                }
                SavedIntelligenceSection(item: displayed, connection: connection,
                    questionFocusToken: questionFocusToken, onChanged: intelligenceChanged)
                    // Stable identity keeps active editors alive while metadata refreshes.
                    .id(displayed.id)
                if !displayed.note.isEmpty { contentSection((metadata.sourceItems?.count ?? 1) > 1 ? "Your notes" : "Your note", text: displayed.note, symbol: "quote.bubble.fill") }
                if let productURL = PriceMoney.exactURL(displayed.originalUrl) {
                    LivePricePanel(url: productURL, title: displayed.title)
                }
                if let sources = metadata.sourceItems, sources.count > 1 { mergedSources(sources) }
                if !displayed.selectedText.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Saved text").font(.headline)
                        Text(displayed.selectedText).font(.body).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 10)
                    }.font(.subheadline.weight(.semibold)).tint(.secondary)
                }
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
          #if DEBUG
          .task {
              if ProcessInfo.processInfo.arguments.contains("-showInsights") {
                  await reloadLocal()
                  await Task.yield()
                  scroll.scrollTo(displayed.id, anchor: .top)
              }
          }
          #endif
        }
        .background(NativeTheme.bg).navigationTitle("Your find").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    if localOnly {
                        Button { showingEditor = true } label: { Label("Edit find", systemImage: "square.and.pencil") }
                        Button { Task { await togglePin() } } label: { Label(metadata.pinned ? "Unpin" : "Pin to top", systemImage: metadata.pinned ? "pin.slash" : "pin") }
                        Button { Task { await toggleFavorite() } } label: { Label(metadata.isFavorite ? "Unfavorite" : "Favorite", systemImage: metadata.isFavorite ? "heart.slash" : "heart") }
                        Button { Task { await toggleArchive() } } label: { Label(metadata.isArchived ? "Move to library" : "Archive", systemImage: "archivebox") }
                        if !metadata.attachments.isEmpty { Button { showingAttachments = true } label: { Label("Original files", systemImage: "paperclip") } }
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
        } message: {
            if localOnly, let sources = metadata.sourceItems, sources.count > 1 {
                Text("This removes all \(sources.count) saves in this product, including their original notes and files, from this iPhone.")
            } else {
                Text(localOnly ? "This removes the find and its note from this iPhone." : "This removes the link and its note from your library on all connected devices.")
            }
        }
        .task(id: "\(item.id)|\(item.revision)") {
            await reloadLocal()
            #if DEBUG
            // Opens the real stored context without selecting or changing a preference.
            if !didShowDebugRefinement, ProcessInfo.processInfo.arguments.contains("-showRefinement"),
               let analysis = metadata.analysis, let intent = metadata.selectedIntents.first {
                didShowDebugRefinement = true
                refinement = IntentRefinementContext(analysis: analysis, selectedIntent: intent, existingIntents: metadata.selectedIntents)
            }
            #endif
        }
        .sheet(isPresented: $showingEditor) { EditFindSheet(item: displayed) { onChanged(); Task { await reloadLocal() } } }
        .sheet(isPresented: $showingAttachments) {
            NavigationStack {
                ScrollView { AttachmentGallery(attachments: metadata.attachments).padding(20) }
                    .navigationTitle("Original files").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingAttachments = false } } }
            }
        }
        .sheet(item: $refinement) { context in
            IntentRefinementSheet(context: context) { value in await appendRefinement(value) }
        }
        .onChange(of: stillSaved) { _, present in if !present { dismiss() } }
    }
    @ViewBuilder private var hero: some View {
        if displayed.hasImage {
            FindImage(item: displayed, connection: connection)
                .frame(height: 280)
                .frame(maxWidth: .infinity)
                .padding(.bottom, reservedQuestionSpace)
                .background(Color(.secondarySystemBackground))
        } else if let originalURL {
            WebsitePreview(url: originalURL, presentation: .hero,
                onImageReady: { websiteHasImage = $0 }, reservedBottomSpace: reservedQuestionSpace)
        }
    }
    @ViewBuilder private func imageQuestion(scroll: ScrollViewProxy) -> some View {
        if let analysis = metadata.analysis {
            FindIntentOverlay(prompts: analysis.prompts, selected: metadata.selectedIntents,
                busy: updating || deleting) {
                questionFocusToken = UUID()
                withAnimation(.easeInOut(duration: 0.25)) { scroll.scrollTo(displayed.id, anchor: .top) }
            }
        }
    }
    private func reloadLocal() async {
        guard localOnly else { return }
        errorMessage = nil; deletionFailed = false
        do {
            metadata = try await LocalLibrary.shared.metadata()[item.id] ?? LocalFindMetadata()
            latestItem = try await LocalLibrary.shared.item(item.id)
        } catch { errorMessage = error.localizedDescription }
    }
    private func intelligenceChanged() {
        onChanged()
        Task { await reloadLocal() }
    }
    private func appendRefinement(_ value: String) async -> Bool {
        do {
            var values = try await LocalLibrary.shared.metadata()[item.id]?.selectedIntents ?? []
            if !values.contains(value) { values.append(value) }
            try await LocalLibrary.shared.setIntents(item.id, values)
            await reloadLocal(); FindsHaptics.selection(); onChanged()
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
    private func togglePin() async {
        guard !updating, !deleting else { return }
        updating = true; errorMessage = nil; deletionFailed = false
        defer { updating = false }
        do {
            try await LocalLibrary.shared.setPinned(item.id, !metadata.pinned)
            await reloadLocal(); FindsHaptics.selection(); onChanged()
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
    private func mergedSources(_ sources: [SavedItem]) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(sources) { source in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(source.title).font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(source.capturedDate, style: .date).font(.caption).foregroundStyle(.secondary)
                        }
                        if !source.note.isEmpty {
                            Text(source.note).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        if !source.selectedText.isEmpty, source.selectedText != source.note {
                            Text(source.selectedText).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        if let url = URL(string: source.originalUrl), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil {
                            Link("View original", destination: url).font(.footnote.weight(.semibold))
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(.top, 14)
        } label: {
            Label("\(sources.count) saves, together", systemImage: "square.on.square")
                .font(.subheadline.weight(.semibold))
        }.tint(.secondary)
    }
    private func contentSection(_ title: String, text: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: symbol).font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
            Text(text).font(.body).lineSpacing(3).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }.padding(18).background(NativeTheme.surface, in: RoundedRectangle(cornerRadius: 22))
    }
    @MainActor private func delete() async {
        guard !deleting, !updating else { return }
        deleting = true; errorMessage = nil; deletionFailed = false; defer { deleting = false }
        let key = deleteKey ?? MutationKey(); deleteKey = key
        do { try await onDelete(item.id, key); dismiss() }
        catch { errorMessage = error.localizedDescription; deletionFailed = true }
    }
}
