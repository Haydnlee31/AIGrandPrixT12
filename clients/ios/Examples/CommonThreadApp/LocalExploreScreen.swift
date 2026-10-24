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
    let discoveryHint: String?
    let productURL: String?
    let licenseURL: String?
    let attribution: String?
    let reasons: [Reason]
    enum CodingKeys: String, CodingKey {
        case id, title, reasons, attribution
        case discoveryHint = "discovery_hint"
        case imageURL = "image_url", sourceName = "source_name", sourceRecordID = "source_record_id"
        case sourceURL = "source_url", licenseURL = "license_url", productURL = "product_url"
    }

    /// A merchant action must open this catalog record's listing, never a search
    /// or a similarly named product. The relay supplies the record's exact URL.
    var exactAmazonURL: URL? {
        guard let productURL, let components = URLComponents(string: productURL),
              components.scheme?.lowercased() == "https", components.user == nil,
              components.password == nil, components.port == nil,
              let host = components.host?.lowercased() else { return nil }
        let domain = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let domains: Set<String> = ["amazon.com", "amazon.sg", "amazon.co.uk", "amazon.ca", "amazon.com.au",
            "amazon.de", "amazon.fr", "amazon.it", "amazon.es", "amazon.co.jp", "amazon.in", "amazon.nl",
            "amazon.se", "amazon.pl", "amazon.com.be", "amazon.com.mx", "amazon.com.br", "amazon.ae",
            "amazon.sa", "amazon.com.tr", "amazon.eg", "amazon.co.za", "amazon.ie"]
        guard domains.contains(domain) else { return nil }
        let path = components.path.split(separator: "/").map(String.init)
        let asin: String
        if path.count == 2, path[0] == "dp" { asin = path[1] }
        else if path.count == 3, path[0] == "gp", path[1] == "product" { asin = path[2] }
        else { return nil }
        guard asin.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else { return nil }
        return URL(string: "https://\(domain)/dp/\(asin)")
    }
}

/// Local saves remain on the device. Only the selected shopping context is sent
/// to the configured relay to retrieve real, attributed catalog records.
struct LocalExploreScreen: View {
    let query: String
    let libraryRevision: String
    var refreshID = UUID()
    var onlyFindID: String? = nil
    var sessionBrief: String? = nil
    var sessionCategory: String? = nil
    @State private var showingTasteLab = false
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
            LazyVStack(alignment: .leading, spacing: 20) {
                if sessionBrief == nil && onlyFindID == nil {
                    Button { showingTasteLab = true } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "slider.horizontal.3").font(.title2).foregroundStyle(.purple)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Taste Lab").font(.headline)
                                Text("Discover what draws you in.").font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer(); Image(systemName: "chevron.right")
                        }.padding(18).background(.quaternary, in: RoundedRectangle(cornerRadius: 22))
                    }.buttonStyle(.plain)
                }
                recommendations
            }.padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear {
            #if DEBUG
            if sessionBrief == nil && ProcessInfo.processInfo.arguments.contains("-showTasteLab") { showingTasteLab = true }
            #endif
        }
        .sheet(isPresented: $showingTasteLab) { TasteLabScreen() }
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
            HStack {
                Text("Closest matches").font(.title3.bold())
                Spacer()
                Text(page.items.count.formatted()).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                    .accessibilityLabel("\(page.items.count) matches")
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: 26) {
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
        if finds.isEmpty && sessionBrief == nil {
            LibraryEmptyState(symbol: "bookmark", title: "Find your next favourite.", detail: "Save an image or link to get recommendations based on what you like.")
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
        if let sessionBrief {
            return try JSONSerialization.data(withJSONObject: ["finds": [["id": "taste-lab-session", "title": "Your Taste Lab choices", "intents": [sessionBrief], "analysis": ["product_name": sessionBrief, "category_path": [sessionCategory ?? TasteLabSession.productType(for: sessionBrief) ?? "unknown"], "summary": "User-confirmed brief from an illustrative reading-corner comparison."]]], "query": "", "limit": 24])
        }
        let input: [[String: Any]] = try finds.filter { (onlyFindID ?? focusedFind) == nil || $0.id == (onlyFindID ?? focusedFind) }.prefix(24).map { find in
            let context = metadata[find.id] ?? LocalFindMetadata()
            // Duplicate saves keep their complete notes locally; transport respects
            // the shared recommendation contract instead of rejecting a large group.
            var value: [String: Any] = ["id": find.id, "title": find.title,
                "note": String(find.note.prefix(2_000)), "text": String(find.selectedText.prefix(12_000)),
                "intents": Array(context.selectedIntents.prefix(8))]
            if !find.originalUrl.isEmpty { value["original_url"] = String(find.originalUrl.prefix(4_000)) }
            if let analysis = context.analysis { value["analysis"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(analysis)) }
            return value
        }
        return try JSONSerialization.data(withJSONObject: ["finds": input, "query": String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100)), "limit": 24], options: [.sortedKeys])
    }
    private func filteredPage(_ value: LocalRecommendationPage) -> LocalRecommendationPage {
        guard let sessionBrief, sessionCategory == nil else { return value }
        let items = value.items.filter { TasteLabSession.suitableTitle($0.title, for: TasteLabSession.productType(for: sessionBrief)) }
        return LocalRecommendationPage(status: items.isEmpty ? "no_matches" : "ready", items: items, catalogCount: value.catalogCount)
    }
    @MainActor private func requestRecommendations(force: Bool) async throws {
        let body = try payload()
        if lastPayload != body { page = nil }
        lastPayload = body
        if let cached = try RecommendationCache.cached(body) { page = filteredPage(try JSONDecoder().decode(LocalRecommendationPage.self, from: cached)) }
        let data = try await RecommendationCache.fetch(body, force: force)
        try Task.checkCancellation()
        page = filteredPage(try JSONDecoder().decode(LocalRecommendationPage.self, from: data))
    }
    @MainActor private func load() async {
        guard !Task.isCancelled else { return }
        busy = true; errorMessage = nil
        defer { if !Task.isCancelled { busy = false; analyzing = false } }
        do {
            try await readLibrary()
            if (finds.isEmpty && sessionBrief == nil) || !CaptureIntelligence.isConfigured { page = nil; lastPayload = nil; return }
            try await Task.sleep(for: .milliseconds(query.isEmpty ? 60 : 230))
            let force = forceNext || (previousRefresh != nil && previousRefresh != refreshID)
            forceNext = false
            previousRefresh = refreshID
            // Show available recommendations before doing any additional model work.
            try await requestRecommendations(force: force)
            busy = false
            guard query.isEmpty && sessionBrief == nil else { return }
            let missing = finds.filter { ((onlyFindID ?? focusedFind) == nil || $0.id == (onlyFindID ?? focusedFind)) && metadata[$0.id]?.analysis?.schemaVersion != 2 }.prefix(2)
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
        VStack(alignment: .leading, spacing: 12) {
            CatalogProductImage(url: item.imageURL.flatMap(URL.init(string:)), height: 196, fit: true)
                .clipShape(RoundedRectangle(cornerRadius: 20))
            VStack(alignment: .leading, spacing: 7) {
                Text(item.title).font(.subheadline.bold()).foregroundStyle(.primary).lineLimit(3).multilineTextAlignment(.leading)
                if let reason = item.reasons.first {
                    HStack(alignment: .top, spacing: 5) {
                        Image(systemName: "sparkles").foregroundStyle(.purple).accessibilityHidden(true)
                        Text(reason.text).foregroundStyle(.secondary).multilineTextAlignment(.leading).lineLimit(2)
                    }.font(.caption.weight(.medium))
                }
                if item.exactAmazonURL != nil {
                    Label("Amazon", systemImage: "arrow.up.right").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .topLeading)
            .accessibilityElement(children: .combine)
    }
}

struct LocalRecommendationDetail: View {
    let item: LocalRecommendation
    let finds: [SavedItem]
    let onChanged: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                CatalogProductImage(url: item.imageURL.flatMap(URL.init(string:)), height: 330, fit: true)
                    .clipShape(RoundedRectangle(cornerRadius: 28))
                Text(item.title).font(.title2.bold())
                if let url = item.exactAmazonURL { LivePricePanel(url: url, title: item.title) }
                if !item.reasons.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        Label("Why it fits", systemImage: "sparkles").font(.headline.bold()).foregroundStyle(.purple)
                        ForEach(Array(item.reasons.prefix(2).enumerated()), id: \.offset) { index, reason in
                            Text(reason.text).font(.subheadline).foregroundStyle(.secondary)
                        }
                        ForEach(finds.filter { find in item.reasons.contains { $0.findID == find.id } }.prefix(2)) { find in
                            NavigationLink {
                                SavedContentView(item: find, stillSaved: true, localOnly: true, onChanged: onChanged,
                                    onDelete: { id, _ in try await LocalLibrary.shared.delete(id); onChanged() })
                            } label: {
                                HStack(spacing: 9) {
                                    Image(systemName: "bookmark.fill").foregroundStyle(.blue)
                                    Text(find.title).lineLimit(1).foregroundStyle(.primary)
                                    Spacer(minLength: 4)
                                    Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
                                }.font(.subheadline.weight(.medium))
                            }.buttonStyle(.plain)
                        }
                    }
                }
                if item.exactAmazonURL == nil {
                    Label("Listing link unavailable", systemImage: "link").font(.footnote).foregroundStyle(.secondary)
                }
                Divider()
                DisclosureGroup("Source & attribution") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(item.attribution ?? item.sourceName).font(.footnote)
                        Text("Record: " + item.sourceRecordID).font(.caption).textSelection(.enabled)
                        if let source = URL(string: item.sourceURL) { Link(item.sourceName, destination: source) }
                        if let url = item.licenseURL.flatMap(URL.init(string:)) { Link("Source license", destination: url) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 12)
                }.font(.subheadline).tint(.secondary)
            }.padding(20)
        }
        .safeAreaInset(edge: .bottom) {
            if let url = item.exactAmazonURL {
                Link(destination: url) {
                    Label("View on Amazon", systemImage: "arrow.up.right").font(.headline.bold())
                        .frame(maxWidth: .infinity).padding(.vertical, 18)
                        .foregroundStyle(colorScheme == .dark ? .black : .white)
                        .background(Color.primary, in: Capsule())
                }.buttonStyle(.plain).padding(.horizontal, 20).padding(.vertical, 12).background(.bar)
            }
        }
        .toolbar {
            if let url = item.exactAmazonURL {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: url).accessibilityLabel("Share product link")
                }
            }
        }
        .background(NativeTheme.bg).navigationTitle("Product").navigationBarTitleDisplayMode(.inline)
    }
}
