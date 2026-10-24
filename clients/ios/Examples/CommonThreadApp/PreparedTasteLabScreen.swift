import SwiftUI

struct PreparedTasteLabScreen: View {
    @Environment(\.dismiss) private var dismiss
    @State private var session = TasteLabSession()
    @State private var version = TasteLabSession.Choice.a
    @State private var focus = "Lighting"
    @State private var brief = ""
    @State private var resultBrief: String?
    @State private var showingResults = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("An evening with a book.").font(.largeTitle.bold())
                    if !session.complete {
                        Text("Starting idea: a reading chair. Let’s see what actually appeals to you.").font(.subheadline).foregroundStyle(.secondary)
                        Text("Which version would you rather spend an evening in?").font(.title3.weight(.semibold))
                        Text(session.dimension == .lighting ? "1 of 2 · Lighting changes; furniture stays the same." : "2 of 2 · Chair changes; lighting stays the same.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Picker("Scene version", selection: $version) {
                            Text("A").tag(TasteLabSession.Choice.a)
                            Text("B").tag(TasteLabSession.Choice.b)
                        }.pickerStyle(.segmented)
                        Image(version == .a ? "reading-corner" : session.dimension == .lighting ? "taste-cool" : "taste-chair")
                            .resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 24))
                            .accessibilityLabel(version == .a ? "Original reading corner with warm light and upholstered chair" : session.dimension == .lighting ? "Same reading corner with cooler light" : "Same reading corner with wooden chair")
                        HStack {
                            Button("Choose A") { choose(.a) }.buttonStyle(.borderedProminent)
                            Button("Choose B") { choose(.b) }.buttonStyle(.borderedProminent)
                        }.frame(maxWidth: .infinity).tint(.purple)
                        HStack {
                            Button("Both") { choose(.both) }
                            Spacer()
                            Button("Neither") { choose(.neither) }
                        }.font(.headline).padding(.horizontal, 12)
                    } else {
                        Label("What your choices suggest", systemImage: "sparkles").font(.headline).foregroundStyle(.purple)
                        Text(session.interpretation).font(.title3.weight(.medium))
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(session.answers.enumerated()), id: \.offset) { _, answer in
                                Label("\(answer.dimension.rawValue.capitalized): \(answer.choice.rawValue)", systemImage: "checkmark.circle")
                            }
                        }.font(.subheadline).foregroundStyle(.secondary)
                        Picker("Explore first", selection: $focus) {
                            if focus.isEmpty { Text("Choose").tag("") }
                            Text("Lighting").tag("Lighting")
                            Text("Furniture").tag("Furniture")
                        }.pickerStyle(.segmented).onChange(of: focus) { _, value in brief = session.brief(for: value) }
                        TextField("Your shopping brief", text: $brief, axis: .vertical).lineLimit(3...5)
                            .padding(18).background(.quaternary, in: RoundedRectangle(cornerRadius: 20))
                        Button { resultBrief = brief; showingResults = true } label: {
                            Label("Explore this idea", systemImage: "arrow.right").frame(maxWidth: .infinity)
                        }.buttonStyle(.borderedProminent).tint(.purple)
                            .disabled(brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || brief.count > 100 || TasteLabSession.productType(for: brief) == nil)
                        if TasteLabSession.productType(for: brief) == nil { Text("Choose lighting or furniture for this experiment.").font(.caption).foregroundStyle(.secondary) }
                        if brief.count > 100 { Text("Keep the brief under 100 characters.").font(.caption).foregroundStyle(.secondary) }
                    }
                    if !session.answers.isEmpty {
                        Button { session.undo(); version = .a } label: { Label("Undo last choice", systemImage: "arrow.uturn.backward") }
                    }
                    Text("Illustrative AI scenes · Your choices stay in this session.").font(.caption).foregroundStyle(.secondary)
                }.padding(22)
            }.scrollDismissesKeyboard(.interactively)
                .navigationTitle("Taste Lab").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
                .navigationDestination(isPresented: $showingResults) {
                    if let resultBrief {
                        LocalExploreScreen(query: "", libraryRevision: resultBrief, sessionBrief: resultBrief)
                            .navigationTitle("For your reading corner").navigationBarTitleDisplayMode(.inline)
                    }
                }
        }
    }
    private func choose(_ value: TasteLabSession.Choice) {
        session.choose(value); version = .a
        if session.complete { focus = session.suggestedFocus; brief = session.brief(for: focus) }
    }
}
