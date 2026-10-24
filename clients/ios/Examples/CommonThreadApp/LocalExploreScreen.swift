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
    var onChanged: () -> Void = {}
    @State private var finds: [SavedItem] = []
    @State private var metadata: [String: LocalFindMetadata] = [:]
    @State private var page: LocalRecommendationPage?
    @State private var focusedFind: String?
    @State private var busy = false
    @State private var statusText = "Finding your next good find…"
    @State private var errorMessage: String?
    @State private var retryID = UUID()
    private var taskID: String { libraryRevision + "|" + query + "|" + (focusedFind ?? "all") + "|" + retryID.uuidString }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text("More like you.").font(.system(.largeTitle, design: .default, weight: .bold))
                Text("Real finds, inspired by what caught your eye.").font(.body).foregroundStyle(.secondary)
            }
            if !finds.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 9) {
                        focusChip("All your finds", id: nil, symbol: "sparkles")
                        ForEach(finds) { find in
                            focusChip(find.title, id: find.id, symbol: find.hasImage ? "photo" : "link")
                        }
                    }.padding(.vertical, 2)
                }
            }
            if busy {
                HStack(spacing: 12) {
                    ProgressView().tint(.purple)
                    Text(statusText).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                }.padding(.vertical, 8)
            }
            if let errorMessage {
                IntelligenceCard(title: "Let’s try that again", symbol: "arrow.clockwise") {
                    Text(errorMessage).font(.subheadline).foregroundStyle(.secondary)
                    Button("Reload recommendations") { retryID = UUID() }.font(.headline)
                }
            }
            if let page, !page.items.isEmpty {
                HStack {
                    Label("Inspired by your saves", systemImage: "sparkles").font(.subheadline.bold()).foregroundStyle(.purple)
                    Spacer()
                    Text("\(page.items.count) finds").font(.caption).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], alignment: .leading, spacing: 20) {
                    ForEach(page.items) { item in
                        NavigationLink {
                            LocalRecommendationDetail(item: item, finds: finds, onChanged: onChanged)
                        } label: { LocalRecommendationCard(item: item) }.buttonStyle(.plain)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Product catalog · \(page.catalogCount.formatted()) records").font(.caption.weight(.medium))
                    Text("Catalog inspiration. Check current price and availability with the seller.").font(.caption)
                }.foregroundStyle(.secondary).padding(.vertical, 8)
            } else if !busy, errorMessage == nil {
                emptyState
            }
        }
        .task(id: taskID) { await load() }
    }

    private func focusChip(_ title: String, id: String?, symbol: String) -> some View {
        Button { focusedFind = id } label: {
            Label(title, systemImage: symbol).font(.subheadline.weight(.semibold)).lineLimit(1)
                .padding(.horizontal, 15).padding(.vertical, 12)
                .foregroundStyle(focusedFind == id ? Color.white : Color.primary)
                .background(focusedFind == id ? Color.purple : NativeTheme.surface, in: Capsule())
        }.buttonStyle(.plain).accessibilityAddTraits(focusedFind == id ? .isSelected : [])
    }
    @ViewBuilder private var emptyState: some View {
        if finds.isEmpty {
            LibraryEmptyState(symbol: "bookmark", title: "It starts with your eye.", detail: "Save a photo or link in Library. Explore will find products inspired by the details you love.")
        } else if !CaptureIntelligence.isConfigured {
            LibraryEmptyState(symbol: "sparkles", title: "Connect your inspiration.", detail: "Connect shopping intelligence in Profile to find real products from your saves.")
        } else if page?.status == "catalog_unavailable" {
            LibraryEmptyState(symbol: "shippingbox", title: "The catalog is getting ready.", detail: "Your finds are safe. Pull down to try again once the product catalog is available.")
        } else if page?.status == "needs_analysis" {
            LibraryEmptyState(symbol: "photo.badge.magnifyingglass", title: "A little more to go on.", detail: "Add a product photo or a descriptive note to your find, then try again.")
        } else {
            LibraryEmptyState(symbol: "magnifyingglass", title: "Nothing quite right yet.", detail: "Try another saved find or a broader search. We only show products that match your saved context.")
        }
    }

    @MainActor private func load() async {
        busy = true; errorMessage = nil; page = nil
        defer { if !Task.isCancelled { busy = false } }
        do {
            try await Task.sleep(for: .milliseconds(280))
            var flags = try await LocalLibrary.shared.metadata()
            var actual = try await LocalLibrary.shared.collection().filter { $0.client != "sample" && !(flags[$0.id]?.isArchived ?? false) }
            finds = actual; metadata = flags
            guard !actual.isEmpty, CaptureIntelligence.isConfigured else { return }
            let candidates = actual.filter { focusedFind == nil || $0.id == focusedFind }.prefix(24)
            var analyzed = false
            // A bounded first pass prepares older saves. Already understood finds
            // reuse their persisted analysis; changing a preference costs no model call.
            for find in candidates.filter({ find in
                guard let analysis = flags[find.id]?.analysis else { return true }
                return analysis.schemaVersion != 2
            }).prefix(4) {
                try Task.checkCancellation()
                statusText = "Understanding your saved \(find.hasImage ? "photo" : "link")…"
                let image = flags[find.id]?.attachments.first(where: \.isImage)
                let bytes = try await image.mapAsync { try await LocalLibrary.shared.attachmentData($0) }
                do {
                    let analysis = try await CaptureIntelligence.analyze(url: find.originalUrl.isEmpty ? nil : find.originalUrl,
                        title: find.title, text: find.selectedText, note: find.note, imageData: bytes)
                    try Task.checkCancellation()
                    try await LocalLibrary.shared.setAnalysis(find.id, analysis)
                    analyzed = true
                } catch is CancellationError { throw CancellationError() }
                catch { /* Other understood saves can still produce recommendations. */ }
            }
            flags = try await LocalLibrary.shared.metadata()
            actual = try await LocalLibrary.shared.collection().filter { $0.client != "sample" && !(flags[$0.id]?.isArchived ?? false) }
            finds = actual; metadata = flags
            statusText = "Finding products for your eye…"
            let input: [[String: Any]] = try actual.filter { focusedFind == nil || $0.id == focusedFind }.prefix(24).map { find in
                let context = flags[find.id] ?? LocalFindMetadata()
                var value: [String: Any] = ["id": find.id, "title": find.title, "note": find.note, "text": find.selectedText, "intents": context.selectedIntents]
                if let analysis = context.analysis { value["analysis"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(analysis)) }
                return value
            }
            let payload = try JSONSerialization.data(withJSONObject: ["finds": input, "query": String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100)), "limit": 24])
            let data = try await CaptureIntelligence.post(path: "v1/recommendations", body: payload)
            let result = try JSONDecoder().decode(LocalRecommendationPage.self, from: data)
            try Task.checkCancellation()
            page = result
            if analyzed { onChanged() }
        } catch is CancellationError {} catch { if !Task.isCancelled { errorMessage = error.localizedDescription } }
    }
}

private extension Optional {
    func mapAsync<T>(_ transform: (Wrapped) async throws -> T) async rethrows -> T? {
        guard let value = self else { return nil }; return try await transform(value)
    }
}

private struct CatalogImage: View {
    let url: String?
    var body: some View {
        AsyncImage(url: url.flatMap(URL.init(string:))) { phase in
            if url.flatMap(URL.init(string:)) == nil { Image(systemName: "bag").font(.largeTitle).foregroundStyle(.purple) }
            else if let image = phase.image { image.resizable().scaledToFit().padding(12) }
            else if phase.error != nil { Image(systemName: "photo").font(.largeTitle).foregroundStyle(.secondary) }
            else { ProgressView().tint(.purple) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.white)
    }
}
private struct LocalRecommendationCard: View {
    let item: LocalRecommendation
    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            CatalogImage(url: item.imageURL).frame(height: 190).clipShape(RoundedRectangle(cornerRadius: 23))
            Text(item.title).font(.subheadline.bold()).foregroundStyle(.primary).lineLimit(3).multilineTextAlignment(.leading)
            if let reason = item.reasons.first {
                Label(reason.text, systemImage: "sparkles").font(.caption.weight(.medium)).foregroundStyle(.purple)
                    .lineLimit(3).multilineTextAlignment(.leading)
            }
            Text("See why this fits").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
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
                CatalogImage(url: item.imageURL).frame(height: 330).clipShape(RoundedRectangle(cornerRadius: 28))
                Text(item.title).font(.title.bold())
                IntelligenceCard(title: "Why it caught our eye", symbol: "sparkles") {
                    ForEach(Array(item.reasons.prefix(3).enumerated()), id: \.offset) { index, reason in
                        FindInsightRow(text: reason.text, index: index)
                        if let find = finds.first(where: { $0.id == reason.findID }) {
                            NavigationLink {
                                SavedContentView(item: find, stillSaved: true, localOnly: true, onChanged: onChanged,
                                    onDelete: { id, _ in try await LocalLibrary.shared.delete(id); onChanged() })
                            } label: { Label("From: " + find.title, systemImage: "bookmark.fill").font(.subheadline.weight(.semibold)) }
                        }
                    }
                }
                if let url = shoppingSearchURL {
                    Link(destination: url) {
                        Label("Look for it on Amazon", systemImage: "arrow.up.right").font(.headline.bold())
                            .frame(maxWidth: .infinity).padding(19).foregroundStyle(.white)
                            .background(Color.purple, in: RoundedRectangle(cornerRadius: 22))
                    }
                    Text("Opens a search. This catalog record does not confirm a current offer, price, or stock.")
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
