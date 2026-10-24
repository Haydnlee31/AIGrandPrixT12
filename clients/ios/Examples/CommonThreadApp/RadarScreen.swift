import SwiftUI
import CommonThreadKit

struct RadarScreen: View {
    var libraryRevision = ""
    var onChanged: () -> Void = {}
    @State private var finds: [SavedItem] = []
    @State private var metadata: [String: LocalFindMetadata] = [:]
    @State private var watches: [RadarWatch] = []
    @State private var customIntent = ""
    @FocusState private var typingIntent: Bool
    @State private var editor: RadarBriefEditorContext?
    @State private var reviewedBrief: RadarBrief?
    @State private var tracking: RadarWatch?
    @State private var request: RadarMatchRequest?
    @State private var showingMatches = false
    @State private var page: LocalRecommendationPage?
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var activeRequestID: UUID?
    #if DEBUG
    @State private var priceReviewURL: URL?
    @State private var showingPriceReview = false
    #endif
    @Environment(\.dynamicTypeSize) private var typeSize
    private var suggestions: [RadarSuggestion] {
        var result: [RadarSuggestion] = []; var used = Set<String>()
        for find in finds.prefix(10) {
            let context = metadata[find.id] ?? LocalFindMetadata()
            let name = context.analysis?.productName ?? find.title
            let candidates = context.selectedIntents + (find.note.isEmpty ? [] : [find.note]) + ["Explore more like \(name)"]
            for text in candidates where result.count < 5 {
                let title = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(180))
                guard !title.isEmpty, used.insert(title.lowercased()).inserted else { continue }
                result.append(RadarSuggestion(id: find.id + ":" + title, title: title, sourceID: find.id))
            }
            if result.count == 5 { break }
        }
        return result
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    introduction
                    if !suggestions.isEmpty { suggestedIntentions }
                    PriceWatchListSection()
                    if !watches.isEmpty { trackedNeeds }
                    if !showingMatches, let errorMessage { Text(errorMessage).font(.footnote).foregroundStyle(.secondary) }
                }.padding(20).padding(.bottom, 20)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(NativeTheme.bg)
            .navigationTitle("Radar").navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $showingMatches) {
                if let request { matches(for: request) }
            }
            .task(id: libraryRevision) { await load() }
            #if DEBUG
            .task {
                let args = ProcessInfo.processInfo.arguments
                if let index = args.firstIndex(of: "-showPriceCheck"), args.indices.contains(index + 1),
                   let url = PriceMoney.exactURL(args[index + 1]) {
                    priceReviewURL = url; showingPriceReview = true
                }
                if let index = args.firstIndex(of: "-reviewBudget"), args.indices.contains(index + 1) {
                    var brief = RadarBrief(); brief.intention = String(args[index + 1].prefix(300))
                    editor = RadarBriefEditorContext(brief: brief)
                }
            }
            .sheet(isPresented: $showingPriceReview) {
                NavigationStack {
                    ScrollView {
                        if let url = priceReviewURL { LivePricePanel(url: url, title: "Amazon listing").padding(24) }
                    }.background(NativeTheme.bg).navigationTitle("Price check").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingPriceReview = false } } }
                }
            }
            #endif
            .task(id: (request?.id.uuidString ?? "") + "|" + libraryRevision) {
                if showingMatches, let request { await findMatches(request) }
            }
            .onChange(of: showingMatches) { _, visible in
                typingIntent = false
                if !visible { request = nil; activeRequestID = nil; busy = false }
            }
            .sheet(item: $editor, onDismiss: {
                typingIntent = false
                if let reviewedBrief {
                    self.reviewedBrief = nil
                    showMatches(RadarMatchRequest(brief: reviewedBrief, watch: nil))
                }
            }) { context in
                RadarBriefEditor(brief: context.brief) { reviewedBrief = $0 }
            }
            .sheet(item: $tracking) { watch in
                RadarWatchEditor(watch: watch) { value in
                    do {
                        try await RadarStore.shared.save(value)
                        watches = try await RadarStore.shared.all()
                        FindsHaptics.success(); return true
                    } catch { errorMessage = error.localizedDescription; return false }
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { typingIntent = false } }
            }
        }
    }
    private var introduction: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "dot.radiowaves.left.and.right").font(.title.weight(.semibold)).foregroundStyle(.purple)
                .frame(width: 56, height: 56).background(Color.purple.opacity(0.1), in: RoundedRectangle(cornerRadius: 18))
            Text("What’s on your mind?").font(.largeTitle.bold()).tracking(-0.7)
            HStack(spacing: 10) {
                TextField("What would you love to find?", text: $customIntent, axis: .vertical)
                    .lineLimit(1...3).focused($typingIntent).submitLabel(.search).onSubmit { openCustomIntent() }
                    .accessibilityIdentifier("radarIntention")
                Button(action: openCustomIntent) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 32)).foregroundStyle(.purple).frame(width: 44, height: 44)
                }.disabled(customIntent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Review this intention")
            }.padding(14).background(NativeTheme.surface, in: RoundedRectangle(cornerRadius: 22))
        }
    }
    private var suggestedIntentions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("On your mind").font(.headline.bold())
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                Button {
                    guard let find = finds.first(where: { $0.id == suggestion.sourceID }) else { return }
                    typingIntent = false
                    editor = RadarBriefEditorContext(brief: brief(for: find, intention: suggestion.title))
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: ["sparkles", "heart", "scope", "bookmark", "lightbulb"][index % 5])
                            .font(.body.weight(.semibold)).foregroundStyle(index.isMultiple(of: 2) ? .purple : .blue)
                            .frame(width: 36, height: 36)
                        Text(suggestion.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                            .lineLimit(2).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
                    }.padding(12).background(NativeTheme.surface, in: RoundedRectangle(cornerRadius: 20))
                }.buttonStyle(.plain)
            }
        }
    }
    private func matches(for request: RadarMatchRequest) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 9) {
                    Text(request.watch?.scope == .need ? request.watch!.target : request.brief.intention)
                        .font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
                    if !request.brief.budget.isEmpty {
                        Text("Budget: \(RadarBudgetSlider.label(request.brief))").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                if busy {
                    ProgressView("Finding your matches…").frame(maxWidth: .infinity).padding(.vertical, 65)
                } else if let errorMessage {
                    ContentUnavailableView {
                        Label("Couldn’t load matches", systemImage: "wifi.exclamationmark")
                    } description: { Text(errorMessage) } actions: {
                        Button("Try again") { showMatches(RadarMatchRequest(brief: request.brief, watch: request.watch)) }.buttonStyle(.borderedProminent)
                    }
                } else if let page, !page.items.isEmpty {
                    HStack {
                        Text("\(page.items.count) matches").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        Spacer()
                        Button { tracking = RadarWatch(brief: request.brief, target: request.brief.intention) } label: {
                            Label("Track need", systemImage: "dot.radiowaves.left.and.right").font(.subheadline.weight(.semibold))
                        }.tint(.purple)
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: typeSize.isAccessibilitySize ? 1 : 2), spacing: 24) {
                        ForEach(page.items) { item in
                            NavigationLink {
                                RadarProductDetail(item: item, finds: finds, onSourceChange: {
                                    onChanged(); Task { await load() }
                                }) {
                                    var brief = request.brief; brief.product = item.title
                                    tracking = RadarWatch(brief: brief, scope: .product, target: item.title)
                                }
                            } label: { RadarProductCard(item: item) }.buttonStyle(.plain)
                        }
                    }
                    Text("Catalog matches · Check current prices at the retailer.").font(.caption).foregroundStyle(.secondary)
                } else {
                    ContentUnavailableView {
                        Label(page?.status == "needs_clarification" ? "A little more detail" : "No close matches yet", systemImage: "sparkle.magnifyingglass")
                    } description: { Text(emptyMatchesMessage) } actions: {
                        Button("Edit intention") { editor = RadarBriefEditorContext(brief: request.brief) }.buttonStyle(.bordered)
                    }
                }
            }.padding(20)
        }.scrollDismissesKeyboard(.interactively).background(NativeTheme.bg)
            .navigationTitle("Matches").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) {
                Button("Edit", systemImage: "slider.horizontal.3") { editor = RadarBriefEditorContext(brief: request.brief) }
            } }
    }
    private var emptyMatchesMessage: String {
        switch page?.status {
        case "needs_clarification", "needs_analysis": "Try naming a product, style, or what you want it to do."
        case "catalog_unavailable": "The catalog is unavailable right now. Please try again shortly."
        default: "Try a broader description or a different product."
        }
    }
    private var trackedNeeds: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack { Text("Tracking").font(.title2.bold()); Spacer(); Text("Manual checks").font(.caption).foregroundStyle(.secondary) }
            ForEach(watches) { watch in
                HStack(spacing: 12) {
                    Button { showMatches(RadarMatchRequest(brief: watch.brief, watch: watch)) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: watch.isPaused ? "pause.circle" : "dot.radiowaves.left.and.right").font(.title3).foregroundStyle(.purple)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(watch.target).font(.subheadline.bold()).foregroundStyle(.primary).lineLimit(2)
                                Text(watch.isPaused ? "Paused" : "Tap to check matches").font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.buttonStyle(.plain).disabled(watch.isPaused)
                    Menu {
                        Button("Edit", systemImage: "pencil") { typingIntent = false; tracking = watch }
                        Button(watch.isPaused ? "Resume" : "Pause", systemImage: watch.isPaused ? "play" : "pause") {
                            Task { await updateWatch { try await RadarStore.shared.setPaused(watch.id, !watch.isPaused) } }
                        }
                        Button("Remove", systemImage: "trash", role: .destructive) {
                            Task { await updateWatch { try await RadarStore.shared.remove(watch.id) } }
                        }
                    } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.accessibilityLabel("Tracking options")
                }.padding(14).background(NativeTheme.surface, in: RoundedRectangle(cornerRadius: 22))
            }
        }
    }
    private func openCustomIntent() {
        guard !customIntent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        typingIntent = false
        var value = RadarBrief(); value.intention = String(customIntent.prefix(300))
        editor = RadarBriefEditorContext(brief: value)
    }
    private func showMatches(_ value: RadarMatchRequest) {
        typingIntent = false; page = nil; errorMessage = nil; busy = true
        request = value; showingMatches = true
    }
    private func brief(for find: SavedItem, intention: String) -> RadarBrief {
        let context = metadata[find.id] ?? LocalFindMetadata()
        var value = RadarBrief(); value.intention = String(intention.prefix(300)); value.sourceIDs = [find.id]
        value.product = context.analysis?.productName ?? find.title; value.brand = context.analysis?.brand ?? ""
        value.category = context.analysis?.categoryPath.last ?? ""
        return value
    }
    @discardableResult @MainActor private func load() async -> Bool {
        do {
            let loadedMetadata = try await LocalLibrary.shared.metadata()
            let loadedFinds = try await LocalLibrary.shared.collection()
            let loadedWatches = try await RadarStore.shared.all()
            try Task.checkCancellation()
            metadata = loadedMetadata
            finds = loadedFinds.filter { $0.client != "sample" && !(loadedMetadata[$0.id]?.isArchived ?? false) }.sorted { $0.capturedAt > $1.capturedAt }
            watches = loadedWatches
            return true
        } catch is CancellationError { return false } catch {
            if !Task.isCancelled { errorMessage = error.localizedDescription }
            return false
        }
    }
    @MainActor private func updateWatch(_ change: () async throws -> Void) async {
        do { try await change(); watches = try await RadarStore.shared.all(); FindsHaptics.selection() }
        catch { errorMessage = error.localizedDescription }
    }
    @MainActor private func findMatches(_ request: RadarMatchRequest) async {
        guard !Task.isCancelled, self.request?.id == request.id else { return }
        let token = UUID(); activeRequestID = token; busy = true; errorMessage = nil; page = nil
        defer { if activeRequestID == token { busy = false } }
        do {
            guard await load() else { return }
            try Task.checkCancellation()
            let result = try await RadarMatchingService.fetch(brief: request.brief, watch: request.watch, finds: finds, metadata: metadata, force: true)
            try Task.checkCancellation()
            guard activeRequestID == token, self.request?.id == request.id else { return }
            page = result
            if let watch = request.watch, ["ready", "no_matches"].contains(result.status) {
                try await RadarStore.shared.recordCheck(watch)
                let latest = try await RadarStore.shared.all()
                try Task.checkCancellation()
                guard activeRequestID == token, self.request?.id == request.id else { return }
                watches = latest
            }
        } catch is CancellationError {} catch {
            if activeRequestID == token, self.request?.id == request.id, !Task.isCancelled { errorMessage = error.localizedDescription }
        }
    }
}

private struct RadarSuggestion: Identifiable { let id: String; let title: String; let sourceID: String }
private struct RadarBriefEditorContext: Identifiable { let id = UUID(); let brief: RadarBrief }
private struct RadarMatchRequest: Identifiable { let id = UUID(); let brief: RadarBrief; let watch: RadarWatch? }

private struct RadarBriefEditor: View {
    @State var brief: RadarBrief
    let onShow: (RadarBrief) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var editing: Bool
    @State private var errorMessage: String?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Your intention").font(.title2.bold())
                        TextField("What would you love to find?", text: $brief.intention, axis: .vertical)
                            .lineLimit(3...6).focused($editing).font(.body)
                            .padding(18).background(NativeTheme.surface, in: RoundedRectangle(cornerRadius: 22))
                    }
                    RadarBudgetSlider(brief: $brief)
                    if let errorMessage { Text(errorMessage).font(.footnote).foregroundStyle(.red) }
                }.padding(24)
            }.scrollDismissesKeyboard(.interactively).background(NativeTheme.bg)
                .navigationTitle("Make it yours").navigationBarTitleDisplayMode(.inline)
                .safeAreaInset(edge: .bottom) {
                    NativePrimaryButton(title: "Show matches") {
                        do {
                            editing = false
                            // Retired form controls must not silently constrain a new search.
                            brief.searchTerms = ""; brief.mustHaves = ""; brief.fitNotes = ""; brief.smallSpace = false
                            let value = try brief.validated(); onShow(value); dismiss()
                        } catch { errorMessage = error.localizedDescription }
                    }.disabled(!brief.intention.contains(where: { $0.isLetter || $0.isNumber }))
                        .padding(20).background(.bar)
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { editing = false; dismiss() } }
                    ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { editing = false } }
                }
        }
    }
}

private struct RadarBudgetSlider: View {
    @Binding var brief: RadarBrief
    var target: String? = nil
    @State private var preservedBudget: String?
    private var steps: [Double] {
        var context = brief
        // Keep the scale stable while dragging, including a previously saved
        // amount outside the normal range. Reconsider it only for a new product.
        context.budget = preservedBudget ?? brief.budget
        return RadarBudgetScale.steps(for: context, target: target)
    }
    private var position: Binding<Double> {
        Binding(get: {
            let amount = Double(brief.budget) ?? 0
            return Double(steps.indices.min(by: { abs(steps[$0] - amount) < abs(steps[$1] - amount) }) ?? 0)
        }, set: { index in
            let value = steps[min(max(Int(index.rounded()), 0), steps.count - 1)]
            brief.budget = RadarBudgetScale.storedValue(value)
        })
    }
    static func label(_ brief: RadarBrief) -> String {
        RadarBudgetScale.label(amount: Double(brief.budget) ?? 0, currency: brief.currency)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("Budget").font(.headline.bold()); Spacer(); Text(Self.label(brief)).font(.headline).foregroundStyle(.purple).monospacedDigit() }
            Slider(value: position, in: 0...Double(steps.count - 1), step: 1).tint(.purple)
                .accessibilityLabel("Maximum budget").accessibilityValue(Self.label(brief))
            HStack { Text("Any"); Spacer(); Text(RadarBudgetScale.label(amount: steps.last ?? 2000, currency: brief.currency)) }.font(.caption).foregroundStyle(.secondary)
            Text("Confirm current prices on Amazon.").font(.caption).foregroundStyle(.secondary)
        }.padding(18).background(NativeTheme.surface, in: RoundedRectangle(cornerRadius: 22))
            .onAppear { preservedBudget = brief.budget }
            .onChange(of: brief.intention) { _, _ in preservedBudget = brief.budget }
            .onChange(of: target) { _, _ in preservedBudget = brief.budget }
    }
}

private struct RadarWatchEditor: View {
    @State var watch: RadarWatch
    let onSave: (RadarWatch) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @FocusState private var editing: Bool
    @State private var saving = false
    @State private var errorMessage: String?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Track", selection: $watch.scope) { ForEach(RadarScope.allCases) { Text($0.title).tag($0) } }
                    TextField("What do you want to track?", text: $watch.target, axis: .vertical).lineLimit(2...4).focused($editing)
                }
                Section { RadarBudgetSlider(brief: $watch.brief, target: watch.target).listRowInsets(EdgeInsets()).listRowBackground(Color.clear) }
                if let errorMessage { Text(errorMessage).font(.footnote).foregroundStyle(.red) }
                Section { Text("Check for new matches whenever you return to Radar.").font(.footnote).foregroundStyle(.secondary) }
            }.scrollDismissesKeyboard(.interactively)
                .navigationTitle("Track this").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { editing = false; dismiss() }.disabled(saving) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            do {
                                editing = false
                                if watch.scope == .need { watch.brief.intention = watch.target }
                                watch.brief.searchTerms = ""; watch.brief.mustHaves = ""; watch.brief.smallSpace = false; watch.brief.fitNotes = ""
                                watch.frequency = .manually
                                let value = try watch.validated(); saving = true
                                Task {
                                    if await onSave(value) { dismiss() } else { errorMessage = "Couldn’t save this need. Try again." }
                                    saving = false
                                }
                            } catch { errorMessage = error.localizedDescription }
                        }.bold().disabled(saving || !watch.target.contains(where: { $0.isLetter || $0.isNumber }))
                    }
                    ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { editing = false } }
                }
                .onChange(of: watch.scope) { _, scope in watch.target = scope.suggestedTarget(for: watch.brief) }
        }.interactiveDismissDisabled(saving)
    }
}

private struct RadarProductCard: View {
    let item: LocalRecommendation
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CatalogProductImage(url: item.imageURL.flatMap(URL.init(string:)), height: 170, fit: true).clipShape(RoundedRectangle(cornerRadius: 21))
            Text(item.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(2)
            if let reason = item.reasons.first {
                Label(reason.text, systemImage: "sparkles").font(.caption).foregroundStyle(.purple).lineLimit(2)
            }
        }.frame(maxWidth: .infinity, alignment: .topLeading).accessibilityElement(children: .combine)
    }
}

private struct RadarProductDetail: View {
    let item: LocalRecommendation
    let finds: [SavedItem]
    let onSourceChange: () -> Void
    let onTrack: () -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                CatalogProductImage(url: item.imageURL.flatMap(URL.init(string:)), height: 300, fit: true).clipShape(RoundedRectangle(cornerRadius: 26))
                Text(item.title).font(.title2.bold())
                if let url = item.exactAmazonURL { LivePricePanel(url: url, title: item.title) }
                VStack(alignment: .leading, spacing: 14) {
                    Label("Why it fits", systemImage: "sparkles").font(.headline).foregroundStyle(.purple)
                    ForEach(item.reasons.prefix(3)) { reason in
                        Text(reason.text).font(.subheadline)
                        if let find = finds.first(where: { $0.id == reason.findID }) {
                            NavigationLink {
                                SavedContentView(item: find, stillSaved: true, localOnly: true, onChanged: onSourceChange,
                                    onDelete: { id, _ in try await LocalLibrary.shared.delete(id); onSourceChange() })
                            } label: { Label(find.title, systemImage: "bookmark").font(.caption).lineLimit(2) }
                        }
                    }
                }
                HStack(spacing: 14) {
                    if let url = item.exactAmazonURL { Link("View on Amazon", destination: url).font(.headline).buttonStyle(.borderedProminent) }
                    Button(action: onTrack) { Image(systemName: "dot.radiowaves.left.and.right").frame(width: 44, height: 44) }.buttonStyle(.bordered).accessibilityLabel("Track this product")
                }
                Text("Check current price and availability on Amazon.").font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("Product source") {
                    VStack(alignment: .leading, spacing: 10) {
                        if let url = safeURL(item.sourceURL) { Link(item.sourceName, destination: url) }
                        if let attribution = item.attribution { Text(attribution) }
                        if let url = item.licenseURL.flatMap(safeURL) { Link("License", destination: url) }
                    }.font(.footnote).padding(.top, 10)
                }.font(.subheadline).tint(.secondary)
            }.padding(20)
        }.background(NativeTheme.bg).navigationTitle("Your match").navigationBarTitleDisplayMode(.inline)
    }
    private func safeURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil, url.user == nil, url.password == nil else { return nil }
        return url
    }
}
