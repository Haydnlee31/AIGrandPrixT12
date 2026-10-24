import SwiftUI

struct VisualIntentSection: View {
    let itemID: String
    let metadata: LocalFindMetadata
    let onChanged: () -> Void
    @State private var editing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Label("What matters to you", systemImage: "hand.point.up.left.fill")
                    .font(.title3.bold()).foregroundStyle(.purple)
                Spacer()
                Button("Edit") { editing = true }.font(.subheadline.bold())
            }
            if metadata.selectedIntents.isEmpty {
                Button("Choose the detail, not the whole thing") { editing = true }
                    .font(.body.weight(.medium)).multilineTextAlignment(.leading)
            } else {
                Text(metadata.selectedIntents.joined(separator: "\n"))
                    .font(.body).fixedSize(horizontal: false, vertical: true)
                NavigationLink {
                    LocalExploreScreen(query: "", libraryRevision: UUID().uuidString, onlyFindID: itemID)
                } label: { Label("Find options for these details", systemImage: "sparkles") }
                    .font(.subheadline.bold())
            }
        }.padding(18).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 22))
        .sheet(isPresented: $editing) {
            VisualIntentEditor(itemID: itemID, metadata: metadata, onChanged: onChanged)
        }
    }
}

private struct VisualIntentEditor: View {
    let itemID: String
    let metadata: LocalFindMetadata
    let onChanged: () -> Void
    @State private var brief = ""
    @State private var saving = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    private var values: [String] { brief.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
    private var suggestions: [String] {
        var options: [String] = []
        if let analysis = metadata.analysis {
            // Observations become optional choices, never silently saved preferences.
            let source = analysis.summary.lowercased()
            let pattern = #"\b(?:silver|black|white|gold|blue|brown|red)(?: leather| metal| steel)? (?:dial|face|strap|case)\b"#
            if let regex = try? NSRegularExpression(pattern: pattern) {
                for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                    if let range = Range(match.range, in: source) { options.append("I like the \(source[range]).") }
                }
            }
            options += analysis.prompts.map(\.text)
        }
        var seen = Set<String>()
        return Array(options.filter { seen.insert($0).inserted }.prefix(5)) + ["Brand flexible"]
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("This part. Not everything.").font(.largeTitle.bold())
                    Text("Choose what you like, then edit the brief. These choices apply only to this find.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    ForEach(Array(suggestions.enumerated()), id: \.element) { index, text in
                        Button {
                            var next = values
                            if let index = next.firstIndex(of: text) { next.remove(at: index) }
                            else if next.count < 8 { next.append(text) }
                            brief = next.joined(separator: "\n")
                        } label: { FindIntentRow(text: text, index: index, selected: values.contains(text), compact: true) }
                            .buttonStyle(.plain).disabled(saving)
                    }
                    Label("Your shopping brief", systemImage: "text.alignleft").font(.headline)
                    TextEditor(text: $brief).frame(minHeight: 150).padding(10)
                        .scrollContentBackground(.hidden)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
                        .accessibilityLabel("Edit your shopping preferences, one per line")
                    Text("One preference per line. Remove anything that doesn’t matter, or write your own.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let error { Text(error).font(.subheadline).foregroundStyle(.red) }
                }.padding(22)
            }.scrollDismissesKeyboard(.interactively)
                .navigationTitle("What caught your eye?").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(saving ? "Saving…" : "Save") { Task { await save() } }
                            .bold().disabled(saving || values.count > 8 || values.contains { $0.count > 500 })
                    }
                }
                .onAppear { brief = metadata.selectedIntents.joined(separator: "\n") }
        }
    }
    @MainActor private func save() async {
        saving = true; error = nil
        defer { saving = false }
        do {
            try await LocalLibrary.shared.setIntents(itemID, values)
            onChanged(); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
