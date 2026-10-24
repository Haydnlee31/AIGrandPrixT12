import SwiftUI
import CommonThreadKit

/// Choices belong to this sheet session, never to a permanent personal profile.
struct DiscoveryScreen: View {
    private struct Page: Decodable { let status: String; let items: [LocalRecommendation] }
    @State private var savedFinds: [SavedItem] = []
    @State private var useInterests = true
    @State private var items: [LocalRecommendation] = []
    @State private var selected: LocalRecommendation?
    @State private var dismissedIDs: [String] = []
    @State private var brief = ""
    @State private var busy = false
    @State private var error: String?
    @State private var generation = UUID()
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text(selected == nil ? (savedFinds.isEmpty || !useInterests ? "What catches your eye?" : "Inspired by your interests.") : "Follow your curiosity.")
                        .font(.largeTitle.bold())
                    Text(selected == nil ? (savedFinds.isEmpty || !useInterests ? "Pick something interesting. No right answers." : "See which detail connects each suggestion to your saves.") : "A starting point, not a permanent preference.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if selected == nil && !savedFinds.isEmpty {
                        Toggle("Use my saved interests", isOn: $useInterests).tint(.purple)
                            .onChange(of: useInterests) { _, _ in dismissedIDs = []; Task { await load() } }
                    }
                    if selected != nil {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("What I understood", systemImage: "sparkles").font(.headline).foregroundStyle(.purple)
                            TextField("What would you like to explore?", text: $brief, axis: .vertical)
                                .lineLimit(2...4).textFieldStyle(.plain)
                            Button("Update suggestions") { Task { await load() } }
                                .buttonStyle(.borderedProminent).disabled(busy || brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }.padding(18).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 22))
                    }
                    if busy { ProgressView("Finding possibilities…").frame(maxWidth: .infinity).padding() }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 14)], spacing: 20) {
                        ForEach(items) { item in
                            VStack(alignment: .leading, spacing: 10) {
                                Button { choose(item) } label: {
                                    VStack(alignment: .leading, spacing: 10) {
                                        CatalogProductImage(url: item.imageURL.flatMap(URL.init(string:)), height: 180, fit: true)
                                            .clipShape(RoundedRectangle(cornerRadius: 20))
                                        Text(item.title).font(.subheadline.bold()).lineLimit(3).foregroundStyle(.primary)
                                            .multilineTextAlignment(.leading)
                                        Label("Explore this", systemImage: "sparkles").font(.caption.bold()).foregroundStyle(.purple)
                                    }
                                }.buttonStyle(.plain).disabled(busy)
                                if let reason = item.reasons.first {
                                    Label(reason.text, systemImage: "sparkles").font(.caption).foregroundStyle(.purple)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Text("From: \(reason.findTitle)").font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                                }
                                NavigationLink("View product") { LocalRecommendationDetail(item: item, finds: savedFinds, onChanged: {}) }
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let error { Text(error).foregroundStyle(.secondary); Button("Try again") { Task { await load() } }.disabled(busy) }
                    if !busy && items.isEmpty && error == nil {
                        Text("No verified options for that preference. Edit it or explore a different direction.").foregroundStyle(.secondary)
                    }
                    HStack {
                        Button(selected == nil ? "None of these" : "A different direction") {
                            dismissedIDs = Array((dismissedIDs + items.map(\.id)).suffix(40))
                            selected = nil; brief = ""; Task { await load() }
                        }.disabled(busy)
                        Spacer()
                        Button("Done") { dismiss() }
                    }.font(.subheadline.bold()).padding(.vertical)
                }.padding(22)
            }.scrollDismissesKeyboard(.interactively)
                .background(NativeTheme.bg)
                .navigationTitle("Discover").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
                .task { await load() }
        }
    }
    private func choose(_ item: LocalRecommendation) {
        selected = item
        brief = item.discoveryHint ?? "Explore alternatives to \(item.title.prefix(220))"
        Task { await load() }
    }
    @MainActor private func load() async {
        let current = UUID(); generation = current; busy = true; error = nil
        defer { if generation == current { busy = false } }
        do {
            var body: [String: Any] = ["dismissed": dismissedIDs, "brief": String(brief.prefix(400))]
            if let selected { body["selected_id"] = selected.id }
            else {
                let metadata = try await LocalLibrary.shared.metadata()
                savedFinds = try await LocalLibrary.shared.collection().filter { $0.client != "sample" && !(metadata[$0.id]?.isArchived ?? false) }
                if useInterests {
                    body["finds"] = try savedFinds.prefix(24).map { find -> [String: Any] in
                        let context = metadata[find.id] ?? LocalFindMetadata()
                        var value: [String: Any] = ["id": find.id, "title": find.title, "intents": Array(context.selectedIntents.prefix(8))]
                        if let analysis = context.analysis { value["analysis"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(analysis)) }
                        return value
                    }
                }
            }
            let data = try await CaptureIntelligence.post(path: "v1/discover", body: JSONSerialization.data(withJSONObject: body))
            try Task.checkCancellation()
            guard generation == current else { return }
            items = try JSONDecoder().decode(Page.self, from: data).items
        } catch is CancellationError {} catch { if generation == current { self.error = error.localizedDescription } }
    }
}
