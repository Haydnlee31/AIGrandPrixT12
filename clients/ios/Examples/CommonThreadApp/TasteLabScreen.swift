import SwiftUI
import CommonThreadKit

struct TasteLabScreen: View {
    private struct Pair: Decodable, Identifiable {
        let id, activity, question, dimension, category, aID, bID, aLabel, bLabel: String
        let sourceFindID: String?
        let a, b: LocalRecommendation
        enum CodingKeys: String, CodingKey {
            case id, activity, question, dimension, category, a, b
            case aID = "a_id", bID = "b_id", aLabel = "a_label", bLabel = "b_label", sourceFindID = "source_find_id"
        }
        var payload: [String: Any] {
            ["activity": activity, "question": question, "dimension": dimension, "category": category,
             "a_id": aID, "b_id": bID, "a_label": aLabel, "b_label": bLabel, "source_find_id": sourceFindID as Any? ?? NSNull()]
        }
    }
    private struct Plan: Decodable { let cases: [Pair] }
    private struct Meaning: Decodable { let interpretation, brief, category: String }
    @MainActor private static var cachedPlans: [Data: (Date, Plan)] = [:]
    @Environment(\.dismiss) private var dismiss
    @State private var cases: [Pair] = []
    @State private var compared: [String: String] = [:]
    @State private var selected: Pair?
    @State private var choice: String?
    @State private var meaning: Meaning?
    @State private var brief = ""
    @State private var goal = ""
    @State private var busy = false
    @State private var error: String?
    @State private var sources: [String: String] = [:]
    @State private var resultBrief = ""
    @State private var resultCategory = ""
    @State private var showingResults = false
    @State private var prepared = false
    @State private var enlarged: LocalRecommendation?
    @State private var operation: Task<Void, Never>?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let selected {
                        Text(selected.activity).font(.title.bold())
                        Text(selected.question).font(.headline)
                        HStack(alignment: .top, spacing: 12) {
                            option(selected.a, label: selected.aLabel, code: "A")
                            option(selected.b, label: selected.bLabel, code: "B")
                        }
                        HStack {
                            Button { pick("Both") } label: { Label("Both", systemImage: choice == "Both" ? "checkmark.circle.fill" : "plus.circle") }
                            Spacer()
                            Button { pick("Neither") } label: { Label("Neither", systemImage: choice == "Neither" ? "checkmark.circle.fill" : "minus.circle") }
                        }.font(.headline).disabled(busy)
                        Text("Comparing \(selected.dimension.lowercased()). These real products can differ in other ways too.")
                            .font(.caption).foregroundStyle(.secondary)
                        if let meaning {
                            Text(meaning.interpretation).font(.body.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                            TextField("Tell us what matters to you", text: $brief, axis: .vertical).lineLimit(2...5)
                                .padding(16).background(.quaternary, in: RoundedRectangle(cornerRadius: 18))
                            Text("Edit before exploring. This is a starting point, not a permanent preference.").font(.caption).foregroundStyle(.secondary)
                            Button { run { await interpret(openResults: true) } } label: {
                                Label("Find options for this", systemImage: "sparkles").frame(maxWidth: .infinity)
                            }.buttonStyle(.borderedProminent).tint(.purple)
                                .disabled(busy || brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || brief.count > 100)
                            if brief.count > 100 { Text("Keep your brief under 100 characters.").font(.caption) }
                        } else if choice != nil && !busy {
                            Button("Explore what this means") { run { await interpret(openResults: false) } }.buttonStyle(.borderedProminent).tint(.purple)
                        }
                        HStack {
                            if choice != nil { Button { compared[selected.id] = nil; choice = nil; meaning = nil; brief = "" } label: { Label("Undo", systemImage: "arrow.uturn.backward") } }
                            Spacer()
                            Button("Other experiments") { self.selected = nil; choice = nil; meaning = nil; brief = "" }
                        }.disabled(busy)
                    } else {
                        Text("Discover what draws you in.").font(.largeTitle.bold())
                        Text("Compare real products. Find a direction worth exploring.").foregroundStyle(.secondary)
                        HStack {
                            TextField("Something you’d like to do?", text: $goal).submitLabel(.search)
                                .onSubmit { run { await load() } }
                            Button { run { await load() } } label: { Image(systemName: "arrow.right.circle.fill").font(.title2) }.disabled(busy)
                        }.padding(16).background(.quaternary, in: RoundedRectangle(cornerRadius: 18))
                        ForEach(cases) { pair in
                            Button { selected = pair; choice = compared[pair.id]; meaning = nil; brief = "" } label: {
                                VStack(alignment: .leading, spacing: 12) {
                                    HStack(spacing: 8) {
                                        CatalogProductImage(url: pair.a.imageURL.flatMap(URL.init(string:)), height: 130, fit: true)
                                        CatalogProductImage(url: pair.b.imageURL.flatMap(URL.init(string:)), height: 130, fit: true)
                                    }.clipShape(RoundedRectangle(cornerRadius: 16))
                                    Text(pair.activity).font(.headline)
                                    if let answer = compared[pair.id] { Label("Your choice: \(answer)", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.purple) }
                                    Text(pair.question).font(.subheadline).foregroundStyle(.secondary)
                                    if let id = pair.sourceFindID, let title = sources[id] {
                                        Label("Inspired by \(title)", systemImage: "bookmark").font(.caption).foregroundStyle(.purple)
                                    }
                                }.padding(16).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 22))
                            }.buttonStyle(.plain).disabled(busy)
                        }
                        if cases.isEmpty && !busy && error == nil { Text("No verified comparison pairs yet. Try another activity.").foregroundStyle(.secondary) }
                        Button("Try the prepared reading-corner experiment") { prepared = true }.font(.subheadline)
                        Text("AI-curated from catalog photos · Session-only choices").font(.caption).foregroundStyle(.secondary)
                    }
                    if busy { ProgressView(selected == nil ? "Creating your experiments…" : "Considering your choice…").frame(maxWidth: .infinity) }
                    if let error {
                        Text(error).font(.subheadline).foregroundStyle(.secondary)
                        Button("Try again") { run { if selected == nil { await load() } else { await interpret(openResults: false) } } }.disabled(busy)
                    }
                }.padding(20)
            }.scrollDismissesKeyboard(.interactively)
                .navigationTitle("Taste Lab").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
                .task { await load() }
                .onDisappear { operation?.cancel() }
                .sheet(isPresented: $prepared) { PreparedTasteLabScreen() }
                .sheet(item: $enlarged) { item in
                    NavigationStack {
                        CatalogProductImage(url: item.imageURL.flatMap(URL.init(string:)), height: 500, fit: true).padding()
                            .navigationTitle("Look closer").navigationBarTitleDisplayMode(.inline)
                            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { enlarged = nil } } }
                    }
                }
                .navigationDestination(isPresented: $showingResults) {
                    LocalExploreScreen(query: "", libraryRevision: resultBrief, sessionBrief: resultBrief, sessionCategory: resultCategory)
                        .navigationTitle("Your next possibilities").navigationBarTitleDisplayMode(.inline)
                }
        }
    }
    private func option(_ item: LocalRecommendation, label: String, code: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { pick(code) } label: {
                VStack(alignment: .leading, spacing: 8) {
                    CatalogProductImage(url: item.imageURL.flatMap(URL.init(string:)), height: 225, fit: true)
                    Label(label, systemImage: choice == code ? "checkmark.circle.fill" : "circle").font(.subheadline.bold())
                        .fixedSize(horizontal: false, vertical: true)
                }.padding(10).background(choice == code ? Color.purple.opacity(0.12) : Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(choice == code ? Color.purple : .clear, lineWidth: 2))
            }.buttonStyle(.plain).disabled(busy)
            Button { enlarged = item } label: { Label("Look closer", systemImage: "arrow.up.left.and.arrow.down.right") }.font(.caption)
        }.frame(maxWidth: .infinity)
    }
    private func pick(_ value: String) { if let selected { compared[selected.id] = value }; choice = value; meaning = nil; brief = "" }
    private func run(_ work: @escaping @MainActor () async -> Void) { operation?.cancel(); operation = Task { await work() } }
    @MainActor private func load() async {
        busy = true; error = nil
        defer { busy = false }
        do {
            let metadata = try await LocalLibrary.shared.metadata()
            let finds = try await LocalLibrary.shared.collection().filter { $0.client != "sample" && !(metadata[$0.id]?.isArchived ?? false) }
            sources = Dictionary(uniqueKeysWithValues: finds.map { ($0.id, $0.title) })
            let payload = try finds.prefix(24).map { find -> [String: Any] in
                var value: [String: Any] = ["id": find.id, "title": find.title, "intents": Array((metadata[find.id]?.selectedIntents ?? []).prefix(8))]
                if let analysis = metadata[find.id]?.analysis { value["analysis"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(analysis)) }
                return value
            }
            let body = try JSONSerialization.data(withJSONObject: ["finds": payload, "goal": String(goal.prefix(300))], options: [.sortedKeys])
            if let cached = Self.cachedPlans[body], Date().timeIntervalSince(cached.0) < 600 {
                cases = cached.1.cases; return
            }
            let data = try await CaptureIntelligence.post(path: "v1/taste-lab", body: body)
            try Task.checkCancellation()
            let plan = try JSONDecoder().decode(Plan.self, from: data)
            cases = plan.cases; compared = [:]
            if !plan.cases.isEmpty {
                if Self.cachedPlans.count >= 8 { Self.cachedPlans.removeAll() }
                Self.cachedPlans[body] = (Date(), plan)
            }
        } catch is CancellationError {} catch { self.error = "Couldn’t create comparisons. Try again; the prepared experiment is still available." }
    }
    @MainActor private func interpret(openResults: Bool) async {
        guard let selected, let choice else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let body: [String: Any] = ["pair": selected.payload, "a_title": selected.a.title, "b_title": selected.b.title, "choice": choice, "clarification": openResults ? brief : ""]
            let data = try await CaptureIntelligence.post(path: "v1/taste-interpret", body: JSONSerialization.data(withJSONObject: body))
            try Task.checkCancellation()
            let value = try JSONDecoder().decode(Meaning.self, from: data)
            meaning = value
            if openResults {
                resultBrief = brief; resultCategory = value.category; showingResults = true
            } else { brief = value.brief }
        } catch is CancellationError {} catch { self.error = "Couldn’t interpret that choice. Try again." }
    }
}
