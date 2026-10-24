import SwiftUI
import CommonThreadKit

/// Product understanding stays behind the scenes. The customer sees useful observations
/// and can choose several reasons for saving a find, each independently editable.
struct LocalIntelligencePreview: View {
    let item: SavedItem
    var questionFocusToken: UUID? = nil
    var onChanged: () -> Void = {}
    @State private var intents: [String] = []
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var editor: IntentEdit?
    @State private var refinement: IntentRefinementContext?
    @State private var analysis: CaptureIntelligenceResult?
    @State private var analyzing = false
    @State private var analysisError: String?
    @State private var analysisRequestID: UUID?
    @State private var analysisRetryID = UUID()
    @State private var showingSuggestions = false
    private var choices: [String] { analysis?.prompts.map(\.text) ?? [] }
    // Pins and selected details refresh metadata without canceling product analysis.
    private var analysisTaskID: [String] {
        [item.id, item.originalUrl, item.title, item.selectedText, item.note, item.client ?? "", analysisRetryID.uuidString]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("New Insights", systemImage: "sparkles")
                .font(.title3.bold()).foregroundStyle(.primary)
                .symbolRenderingMode(.hierarchical)
            if let analysis {
                NewInsightHighlights(summary: analysis.summary, evidence: analysis.evidence, uncertainties: analysis.uncertainties)
            } else if analyzing {
                ProgressView("Taking a closer look…").font(.subheadline).tint(.purple)
            } else {
                Text(CaptureIntelligence.isConfigured ? "Add a detail to make this find yours." : "Connect shopping intelligence in Profile for tailored ideas.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if !intents.isEmpty {
                SelectedIntentChips(values: intents, onRefine: { openRefinement($0) },
                    onRemove: { value in Task { _ = await saveIntents(intents.filter { $0 != value }) } },
                    onEdit: { editor = IntentEdit(original: $0, initial: $0) }, disabled: busy)
            }
            DisclosureGroup("Personalize this find", isExpanded: $showingSuggestions) {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(Array(choices.filter { !intents.contains($0) }.prefix(3).enumerated()), id: \.element) { index, choice in
                        Button { Task { await selectIntent(choice) } } label: {
                            FindIntentRow(text: choice, index: index, compact: true)
                        }.buttonStyle(.plain).disabled(busy)
                    }
                    Button { editor = IntentEdit(original: nil, initial: "") } label: {
                        Label("Add your own · type or speak", systemImage: "plus.bubble")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(.purple)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10)
                    }.buttonStyle(.plain).disabled(busy)
                }.padding(.top, 12)
            }.font(.subheadline.weight(.semibold)).tint(.purple)
            if let analysisError {
                Text(analysisError).font(.subheadline).foregroundStyle(.secondary)
                Button("Try again", systemImage: "arrow.clockwise") { analysisRetryID = UUID() }.disabled(analyzing)
            }
            if let errorMessage { Text(errorMessage).font(.subheadline).foregroundStyle(.red) }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(20)
        .background(NativeTheme.surface, in: RoundedRectangle(cornerRadius: 25))
        .onChange(of: questionFocusToken) { _, token in
            if token != nil { withAnimation(.easeInOut(duration: 0.2)) { showingSuggestions = true } }
        }
        .task(id: "\(item.id)|\(item.revision)") {
            do {
                let saved = try await LocalLibrary.shared.metadata()[item.id]
                try Task.checkCancellation()
                intents = saved?.selectedIntents ?? []; analysis = saved?.analysis
            } catch is CancellationError {} catch { if !Task.isCancelled { errorMessage = error.localizedDescription } }
        }
        .task(id: analysisTaskID) { await analyzeFind() }
        .sheet(item: $editor) { value in
            LocalIntentEditor(initial: value.initial) { text in
                var updated = intents
                if let original = value.original, let index = updated.firstIndex(of: original) { updated[index] = text }
                else if !updated.contains(text) { updated.append(text) }
                return await saveIntents(updated)
            }
        }
        .sheet(item: $refinement) { context in
            IntentRefinementSheet(context: context) { choice in
                do {
                    let current = try await LocalLibrary.shared.metadata()[item.id]?.selectedIntents ?? intents
                    return await saveIntents(current.contains(choice) ? current : current + [choice])
                } catch { errorMessage = error.localizedDescription; return false }
            }
        }
    }

    private func openRefinement(_ value: String) {
        guard let analysis, analysis.productName != nil, CaptureIntelligence.isConfigured else {
            editor = IntentEdit(original: value, initial: value); return
        }
        refinement = IntentRefinementContext(analysis: analysis, selectedIntent: value, existingIntents: intents)
    }

    @MainActor private func analyzeFind() async {
        guard !Task.isCancelled else { return }
        let requestID = UUID()
        let input = SavedAnalysisInput(item)
        analysisRequestID = requestID; analyzing = false; analysisError = nil
        defer {
            if analysisRequestID == requestID { analyzing = false; analysisRequestID = nil }
        }
        guard CaptureIntelligence.isConfigured, item.client != "sample" else { return }
        do {
            let metadata = try await LocalLibrary.shared.metadata()[item.id]
            try Task.checkCancellation()
            guard analysisRequestID == requestID else { return }
            analysis = metadata?.analysis
            guard metadata?.analysis?.schemaVersion != 2 else { return }
            analyzing = true
            var image: Data?
            if let attachment = metadata?.attachments.first(where: \.isImage) { image = try await LocalLibrary.shared.attachmentData(attachment) }
            try Task.checkCancellation()
            let result = try await CaptureIntelligence.analyze(url: item.originalUrl.isEmpty ? nil : item.originalUrl,
                title: item.title, text: item.selectedText, note: item.note, imageData: image)
            try Task.checkCancellation()
            guard analysisRequestID == requestID else { return }
            guard try await LocalLibrary.shared.setAnalysis(result, matching: input) else { return }
            try Task.checkCancellation()
            guard analysisRequestID == requestID else { return }
            analysis = result; onChanged()
        } catch is CancellationError {} catch {
            if analysisRequestID == requestID, !Task.isCancelled { analysisError = error.localizedDescription }
        }
    }

    @MainActor private func selectIntent(_ value: String) async {
        if !intents.contains(value), !(await saveIntents(intents + [value])) { return }
        openRefinement(value)
    }

    @MainActor private func saveIntents(_ values: [String]) async -> Bool {
        guard !busy else { return false }; busy = true; errorMessage = nil
        defer { busy = false }
        do {
            var unique: [String] = []
            for value in values.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !value.isEmpty && !unique.contains(value) { unique.append(value) }
            guard unique.count <= 8 else {
                errorMessage = "You can choose up to 8 details. Remove one to add another."
                return false
            }
            try await LocalLibrary.shared.setIntents(item.id, unique)
            intents = unique; onChanged(); FindsHaptics.selection()
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
}

fileprivate struct SavedAnalysisInput: Equatable, Sendable {
    let id: String
    let url: String
    let title: String
    let text: String
    let note: String
    init(_ item: SavedItem) {
        id = item.id; url = item.originalUrl; title = item.title; text = item.selectedText; note = item.note
    }
}

fileprivate extension LocalLibrary {
    /// Check the source and commit on the same actor turn so an edited find
    /// cannot receive a late analysis produced from its previous content.
    func setAnalysis(_ analysis: CaptureIntelligenceResult, matching input: SavedAnalysisInput) throws -> Bool {
        try Task.checkCancellation()
        guard let current = try collection().first(where: { $0.id == input.id }), SavedAnalysisInput(current) == input else { return false }
        try setAnalysis(input.id, analysis)
        return true
    }
}

private struct IntentEdit: Identifiable {
    let id = UUID()
    let original: String?
    let initial: String
}

private struct LocalIntentEditor: View {
    let initial: String
    let save: (String) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var text = ""
    @State private var recorder = VoiceNoteRecorder()
    @State private var voiceTask: Task<Void, Never>?
    @State private var startingVoice = false
    @State private var busy = false
    @State private var errorMessage: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("What do you like about this find?") {
                    TextEditor(text: $text).frame(minHeight: 130).disabled(recorder.isRecording || startingVoice || recorder.isTranscribing)
                    Text("\(text.count)/500").font(.caption).foregroundStyle(.secondary)
                    Button {
                        if startingVoice { cancelVoice() }
                        else if recorder.isRecording { recorder.stop() }
                        else { startVoice() }
                    } label: { Label(recorder.isRecording ? "Stop & transcribe" : startingVoice ? "Starting microphone…" : "Say it out loud", systemImage: recorder.isRecording ? "stop.circle.fill" : "mic.fill") }
                        .disabled(recorder.isTranscribing)
                    VoiceDictationStatus(recorder: recorder)
                }
                Section { Text("This detail helps shape Explore. You can edit or remove it whenever you like.").font(.footnote).foregroundStyle(.secondary) }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red).font(.footnote) }
            }
            .navigationTitle("What caught your eye?").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { cancelVoice(); dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save detail") {
                        busy = true
                        Task {
                            if await save(text.trimmingCharacters(in: .whitespacesAndNewlines)) { dismiss() }
                            else { errorMessage = "Couldn’t save your detail. Please try again." }
                            busy = false
                        }
                    }.bold().disabled(busy || startingVoice || recorder.isRecording || recorder.isTranscribing || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.count > 500)
                }
            }
            .task { text = initial }
        }.presentationDetents([.medium, .large]).interactiveDismissDisabled(busy)
            .onDisappear { cancelVoice() }
            .onChange(of: scenePhase) { _, phase in if phase == .background { cancelVoice() } }
    }
    private func startVoice() {
        startingVoice = true; errorMessage = nil
        voiceTask = Task { @MainActor in
            defer { startingVoice = false }
            do { try await recorder.start { transcript in text = [text.trimmingCharacters(in: .whitespacesAndNewlines), transcript].filter { !$0.isEmpty }.joined(separator: " ") } }
            catch is CancellationError {} catch { errorMessage = error.localizedDescription }
        }
    }
    private func cancelVoice() { voiceTask?.cancel(); voiceTask = nil; startingVoice = false; recorder.cancel() }
}
