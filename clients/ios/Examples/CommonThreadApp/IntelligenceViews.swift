import SwiftUI
import CommonThreadKit

// These views use the shared SDK only after an account is connected. Local saves
// are never silently uploaded and a missing service never produces invented results.
private func webURL(_ value: String?) -> URL? {
    guard let value, let url = URL(string: value),
          ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
          url.host != nil, url.user == nil, url.password == nil else { return nil }
    return url
}

private func connectionIdentity(_ connection: SharedEnvironment?) -> String {
    connection.map { $0.baseURL.absoluteString + "|" + $0.accountId } ?? "local"
}

func catalogCurrencyExponent(_ currency: String) -> Int? {
    // The backend's approved currency exponents, without currency conversion.
    let zeroDecimal = ["JPY", "KRW"]
    let threeDecimal = ["KWD", "BHD", "OMR"]
    let twoDecimal = ["USD", "SGD", "EUR", "GBP", "AUD", "CAD", "NZD", "HKD", "CNY", "MYR", "THB", "PHP", "IDR", "INR", "CHF", "SEK", "NOK", "DKK", "PLN", "CZK", "AED", "SAR", "ZAR", "BRL", "MXN", "TWD"]
    if zeroDecimal.contains(currency) { return 0 }
    if threeDecimal.contains(currency) { return 3 }
    if twoDecimal.contains(currency) { return 2 }
    return nil
}

func catalogCurrencyText(_ minor: Int?, currency: String?) -> String {
    guard let minor, minor >= 0, let currency else { return "Price unavailable" }
    guard let exponent = catalogCurrencyExponent(currency) else { return "\(currency) \(minor) minor units" }
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = currency
    formatter.minimumFractionDigits = exponent; formatter.maximumFractionDigits = exponent
    let divisor = NSDecimalNumber(mantissa: 1, exponent: Int16(exponent), isNegative: false)
    return formatter.string(from: NSDecimalNumber(value: minor).dividing(by: divisor)) ?? "\(currency) \(minor) minor units"
}

private func isCurrentMerchantOffer(_ product: CatalogRecord) -> Bool {
    guard product.dataKind == "merchant_feed", product.offer.environment == "production",
          let price = product.offer.priceMinor, price >= 0,
          let currency = product.offer.currency, catalogCurrencyExponent(currency) != nil,
          product.offer.hasCurrentObservation() else { return false }
    return true
}

struct IntelligenceCard<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(title, systemImage: symbol).font(.headline.bold())
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(NativeTheme.surface, in: RoundedRectangle(cornerRadius: 24))
    }
}

/// Insert below the original content in SavedContentView. No connection means no upload.
struct SavedIntelligenceSection: View {
    let item: SavedItem
    let connection: SharedEnvironment?
    var questionFocusToken: UUID? = nil
    var onChanged: () -> Void = {}
    @State private var refreshed: SavedItem?
    @State private var capabilities: Capabilities?
    @State private var errorMessage: String?
    @State private var acknowledgment: String?
    @State private var busy = false
    @State private var editor: Suggestion?
    @State private var editText = ""
    @State private var pendingResponse: (request: AnnotationRequest, key: MutationKey)?
    @State private var analyzeKey: MutationKey?
    @State private var operation: Task<Void, Never>?
    @State private var showingSuggestions = false
    private var current: SavedItem { refreshed ?? item }
    private var isLocal: Bool { connection == nil || item.client == "sample" || item.id.hasPrefix("local-") }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if isLocal {
                LocalIntelligencePreview(item: item, questionFocusToken: questionFocusToken, onChanged: onChanged)
            } else {
                IntelligenceCard(title: "New Insights", symbol: "sparkles") {
                    analysisCard
                    if capabilities?.features["annotations"] == true, !current.suggestions.isEmpty {
                        DisclosureGroup("Personalize this find", isExpanded: $showingSuggestions) {
                            VStack(alignment: .leading, spacing: 9) {
                                ForEach(Array(current.suggestions.enumerated()), id: \.element.id) { index, suggestion in
                                    HStack(alignment: .center, spacing: 4) {
                                        Button { respond(.init(action: .select, suggestionId: suggestion.id)) } label: {
                                            FindIntentRow(text: suggestion.text, index: index, compact: true)
                                        }.buttonStyle(.plain).disabled(busy)
                                        Menu {
                                            Button("Edit suggestion", systemImage: "pencil") {
                                                editText = suggestion.text; editor = suggestion
                                            }
                                            Button("Not relevant", systemImage: "xmark") {
                                                respond(.init(action: .reject, suggestionId: suggestion.id))
                                            }
                                        } label: { Image(systemName: "ellipsis").frame(width: 34, height: 44) }
                                            .disabled(busy).accessibilityLabel("Options for \(suggestion.text)")
                                    }
                                }
                                Button("Skip for now") { respond(.init(action: .skip)) }.font(.subheadline).disabled(busy)
                            }.padding(.top, 12)
                        }.font(.subheadline.weight(.semibold)).tint(.purple)
                    }
                    if let acknowledgment { Label(acknowledgment, systemImage: "checkmark.circle.fill").font(.subheadline).foregroundStyle(.green) }
                    if let errorMessage {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(errorMessage).font(.subheadline).foregroundStyle(.secondary)
                            if pendingResponse != nil { Button("Retry annotation") { retryResponse() }.disabled(busy) }
                        }
                    }
                    if busy { ProgressView("Updating your find").font(.subheadline) }
                }
            }
        }
        .onChange(of: questionFocusToken) { _, token in
            if token != nil { withAnimation(.easeInOut(duration: 0.2)) { showingSuggestions = true } }
        }
        .task(id: "\(connectionIdentity(connection))|\(item.id)|\(item.revision)") {
            refreshed = nil; capabilities = nil; errorMessage = nil
            guard !isLocal, let connection else { return }
            do {
                let api = try await connection.intelligenceClient()
                let loadedCapabilities = try await api.capabilities()
                try Task.checkCancellation()
                capabilities = loadedCapabilities
                await refreshAnalysis(api)
            } catch is CancellationError {} catch { if !Task.isCancelled { errorMessage = error.localizedDescription } }
        }
        .onDisappear { operation?.cancel() }
        .sheet(item: $editor) { suggestion in
            NavigationStack {
                Form {
                    Section("Why are you saving this?") {
                        TextEditor(text: $editText).frame(minHeight: 140)
                        Text("\(editText.count)/2,000").font(.caption).foregroundStyle(.secondary)
                    }
                    Section { Text("You can change the suggestion completely. Only the words you save become your annotation.").font(.footnote).foregroundStyle(.secondary) }
                }
                .navigationTitle("Make it yours").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { editor = nil } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            let text = editText.trimmingCharacters(in: .whitespacesAndNewlines)
                            editor = nil
                            respond(.init(action: .edit, suggestionId: suggestion.id, text: text))
                        }.bold().disabled(editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || editText.count > 2000)
                    }
                }
            }.presentationDetents([.medium, .large])
        }
    }

    private var analysisCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let analysis = current.analysis {
                NewInsightHighlights(summary: analysis.summary, evidence: customerObservations, uncertainties: analysis.uncertainties)
            }
            switch current.analysisStatus {
            case .pending:
                Label("Taking a closer look…", systemImage: "sparkles").font(.subheadline).foregroundStyle(.secondary)
            case .failed:
                Label("We couldn’t finish looking at this find yet.", systemImage: "arrow.clockwise").font(.subheadline).foregroundStyle(.secondary)
            case .unavailable:
                Text("Your original and note are saved.").font(.subheadline).foregroundStyle(.secondary)
            case .ready: EmptyView()
            }
            if capabilities?.features["product_analysis"] == true {
                Button(current.analysis == nil ? "Take a closer look" : "Refresh insights", systemImage: "arrow.clockwise") { analyze() }
                    .font(.subheadline).disabled(busy)
            }
        }
    }

    private var customerObservations: [String] {
        guard let analysis = current.analysis else { return [] }
        var observations: [String] = []
        for product in analysis.products {
            let evidence = product.attributes.map(\.evidence) + [product.brand?.evidence, product.model?.evidence].compactMap { $0 }
            for text in evidence where !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !observations.contains(text) {
                observations.append(text)
            }
        }
        return observations
    }

    @MainActor private func refreshAnalysis(_ api: CommonThreadClient) async {
        do {
            // Bounded foreground polling. Closing the view/account cancels its task.
            for attempt in 0..<12 {
                let result = try await api.savedItem(item.id)
                try Task.checkCancellation()
                refreshed = result
                if result.analysisStatus != .pending { break }
                if attempt < 11 { try await Task.sleep(for: .milliseconds(1500)) }
            }
        } catch is CancellationError {} catch { if !Task.isCancelled { errorMessage = error.localizedDescription } }
    }

    @MainActor private func respond(_ request: AnnotationRequest) {
        guard !busy, capabilities?.features["annotations"] == true else { return }
        pendingResponse = (request, MutationKey())
        retryResponse()
    }

    @MainActor private func retryResponse() {
        guard !busy, capabilities?.features["annotations"] == true, let pendingResponse, let connection else { return }
        busy = true; errorMessage = nil; acknowledgment = nil
        operation?.cancel()
        operation = Task { @MainActor in
            defer { busy = false }
            do {
                let api = try await connection.intelligenceClient()
                let scope = "annotation:\(item.id)"
                let key = try await IntelligenceMutationKeys.shared.key(for: pendingResponse.request, scope: scope, connection: connection)
                try Task.checkCancellation()
                _ = try await api.respond(to: item.id, with: pendingResponse.request, key: key)
                try await IntelligenceMutationKeys.shared.complete(pendingResponse.request, scope: scope, connection: connection)
                try Task.checkCancellation()
                self.pendingResponse = nil
                acknowledgment = pendingResponse.request.action == .skip ? "Skipped for now" : "Annotation saved"
                onChanged()
                await refreshAnalysis(api)
            } catch is CancellationError {} catch { if !Task.isCancelled { errorMessage = error.localizedDescription } }
        }
    }

    @MainActor private func analyze() {
        guard !busy, capabilities?.features["product_analysis"] == true, let connection else { return }
        busy = true; errorMessage = nil
        let key = analyzeKey ?? MutationKey(); analyzeKey = key
        operation?.cancel()
        operation = Task { @MainActor in
            defer { busy = false }
            do {
                let api = try await connection.intelligenceClient()
                let payload: [String: String] = [:]
                let scope = "analyze:\(item.id)"
                let persistedKey = try await IntelligenceMutationKeys.shared.key(for: payload, scope: scope, connection: connection)
                try Task.checkCancellation()
                _ = try await api.analyzeSave(item.id, key: persistedKey)
                try await IntelligenceMutationKeys.shared.complete(payload, scope: scope, connection: connection)
                try Task.checkCancellation()
                analyzeKey = nil; acknowledgment = "Your find is saved. Analysis requested."
                await refreshAnalysis(api); onChanged()
            } catch is CancellationError {} catch { if !Task.isCancelled { errorMessage = error.localizedDescription } }
        }
    }
}

/// A complete tab. Key by accountGeneration at its call site to discard private state on sign-out.
struct ExploreScreen: View {
    let connection: SharedEnvironment?
    var libraryRevision: String = ""
    var onLocalChange: () -> Void = {}
    @Environment(\.scenePhase) private var scenePhase
    @State private var query = ""
    @State private var page: ExplorePage?
    @State private var results: [ExploreItem] = []
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var refreshID = UUID()
    @State private var requestedOffset = 0
    private var taskID: String { "\(connectionIdentity(connection))|\(libraryRevision)|\(query)|\(refreshID)|\(requestedOffset)" }

    var body: some View {
        NavigationStack {
            Group {
                if connection == nil {
                    LocalExploreScreen(query: query, libraryRevision: libraryRevision, refreshID: refreshID, onChanged: onLocalChange)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                        Text(query.isEmpty ? "Ideas shaped by what you’ve saved." : "Explore the details that matter to you.").font(.subheadline).foregroundStyle(.secondary)
                        if !results.isEmpty {
                            ForEach(results) { item in
                                if let connection {
                                    NavigationLink { ExploreDetailView(item: item, connection: connection) } label: { ExploreProductCard(item: item) }.buttonStyle(.plain)
                                }
                            }
                        } else if !busy, let page {
                            emptyState(page.status)
                        }
                        if busy { ProgressView("Finding possibilities").frame(maxWidth: .infinity).padding(24) }
                        if let errorMessage {
                            IntelligenceCard(title: "Couldn’t load ideas", symbol: "wifi.exclamationmark") {
                                Text(errorMessage).font(.subheadline).foregroundStyle(.secondary)
                                Button("Try again") { refreshID = UUID() }
                            }
                        }
                        if let next = page?.nextOffset, !busy {
                            Button("Show more ideas") { requestedOffset = next }.frame(maxWidth: .infinity).padding()
                        }
                        }.padding(20)
                    }
                }
            }
            .background(NativeTheme.bg).navigationTitle("Explore").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let connection {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        NavigationLink { FrameworkToolsView(connection: connection) } label: { Image(systemName: "bag") }.accessibilityLabel("Shopping tools")
                    }
                }
            }
            .searchable(text: $query, prompt: "Search")
            .autocorrectionDisabled()
            .onChange(of: query) { _, _ in requestedOffset = 0; results = []; page = nil }
            .onChange(of: libraryRevision) { _, _ in requestedOffset = 0; results = []; page = nil }
            .task(id: taskID) { await load() }
            .refreshable { requestedOffset = 0; refreshID = UUID() }
            .onChange(of: scenePhase) { _, phase in if phase == .active { requestedOffset = 0; refreshID = UUID() } }
        }
    }

    @ViewBuilder private func emptyState(_ status: ExploreStatus) -> some View {
        switch status {
        case .needsSaves:
            LibraryEmptyState(symbol: "bookmark", title: "Start with a find.", detail: "Save a photo or link to your shared library. Your saved details will help shape ideas here.")
        case .needsAnalysis:
            LibraryEmptyState(symbol: "sparkle.magnifyingglass", title: "A little more context.", detail: "Your finds are saved. Product details need to be understood before we can connect them with ideas. You can also search above.")
        case .noMatches, .ready:
            LibraryEmptyState(symbol: "magnifyingglass", title: "No matching ideas yet.", detail: "Try a different style, product or category. We’ll only show results the catalog can support.")
        }
    }

    @MainActor private func load() async {
        guard let connection else { page = nil; results = []; return }
        busy = true; errorMessage = nil
        defer { if !Task.isCancelled { busy = false } }
        do {
            try await Task.sleep(for: .milliseconds(300))
            let api = try await connection.intelligenceClient()
            let result = try await api.explore(query: query.trimmingCharacters(in: .whitespacesAndNewlines), offset: requestedOffset)
            try Task.checkCancellation()
            if requestedOffset == 0 { results = result.items }
            else {
                let ids = Set(results.map(\.id))
                results += result.items.filter { !ids.contains($0.id) }
            }
            page = result
        } catch is CancellationError {} catch { if !Task.isCancelled { errorMessage = error.localizedDescription } }
    }
}

private struct ExploreProductCard: View {
    let item: ExploreItem
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: "bag").font(.title2).foregroundStyle(NativeTheme.accent)
                    .frame(width: 60, height: 60).background(NativeTheme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 20))
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.product.category ?? "An idea for you").font(.caption).foregroundStyle(.secondary)
                    Text(item.product.title).font(.headline.bold()).foregroundStyle(.primary).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            if let reason = item.reasons.first { Text(reason.text).font(.subheadline).foregroundStyle(.secondary).lineLimit(3) }
            HStack {
                Text(catalogCurrencyText(item.product.offer.priceMinor, currency: item.product.offer.currency)).font(.subheadline.bold())
                Spacer()
                Label("Why this?", systemImage: "arrow.up.right").font(.caption.weight(.semibold))
            }
            if item.product.offer.priceMinor != nil, !isCurrentMerchantOffer(item.product) {
                Text("Recorded price · not a current offer").font(.caption).foregroundStyle(.secondary)
            }
            Text(item.product.dataKind == "merchant_feed" ? "Source: \(item.catalogCitation.sourceId.rawValue)" : item.product.dataKind == "synthetic" ? "Illustrative catalog idea" : "Catalog idea · current price and availability may be unknown")
                .font(.caption2).foregroundStyle(.secondary)
        }.padding(20).background(NativeTheme.surface, in: RoundedRectangle(cornerRadius: 26))
    }
}

private struct ExploreDetailView: View {
    let item: ExploreItem
    let connection: SharedEnvironment
    @Environment(\.openURL) private var openURL
    @State private var offerExpired = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(item.product.title).font(.largeTitle.bold())
                if let description = item.product.description { Text(description).foregroundStyle(.secondary) }
                IntelligenceCard(title: "From the catalog", symbol: "tag") {
                    LabeledContent(isCurrentMerchantOffer(item.product) ? "Price" : "Recorded price", value: catalogCurrencyText(item.product.offer.priceMinor, currency: item.product.offer.currency))
                    LabeledContent("Merchant", value: item.product.merchant.name ?? "Unknown")
                    LabeledContent("Availability", value: availability)
                    if let shipping = item.product.offer.shippingMinor { LabeledContent("Shipping", value: catalogCurrencyText(shipping, currency: item.product.offer.currency)) }
                    if !isCurrentMerchantOffer(item.product) {
                        Text("This is a source record, not a verified current offer. Confirm details with the seller.").font(.footnote).foregroundStyle(.secondary)
                    }
                    if currentOfferURL != nil, !offerExpired {
                        Button("View offer") {
                            // Recheck at the tap: the observation can expire while
                            // this view is visible without another SwiftUI render.
                            guard let url = currentOfferURL else { offerExpired = true; return }
                            openURL(url)
                        }.font(.headline)
                    } else if let url = webURL(item.catalogCitation.recordUrl ?? item.actionUrl) {
                        Link("View source record", destination: url).font(.headline)
                    }
                    if offerExpired { Text("The offer information is no longer current. You can still inspect its source record.").font(.footnote).foregroundStyle(.secondary) }
                }
                IntelligenceCard(title: "Why this?", symbol: "sparkles") {
                    ForEach(Array(item.reasons.enumerated()), id: \.offset) { _, reason in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(reason.text).font(.subheadline)
                            if let id = reason.savedItemId {
                                NavigationLink {
                                    SavedEvidenceView(id: id, connection: connection)
                                } label: { Label(reason.savedItemTitle ?? "View saved evidence", systemImage: "bookmark").font(.subheadline) }
                            }
                            if let field = reason.catalogField, let value = reason.catalogValue {
                                Text("Catalog: \(field.replacingOccurrences(of: "_", with: " ")) · \(value)").font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 4)
                    }
                }
                IntelligenceCard(title: "Source", symbol: "link") {
                    Text(item.catalogCitation.title).font(.headline)
                    Text(item.catalogCitation.attribution ?? item.catalogCitation.sourceId.rawValue).font(.subheadline).foregroundStyle(.secondary)
                    if let license = item.catalogCitation.licenseId { Text(license).font(.caption).foregroundStyle(.secondary) }
                    if let url = webURL(item.catalogCitation.licenseUrl) { Link("Source license", destination: url) }
                }
            }.padding(24)
        }.navigationTitle("A possibility").navigationBarTitleDisplayMode(.inline)
    }
    private var currentOfferURL: URL? {
        guard item.action == .viewOffer, isCurrentMerchantOffer(item.product),
              let url = webURL(item.actionUrl), url.scheme == "https",
              url == webURL(item.product.offer.url) else { return nil }
        return url
    }
    private var availability: String {
        switch item.product.offer.availability {
        case "in_stock": return isCurrentMerchantOffer(item.product) ? "Reported in stock" : "Previously listed in stock"
        case "out_of_stock": return "Reported out of stock"
        default: return "Unknown"
        }
    }
}

/// Citation routes fetch exactly the saved-item ID supplied by the server.
struct SavedEvidenceView: View {
    let id: String
    let connection: SharedEnvironment
    @State private var item: SavedItem?
    @State private var errorMessage: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let item {
                    Text(item.title).font(.largeTitle.bold())
                    if !item.note.isEmpty { Text(item.note).font(.body) }
                    if !item.selectedText.isEmpty { Text(item.selectedText).foregroundStyle(.secondary) }
                    if let url = webURL(item.originalUrl) { Link("Open original", destination: url) }
                    SavedIntelligenceSection(item: item, connection: connection)
                } else if let errorMessage { ContentUnavailableView("Evidence unavailable", systemImage: "bookmark.slash", description: Text(errorMessage)) }
                else { ProgressView("Loading your find").frame(maxWidth: .infinity) }
            }.padding(24)
        }
        .navigationTitle("Saved evidence").navigationBarTitleDisplayMode(.inline)
        .task(id: id) {
            do { let api = try await connection.intelligenceClient(); let loaded = try await api.savedItem(id); try Task.checkCancellation(); item = loaded }
            catch is CancellationError {} catch { if !Task.isCancelled { errorMessage = error.localizedDescription } }
        }
    }
}

/// Server-backed search including analyzed product/category facets, with bounded paging.
struct SharedLibrarySearchScreen: View {
    let connection: SharedEnvironment
    let onDelete: (String, MutationKey) async throws -> Void
    @State private var query = ""
    @State private var category = ""
    @State private var items: [SavedItem] = []
    @State private var total = 0
    @State private var nextOffset: Int?
    @State private var requestedOffset = 0
    @State private var refreshID = UUID()
    @State private var busy = false
    @State private var errorMessage: String?
    var body: some View {
        List {
            Section {
                TextField("Category, optional", text: $category).autocorrectionDisabled()
                if !query.isEmpty || !category.isEmpty { Text("\(total) matching finds").font(.caption).foregroundStyle(.secondary) }
            }
            ForEach(items) { item in
                NavigationLink {
                    SavedContentView(item: item, stillSaved: items.contains { $0.id == item.id }, connection: connection, onDelete: { id, key in
                        try await onDelete(id, key)
                        items.removeAll { $0.id == id }; total = max(0, total - 1)
                    })
                } label: { SavedContentCard(item: item, compact: true, connection: connection) }
                .listRowSeparator(.hidden).listRowBackground(Color.clear)
            }
            if busy { ProgressView("Searching your library") }
            if let errorMessage { Section { Text(errorMessage).foregroundStyle(.secondary); Button("Try again") { refreshID = UUID() } } }
            if !busy, errorMessage == nil, items.isEmpty { ContentUnavailableView.search(text: query) }
            if let nextOffset, !busy { Button("Load more") { requestedOffset = nextOffset } }
        }
        .navigationTitle("Search library").searchable(text: $query, prompt: "Words, styles, categories")
        .onChange(of: query) { _, _ in requestedOffset = 0; items = [] }
        .onChange(of: category) { _, _ in requestedOffset = 0; items = [] }
        .task(id: "\(connectionIdentity(connection))|\(query)|\(category)|\(requestedOffset)|\(refreshID)") { await search() }
    }
    @MainActor private func search() async {
        busy = true; errorMessage = nil
        defer { if !Task.isCancelled { busy = false } }
        do {
            try await Task.sleep(for: .milliseconds(300))
            let categoryFilter = category.trimmingCharacters(in: .whitespacesAndNewlines)
            let api = try await connection.intelligenceClient()
            let result = try await api.searchLibrary(query: query, category: categoryFilter.isEmpty ? nil : categoryFilter, offset: requestedOffset)
            try Task.checkCancellation()
            if requestedOffset == 0 { items = result.items }
            else { let ids = Set(items.map(\.id)); items += result.items.filter { !ids.contains($0.id) } }
            total = result.total; nextOffset = result.nextOffset
        } catch is CancellationError {} catch { if !Task.isCancelled { errorMessage = error.localizedDescription } }
    }
}
