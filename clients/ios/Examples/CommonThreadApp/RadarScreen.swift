import SwiftUI
import CommonThreadKit

struct RadarScreen: View {
    var libraryRevision = ""
    var onChanged: () -> Void = {}
    @State private var finds: [SavedItem] = []
    @State private var metadata: [String: LocalFindMetadata] = [:]
    @State private var watches: [RadarWatch] = []
    @State private var customIntent = ""
    @State private var editor: RadarBriefEditorContext?
    @State private var tracking: RadarWatch?
    @State private var request: RadarMatchRequest?
    @State private var page: LocalRecommendationPage?
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var sort = RadarMatchSort.bestFit
    @State private var activeRequestID: UUID?
    private var suggestions: [RadarSuggestion] {
        var result: [RadarSuggestion] = []
        var used = Set<String>()
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
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        introduction
                        if !suggestions.isEmpty { suggestedIntentions }
                        if let request {
                            matches(for: request).id("radarMatches")
                        }
                        if !finds.isEmpty { sourceSaves }
                        trackedNeeds
                        if let errorMessage {
                            Text(errorMessage).font(.subheadline).foregroundStyle(.secondary)
                            if let request {
                                Button("Try again", systemImage: "arrow.clockwise") {
                                    self.request = RadarMatchRequest(brief: request.brief, watch: request.watch)
                                }.disabled(busy)
                            }
                        }
                    }.padding(20).padding(.bottom, 20)
                }
                .onChange(of: request?.id) { _, id in
                    if id != nil { withAnimation(.easeInOut(duration: 0.25)) { scroll.scrollTo("radarMatches", anchor: .top) } }
                }
            }
            .background(NativeTheme.bg)
            .navigationTitle("Intent Radar").navigationBarTitleDisplayMode(.inline)
            .task(id: libraryRevision) { await load() }
            .task(id: (request?.id.uuidString ?? "") + "|" + libraryRevision) {
                if let request { await findMatches(request) }
            }
            .sheet(item: $editor) { context in
                RadarBriefEditor(brief: context.brief, finds: finds) { reviewed in
                    page = nil; errorMessage = nil; sort = .bestFit
                    request = RadarMatchRequest(brief: reviewed, watch: nil)
                }
            }
            .sheet(item: $tracking) { watch in
                RadarWatchEditor(watch: watch, finds: finds) { value in
                    do {
                        try await RadarStore.shared.save(value)
                        watches = try await RadarStore.shared.all()
                        FindsHaptics.success()
                        return true
                    } catch { errorMessage = error.localizedDescription; return false }
                }
            }
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 15) {
            Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 28, weight: .semibold)).foregroundStyle(.purple)
                .frame(width: 58, height: 58).background(Color.purple.opacity(0.1), in: RoundedRectangle(cornerRadius: 19))
            Text("What’s on your mind?").font(.largeTitle.bold()).tracking(-0.7)
            Text("Start with a feeling. Make it a find.").font(.body).foregroundStyle(.secondary)
            HStack(alignment: .center, spacing: 10) {
                TextField("Something you’re looking for…", text: $customIntent, axis: .vertical)
                    .lineLimit(1...3).font(.body).submitLabel(.continue)
                Button { openCustomIntent() } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 31)).foregroundStyle(.purple)
                        .frame(width: 44, height: 44)
                }.disabled(customIntent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Review this intention")
            }.padding(14).background(NativeTheme.surface, in: RoundedRectangle(cornerRadius: 22))
            if finds.isEmpty {
                Text("Save an example in Library to ground your first search. You can still write down a need here.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
    private var suggestedIntentions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("A few starting points").font(.headline.bold())
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                Button {
                    guard let find = finds.first(where: { $0.id == suggestion.sourceID }) else { return }
                    editor = RadarBriefEditorContext(brief: brief(for: find, intention: suggestion.title))
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: ["sparkles", "heart", "scope", "bookmark", "lightbulb"][index % 5])
                            .font(.system(size: 17, weight: .semibold)).foregroundStyle(index.isMultiple(of: 2) ? .purple : .blue)
                            .frame(width: 36, height: 36).background(Color.purple.opacity(0.07), in: Circle())
                        Text(suggestion.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                            .lineLimit(2).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "arrow.up.left").font(.caption.bold()).foregroundStyle(.secondary)
                    }.padding(12).background(NativeTheme.surface, in: RoundedRectangle(cornerRadius: 20))
                }.buttonStyle(.plain)
            }
        }
    }
    @ViewBuilder private func matches(for request: RadarMatchRequest) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Your intention").font(.caption.weight(.semibold)).foregroundStyle(.purple)
                    Text(request.brief.intention).font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button { editor = RadarBriefEditorContext(brief: request.brief) } label: { Image(systemName: "pencil").frame(width: 44, height: 44) }
                    .accessibilityLabel("Edit your interpretation")
            }
            Button {
                tracking = RadarWatch(brief: request.brief, target: request.brief.intention)
            } label: {
                Label("Track my need", systemImage: "dot.radiowaves.left.and.right")
                    .font(.subheadline.bold()).padding(.vertical, 10).padding(.horizontal, 15)
                    .background(Color.purple.opacity(0.1), in: Capsule())
            }.buttonStyle(.plain).foregroundStyle(.purple)
            Picker("Match order", selection: $sort) {
                ForEach(RadarMatchSort.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            if sort != .bestFit {
                Label(sort == .price ? "Live prices aren’t available. Matches remain in best-fit order." : "Comparable quality evidence isn’t available. Matches remain in best-fit order.", systemImage: "info.circle")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if !request.brief.budget.isEmpty || request.brief.smallSpace || !request.brief.fitNotes.isEmpty {
                Text("Your budget and fit preferences are saved in this brief. Check price and dimensions at the retailer.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if busy { ProgressView("Looking through the catalog…").font(.subheadline).padding(.vertical, 20) }
            if let page, !page.items.isEmpty {
                ForEach(page.items.prefix(10)) { item in
                    RadarOpportunityCard(item: item, finds: finds.filter { request.brief.sourceIDs.contains($0.id) }, onSourceChange: {
                        onChanged(); Task { await load() }
                    }) {
                        var brief = request.brief; brief.product = item.title
                        tracking = RadarWatch(brief: brief, scope: .product, target: item.title)
                    }
                }
            } else if !busy {
                Text(emptyMatchesMessage).font(.body).foregroundStyle(.secondary).padding(.vertical, 8)
            }
        }
    }
    private var emptyMatchesMessage: String {
        if !CaptureIntelligence.isConfigured { return "Connect shopping intelligence in Profile to check this need." }
        switch page?.status {
        case "needs_analysis": return "Open one of your saved examples so Mynah can understand it, then try again."
        case "needs_saves": return "Choose a saved example in your interpretation to ground these matches."
        case "catalog_unavailable": return "The catalog is unavailable right now. Your need can still be saved locally."
        default: return "No close matches yet. Try fewer search terms or adjust your interpretation."
        }
    }
    private var sourceSaves: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Based on your saves").font(.headline.bold())
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(finds.filter { request == nil || request!.brief.sourceIDs.contains($0.id) }.prefix(8)) { find in
                        NavigationLink {
                            SavedContentView(item: find, stillSaved: finds.contains(where: { $0.id == find.id }), localOnly: true,
                                onChanged: { onChanged(); Task { await load() } },
                                onDelete: { id, _ in try await LocalLibrary.shared.delete(id); onChanged(); await load() })
                        } label: { SavedContentCard(item: find, compact: true).frame(width: 260) }.buttonStyle(.plain)
                    }
                }
            }.scrollIndicators(.hidden)
        }
    }
    private var trackedNeeds: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("Your radar").font(.title2.bold())
            Text("Saved on this iPhone. Check now runs a catalog search; background checks and alerts aren’t connected.")
                .font(.footnote).foregroundStyle(.secondary)
            if watches.isEmpty {
                Text("A need worth keeping? Track it after reviewing your intention.")
                    .font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 10)
            }
            ForEach(watches) { watch in
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(watch.target).font(.headline.bold()).lineLimit(2)
                            Text(watch.isPaused ? "Paused" : "Saved locally · \(watch.scope.title)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Menu {
                            Button("Edit need", systemImage: "pencil") { tracking = watch }
                            Button(watch.isPaused ? "Resume" : "Pause", systemImage: watch.isPaused ? "play" : "pause") {
                                Task { await updateWatch { try await RadarStore.shared.setPaused(watch.id, !watch.isPaused) } }
                            }
                            Button("Remove need", systemImage: "trash", role: .destructive) {
                                Task { await updateWatch { try await RadarStore.shared.remove(watch.id) } }
                            }
                        } label: { Image(systemName: "ellipsis").frame(width: 36, height: 36) }.accessibilityLabel("Options for \(watch.target)")
                    }
                    if !watch.conditions.isEmpty { Text(watch.conditions).font(.subheadline).foregroundStyle(.secondary).lineLimit(2) }
                    HStack {
                        Button("Check now", systemImage: "arrow.clockwise") {
                            page = nil; sort = .bestFit
                            request = RadarMatchRequest(brief: watch.brief, watch: watch)
                        }.font(.subheadline.weight(.semibold)).disabled(busy || watch.isPaused)
                        Spacer()
                        if let checked = watch.lastCheckedAt {
                            (Text("Checked ") + Text(checked, style: .relative)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.padding(17).background(NativeTheme.surface, in: RoundedRectangle(cornerRadius: 23))
            }
        }
    }
    private func openCustomIntent() {
        var value = RadarBrief(); value.intention = String(customIntent.prefix(300))
        editor = RadarBriefEditorContext(brief: value)
    }
    private func brief(for find: SavedItem, intention: String) -> RadarBrief {
        let context = metadata[find.id] ?? LocalFindMetadata()
        var value = RadarBrief()
        value.intention = String(intention.prefix(300)); value.sourceIDs = [find.id]
        value.mustHaves = String(context.selectedIntents.joined(separator: "; ").prefix(500))
        value.product = context.analysis?.productName ?? find.title
        value.brand = context.analysis?.brand ?? ""
        value.category = context.analysis?.categoryPath.last ?? ""
        return value
    }
    @MainActor private func load() async {
        do {
            let loadedMetadata = try await LocalLibrary.shared.metadata()
            let loadedFinds = try await LocalLibrary.shared.collection()
            let loadedWatches = try await RadarStore.shared.all()
            try Task.checkCancellation()
            metadata = loadedMetadata
            finds = loadedFinds.filter { $0.client != "sample" && !(loadedMetadata[$0.id]?.isArchived ?? false) }.sorted { $0.capturedAt > $1.capturedAt }
            watches = loadedWatches
        } catch is CancellationError {} catch { if !Task.isCancelled { errorMessage = error.localizedDescription } }
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
            await load(); try Task.checkCancellation()
            guard activeRequestID == token, self.request?.id == request.id else { return }
            guard CaptureIntelligence.isConfigured else { throw CaptureIntelligence.Failure.configuration }
            let selected = finds.filter { request.brief.sourceIDs.contains($0.id) }.prefix(24)
            guard !selected.isEmpty else { throw RadarMatchError.noSources }
            let input: [[String: Any]] = try selected.map { find in
                let context = metadata[find.id] ?? LocalFindMetadata()
                let userDetails = [request.brief.mustHaves, request.watch?.conditions ?? "", request.brief.fitNotes].filter { !$0.isEmpty }
                let currentIntention = request.watch?.scope == .need ? request.watch!.target : request.brief.intention
                var value: [String: Any] = ["id": find.id, "title": find.title, "text": find.selectedText,
                    "note": String(("Current intention: " + currentIntention + "\n" + find.note).prefix(2000)),
                    "intents": Array((userDetails + context.selectedIntents).prefix(8))]
                if let analysis = context.analysis { value["analysis"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(analysis)) }
                return value
            }
            let query: String
            if let watch = request.watch, watch.scope != .need { query = watch.target }
            else { query = request.brief.searchTerms }
            let payload = try JSONSerialization.data(withJSONObject: ["finds": input, "query": String(query.prefix(100)), "limit": 12], options: [.sortedKeys])
            let data = try await RecommendationCache.fetch(payload, force: request.watch != nil)
            let result = try JSONDecoder().decode(LocalRecommendationPage.self, from: data)
            try Task.checkCancellation()
            guard activeRequestID == token, self.request?.id == request.id else { return }
            page = result
            if let watch = request.watch, ["ready", "no_matches"].contains(result.status) {
                try await RadarStore.shared.recordCheck(watch)
                try Task.checkCancellation()
                guard activeRequestID == token, self.request?.id == request.id else { return }
                let latestWatches = try await RadarStore.shared.all()
                try Task.checkCancellation()
                guard activeRequestID == token, self.request?.id == request.id else { return }
                watches = latestWatches
            }
        } catch is CancellationError {} catch {
            if activeRequestID == token, self.request?.id == request.id, !Task.isCancelled { errorMessage = error.localizedDescription }
        }
    }
}

private struct RadarSuggestion: Identifiable { let id: String; let title: String; let sourceID: String }
private struct RadarBriefEditorContext: Identifiable { let id = UUID(); let brief: RadarBrief }
private struct RadarMatchRequest: Identifiable { let id = UUID(); let brief: RadarBrief; let watch: RadarWatch? }
private enum RadarMatchSort: String, CaseIterable, Identifiable {
    case bestFit = "Best fit", price = "Price", quality = "Quality"
    var id: String { rawValue }
}
private enum RadarMatchError: LocalizedError {
    case noSources
    var errorDescription: String? { "Choose an existing saved example in your interpretation before checking matches." }
}

private struct RadarBriefEditor: View {
    @State var brief: RadarBrief
    let finds: [SavedItem]
    let onShow: (RadarBrief) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Make sure this captures what you mean. Every detail is editable.").font(.subheadline).foregroundStyle(.secondary)
                    TextField("Your intention", text: $brief.intention, axis: .vertical).lineLimit(2...4)
                    TextField("Must-haves or things to avoid", text: $brief.mustHaves, axis: .vertical).lineLimit(2...4)
                    TextField("Optional search terms", text: $brief.searchTerms)
                } header: { Text("Your interpretation") } footer: { Text("Search terms narrow the catalog. Keep them short, such as a product type or material.") }
                Section("Budget & fit") {
                    HStack {
                        Picker("Currency", selection: $brief.currency) { ForEach(["SGD", "USD", "GBP", "EUR"], id: \.self) { Text($0).tag($0) } }.labelsHidden()
                        TextField("Maximum budget, optional", text: $brief.budget).keyboardType(.decimalPad)
                    }
                    Toggle("Needs to fit a small space", isOn: $brief.smallSpace)
                    TextField("Dimensions or fit details", text: $brief.fitNotes, axis: .vertical).lineLimit(1...3)
                    Text("Price and dimensions need checking at the retailer. These preferences are saved, not verified filters.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Use these saved examples") {
                    if finds.isEmpty { Text("Add an example in Library to get grounded matches.").foregroundStyle(.secondary) }
                    ForEach(finds.prefix(24)) { find in
                        Toggle(find.title, isOn: Binding(get: { brief.sourceIDs.contains(find.id) }, set: { include in
                            if include { if !brief.sourceIDs.contains(find.id) { brief.sourceIDs.append(find.id) } }
                            else { brief.sourceIDs.removeAll { $0 == find.id } }
                        })).font(.subheadline)
                    }
                }
                if let errorMessage { Section { Text(errorMessage).font(.footnote).foregroundStyle(.red) } }
                Section {
                    Button("Show matches", systemImage: "sparkle.magnifyingglass") {
                        do { let value = try brief.validated(); onShow(value); dismiss() }
                        catch { errorMessage = error.localizedDescription }
                    }.font(.headline.bold()).disabled(brief.intention.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.navigationTitle("Review your intent").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

private struct RadarWatchEditor: View {
    @State var watch: RadarWatch
    let finds: [SavedItem]
    let onSave: (RadarWatch) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false
    @State private var errorMessage: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("What should we keep in mind?") {
                    Picker("Track a", selection: $watch.scope) { ForEach(RadarScope.allCases) { Text($0.title).tag($0) } }
                    TextField("Specific \(watch.scope.title.lowercased())", text: $watch.target, axis: .vertical).lineLimit(1...3)
                    TextField("Conditions that matter", text: $watch.conditions, axis: .vertical).lineLimit(2...4)
                }
                Section("Your need") {
                    if watch.scope != .need {
                        TextField("Intention", text: $watch.brief.intention, axis: .vertical).lineLimit(1...3)
                    }
                    TextField("Must-haves", text: $watch.brief.mustHaves, axis: .vertical).lineLimit(1...3)
                    TextField("Search terms", text: $watch.brief.searchTerms)
                    TextField("Budget (\(watch.brief.currency))", text: $watch.brief.budget).keyboardType(.decimalPad)
                    Toggle("Small-space fit", isOn: $watch.brief.smallSpace)
                    TextField("Fit details", text: $watch.brief.fitNotes)
                }
                Section("Use these saved examples") {
                    if finds.isEmpty { Text("Save an example in Library, then return here to connect it.").foregroundStyle(.secondary) }
                    ForEach(finds.prefix(24)) { find in
                        Toggle(find.title, isOn: Binding(get: { watch.brief.sourceIDs.contains(find.id) }, set: { include in
                            if include { if !watch.brief.sourceIDs.contains(find.id) { watch.brief.sourceIDs.append(find.id) } }
                            else { watch.brief.sourceIDs.removeAll { $0 == find.id } }
                        })).font(.subheadline)
                    }
                }
                Section {
                    Picker("Preferred frequency", selection: $watch.frequency) { ForEach(RadarFrequency.allCases) { Text($0.title).tag($0) } }
                    Toggle("Pause this need", isOn: $watch.isPaused)
                } footer: {
                    Text("This saves a preference on your iPhone. Use Check now for a fresh catalog search. Scheduled checks, live prices and notifications are not connected.")
                }
                if let errorMessage { Section { Text(errorMessage).font(.footnote).foregroundStyle(.red) } }
            }.navigationTitle("Track my need").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save need") {
                            do {
                                if watch.scope == .need { watch.brief.intention = watch.target }
                                watch.brief.sourceIDs.removeAll { id in !finds.contains(where: { $0.id == id }) }
                                let value = try watch.validated(); saving = true
                                Task {
                                    if await onSave(value) { dismiss() } else { errorMessage = "Couldn’t save this need. Try again." }
                                    saving = false
                                }
                            } catch { errorMessage = error.localizedDescription }
                        }.bold().disabled(saving || watch.target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .onChange(of: watch.scope) { _, scope in watch.target = scope.suggestedTarget(for: watch.brief) }
        }.interactiveDismissDisabled(saving)
    }
}

private struct RadarOpportunityCard: View {
    let item: LocalRecommendation
    let finds: [SavedItem]
    let onSourceChange: () -> Void
    let onTrack: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            CatalogProductImage(url: item.imageURL.flatMap(URL.init(string:)), height: 210, fit: true)
                .clipShape(RoundedRectangle(cornerRadius: 22))
            Text(item.title).font(.headline.bold()).fixedSize(horizontal: false, vertical: true)
            ForEach(item.reasons.prefix(2)) { reason in
                Label(reason.text, systemImage: "sparkles").font(.subheadline).foregroundStyle(.purple)
                if let find = finds.first(where: { $0.id == reason.findID }) {
                    NavigationLink {
                        SavedContentView(item: find, stillSaved: true, localOnly: true, onChanged: onSourceChange,
                            onDelete: { id, _ in try await LocalLibrary.shared.delete(id); onSourceChange() })
                    } label: { Label("From \(find.title)", systemImage: find.hasImage ? "photo" : "bookmark") }
                        .font(.caption).lineLimit(2)
                    if let url = safeURL(find.originalUrl) {
                        Link("Original source", destination: url).font(.caption)
                    }
                }
            }
            DisclosureGroup("Evidence & trade-offs") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Why now: this record is available in the catalog. This is not a live stock or discount signal.")
                    Text("Price, dimensions and comparative quality are unverified. Check them against your brief before buying.")
                    if let url = safeURL(item.sourceURL) { Link(item.sourceName, destination: url) }
                    if let attribution = item.attribution { Text(attribution) }
                    if let url = item.licenseURL.flatMap(safeURL) { Link("Source license", destination: url) }
                }.font(.footnote).foregroundStyle(.secondary).padding(.top, 10)
            }.font(.subheadline).tint(.secondary)
            HStack {
                if let url = searchURL { Link("View shopping options", destination: url).font(.subheadline.bold()) }
                Spacer()
                Button(action: onTrack) { Image(systemName: "dot.radiowaves.left.and.right").frame(width: 44, height: 44) }
                    .accessibilityLabel("Track this product")
            }
            Text("Opens an Amazon search. Confirm the seller, current price and availability.").font(.caption).foregroundStyle(.secondary)
        }.padding(17).background(NativeTheme.surface, in: RoundedRectangle(cornerRadius: 27))
    }
    private var searchURL: URL? {
        var value = URLComponents(string: "https://www.amazon.com/s")
        value?.queryItems = [URLQueryItem(name: "k", value: item.title)]
        return value?.url
    }
    private func safeURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil, url.user == nil, url.password == nil else { return nil }
        return url
    }
}
