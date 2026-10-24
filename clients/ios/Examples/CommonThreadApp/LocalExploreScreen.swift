import SwiftUI
import CommonThreadKit

struct LocalRecommendationPage: Decodable {
    let status: String
    let items: [LocalRecommendation]
    let catalogCount: Int
    enum CodingKeys: String, CodingKey { case status, items; case catalogCount = "catalog_count" }
}
struct LocalRecommendation: Decodable, Identifiable {
    struct Reason: Decodable, Identifiable {
        let findID: String
        let findTitle: String
        let text: String
        var id: String { findID + text }
        enum CodingKeys: String, CodingKey { case findID = "find_id", findTitle = "find_title", text }
    }
    let id: String
    let title: String
    let imageURL: String?
    let sourceName: String
    let sourceRecordID: String
    let sourceURL: String
    let licenseURL: String?
    let attribution: String?
    let reasons: [Reason]
    enum CodingKeys: String, CodingKey {
        case id, title, reasons, attribution
        case imageURL = "image_url", sourceName = "source_name", sourceRecordID = "source_record_id"
        case sourceURL = "source_url", licenseURL = "license_url"
    }
}

/// Local saves remain on the device. Only the selected shopping context is sent
/// to the configured relay to retrieve real, attributed catalog records.
struct LocalExploreScreen: View {
    let query: String
    let libraryRevision: String
    var refreshID = UUID()
    var onChanged: () -> Void = {}
    @State private var finds: [SavedItem] = []
    @State private var metadata: [String: LocalFindMetadata] = [:]
    @State private var page: LocalRecommendationPage?
    @State private var focusedFind: String?
    @State private var busy = false
    @State private var analyzing = false
    @State private var errorMessage: String?
    @State private var retryID = UUID()
    @State private var previousRefresh: UUID?
    @State private var forceNext = false
    @State private var lastPayload: Data?
    @Environment(\.dynamicTypeSize) private var typeSize
    private var taskID: String { libraryRevision + "|" + query + "|" + (focusedFind ?? "all") + "|" + retryID.uuidString + "|" + refreshID.uuidString }
    private var columns: [GridItem] { Array(repeating: GridItem(.flexible(), spacing: 12), count: typeSize.isAccessibilitySize ? 1 : 2) }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                recommendations
            }.padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 24)
        }
        .task(id: taskID) { await load() }
    }
    @ViewBuilder private var recommendations: some View {
        if let id = focusedFind, let find = finds.first(where: { $0.id == id }) {
            HStack(spacing: 8) {
                Label(find.title, systemImage: "sparkles").font(.subheadline.weight(.semibold)).lineLimit(1).foregroundStyle(.purple)
                Spacer()
                Button { focusedFind = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).frame(minWidth: 44, minHeight: 44) }
                    .accessibilityLabel("Explore all finds")
            }
        }
        if let page, !page.items.isEmpty {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
                ForEach(page.items) { item in
                    NavigationLink { LocalRecommendationDetail(item: item, finds: finds, onChanged: reloadLibrary) }
                    label: { LocalRecommendationCard(item: item) }.buttonStyle(.plain)
                }
            }
        } else if busy || analyzing {
            ProgressView(analyzing ? "Understanding your find…" : "Finding matches…")
                .font(.subheadline).frame(maxWidth: .infinity).padding(.vertical, 65)
        } else if errorMessage == nil { emptyState }
        if (busy || analyzing), page?.items.isEmpty == false {
            HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }.padding(6)
        }
        if let errorMessage {
            HStack {
                Text(errorMessage).font(.footnote).foregroundStyle(.secondary)
                Spacer()
                Button("Retry") { forceNext = true; retryID = UUID() }.font(.subheadline.bold())
            }.padding(.vertical, 12)
        }
    }
    @ViewBuilder private var emptyState: some View {
        if finds.isEmpty {
            LibraryEmptyState(symbol: "bookmark", title: "Start with a find.", detail: "Save something you like in Library.")
        } else if !CaptureIntelligence.isConfigured {
            LibraryEmptyState(symbol: "sparkles", title: "Connect AI.", detail: "Open AI & privacy in Profile.")
        } else if page?.status == "catalog_unavailable" {
            LibraryEmptyState(symbol: "shippingbox", title: "Catalog unavailable.", detail: "Pull down to try again.")
        } else if page?.status == "needs_analysis" {
            LibraryEmptyState(symbol: "photo", title: "Add a little context.", detail: "A product photo or description helps.")
        } else {
            LibraryEmptyState(symbol: "magnifyingglass", title: "No close matches.", detail: "Try another search or saved find.")
        }
    }
    private func reloadLibrary() { retryID = UUID(); onChanged() }
    @MainActor private func readLibrary() async throws {
        let savedMetadata = try await LocalLibrary.shared.metadata()
        let savedFinds = try await LocalLibrary.shared.collection()
        try Task.checkCancellation()
        metadata = savedMetadata
        finds = savedFinds.filter { $0.client != "sample" && !(savedMetadata[$0.id]?.isArchived ?? false) }
        if let focusedFind, !finds.contains(where: { $0.id == focusedFind }) { self.focusedFind = nil }
    }
    @MainActor private func payload() throws -> Data {
        let input: [[String: Any]] = try finds.filter { focusedFind == nil || $0.id == focusedFind }.prefix(24).map { find in
            let context = metadata[find.id] ?? LocalFindMetadata()
            // Duplicate saves keep their complete notes locally; transport respects
            // the shared recommendation contract instead of rejecting a large group.
            var value: [String: Any] = ["id": find.id, "title": find.title,
                "note": String(find.note.prefix(2_000)), "text": String(find.selectedText.prefix(12_000)),
                "intents": Array(context.selectedIntents.prefix(8))]
            if let analysis = context.analysis { value["analysis"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(analysis)) }
            return value
        }
        return try JSONSerialization.data(withJSONObject: ["finds": input, "query": String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100)), "limit": 24], options: [.sortedKeys])
    }
    @MainActor private func requestRecommendations(force: Bool) async throws {
        let body = try payload()
        if lastPayload != body { page = nil }
        lastPayload = body
        if let cached = try RecommendationCache.cached(body) { page = try JSONDecoder().decode(LocalRecommendationPage.self, from: cached) }
        let data = try await RecommendationCache.fetch(body, force: force)
        try Task.checkCancellation()
        page = try JSONDecoder().decode(LocalRecommendationPage.self, from: data)
    }
    @MainActor private func load() async {
        guard !Task.isCancelled else { return }
        busy = true; errorMessage = nil
        defer { if !Task.isCancelled { busy = false; analyzing = false } }
        do {
            try await readLibrary()
            if finds.isEmpty || !CaptureIntelligence.isConfigured { page = nil; lastPayload = nil; return }
            try await Task.sleep(for: .milliseconds(query.isEmpty ? 60 : 230))
            let force = forceNext || (previousRefresh != nil && previousRefresh != refreshID)
            forceNext = false
            previousRefresh = refreshID
            // Show available recommendations before doing any additional model work.
            try await requestRecommendations(force: force)
            busy = false
            guard query.isEmpty else { return }
            let missing = finds.filter { (focusedFind == nil || $0.id == focusedFind) && metadata[$0.id]?.analysis?.schemaVersion != 2 }.prefix(2)
            var changed = false
            for find in missing {
                try Task.checkCancellation(); analyzing = true
                do {
                    var bytes: Data?
                    if let image = metadata[find.id]?.attachments.first(where: \.isImage) { bytes = try await LocalLibrary.shared.attachmentData(image) }
                    let result = try await CaptureIntelligence.analyze(url: find.originalUrl.isEmpty ? nil : find.originalUrl,
                        title: find.title, text: find.selectedText, note: find.note, imageData: bytes)
                    try Task.checkCancellation()
                    try await LocalLibrary.shared.setAnalysis(find.id, result); changed = true
                } catch is CancellationError { throw CancellationError() }
                catch { if page?.items.isEmpty != false { errorMessage = error.localizedDescription } }
            }
            if changed {
                try await readLibrary(); try await requestRecommendations(force: false); onChanged()
            }
        } catch is CancellationError {} catch { if !Task.isCancelled { errorMessage = error.localizedDescription } }
    }
}

private struct LocalRecommendationCard: View {
    let item: LocalRecommendation
    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            CatalogProductImage(url: item.imageURL.flatMap(URL.init(string:)), height: 190, fit: true)
                .clipShape(RoundedRectangle(cornerRadius: 23))
            Text(item.title).font(.subheadline.bold()).foregroundStyle(.primary).lineLimit(3).multilineTextAlignment(.leading)
            if let reason = item.reasons.first {
                Label(reason.text, systemImage: "sparkles").font(.caption.weight(.medium)).foregroundStyle(.purple)
                    .lineLimit(3).multilineTextAlignment(.leading)
            }
        }.frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct LocalRecommendationDetail: View {
    let item: LocalRecommendation
    let finds: [SavedItem]
    let onChanged: () -> Void
    @Environment(\.openURL) private var openURL
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                CatalogProductImage(url: item.imageURL.flatMap(URL.init(string:)), height: 330, fit: true)
                    .clipShape(RoundedRectangle(cornerRadius: 28))
                Text(item.title).font(.title.bold())
                IntelligenceCard(title: "Why this fits", symbol: "sparkles") {
                    ForEach(Array(item.reasons.prefix(2).enumerated()), id: \.offset) { index, reason in
                        FindInsightRow(text: reason.text, index: index)
                    }
                    ForEach(finds.filter { find in item.reasons.contains { $0.findID == find.id } }) { find in
                        NavigationLink {
                            SavedContentView(item: find, stillSaved: true, localOnly: true, onChanged: onChanged,
                                onDelete: { id, _ in try await LocalLibrary.shared.delete(id); onChanged() })
                        } label: { Label(find.title, systemImage: "bookmark.fill").font(.subheadline.weight(.semibold)) }
                    }
                }

                if let url = shoppingSearchURL {
                    Link(destination: url) {
                        Label("Find on Amazon", systemImage: "arrow.up.right").font(.headline.bold())
                            .frame(maxWidth: .infinity).padding(19).foregroundStyle(.white)
                            .background(Color.purple, in: RoundedRectangle(cornerRadius: 22))
                    }
                    Text("Opens a search. Check current price and availability on Amazon.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                DisclosureGroup("Source & attribution") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(item.attribution ?? item.sourceName).font(.footnote)
                        Text("Record: " + item.sourceRecordID).font(.caption).textSelection(.enabled)
                        if let source = URL(string: item.sourceURL) { Link(item.sourceName, destination: source) }
                        if let url = item.licenseURL.flatMap(URL.init(string:)) { Link("Source license", destination: url) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 12)
                }.font(.subheadline).tint(.secondary)
            }.padding(20)
        }.background(NativeTheme.bg).navigationTitle("A find for you").navigationBarTitleDisplayMode(.inline)
    }
    private var shoppingSearchURL: URL? {
        var url = URLComponents(string: "https://www.amazon.com/s")
        url?.queryItems = [URLQueryItem(name: "k", value: item.title)]
        return url?.url
    }
}
