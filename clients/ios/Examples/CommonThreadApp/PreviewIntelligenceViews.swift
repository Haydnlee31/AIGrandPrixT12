import SwiftUI
import CommonThreadKit

private struct ExamplePreviewBadge: View {
    var body: some View {
        Label("Example preview", systemImage: "sparkles")
            .font(.caption.weight(.semibold)).foregroundStyle(.blue)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.blue.opacity(0.09), in: Capsule())
    }
}

private struct PreviewSection<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(title, systemImage: symbol).font(.headline.bold())
            content
        }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
            .background(NativeTheme.surface, in: RoundedRectangle(cornerRadius: 25))
    }
}

/// Product understanding stays behind the scenes. The customer sees useful observations
/// and can choose several reasons for saving a find, each independently editable.
struct LocalIntelligencePreview: View {
    let item: SavedItem
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
    private var choices: [String] { analysis?.prompts.map(\.text) ?? [] }
    // Pins and selected details refresh metadata without canceling product analysis.
    private var analysisTaskID: [String] {
        [item.id, item.originalUrl, item.title, item.selectedText, item.note, item.client ?? "", analysisRetryID.uuidString]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PreviewSection(title: "What caught your eye?", symbol: "sparkles") {
                if analyzing { ProgressView("Finding ideas from your save…").font(.subheadline) }
                ForEach(Array(choices.filter { !intents.contains($0) }.prefix(3).enumerated()), id: \.element) { index, choice in
                    Button { Task { await selectIntent(choice) } } label: {
                        FindIntentRow(text: choice, index: index)
                    }.buttonStyle(.plain).disabled(busy)
                }
                SelectedIntentChips(values: intents, onRefine: { openRefinement($0) },
                    onRemove: { value in Task { _ = await saveIntents(intents.filter { $0 != value }) } },
                    onEdit: { editor = IntentEdit(original: $0, initial: $0) }, disabled: busy)
                Button { editor = IntentEdit(original: nil, initial: "") } label: {
                    HStack(spacing: 13) {
                        Image(systemName: "mic.fill").font(.title3).foregroundStyle(.purple)
                            .frame(width: 46, height: 46).background(Color.purple.opacity(0.1), in: RoundedRectangle(cornerRadius: 15))
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Tell us in your own words").font(.body.weight(.semibold))
                            Text("Type or speak").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "plus").font(.body.bold()).foregroundStyle(.purple)
                    }.padding(14).background(NativeTheme.bg, in: RoundedRectangle(cornerRadius: 19))
                }.buttonStyle(.plain).disabled(busy)
                if let analysisError {
                    Text(analysisError).font(.subheadline).foregroundStyle(.secondary)
                    Button("Try suggestions again", systemImage: "arrow.clockwise") { analysisRetryID = UUID() }.disabled(analyzing)
                }
                if let errorMessage { Text(errorMessage).font(.subheadline).foregroundStyle(.red) }
            }

            PreviewSection(title: "Based on your find", symbol: "sparkle.magnifyingglass") {
                if let analysis {
                    Text(analysis.summary).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    ForEach(Array(analysis.evidence.prefix(3).enumerated()), id: \.offset) { index, evidence in
                        FindInsightRow(text: evidence, index: index)
                    }
                    if !analysis.uncertainties.isEmpty {
                        DisclosureGroup("A few things to check") {
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(analysis.uncertainties, id: \.self) { uncertainty in
                                    Label(uncertainty, systemImage: "questionmark.circle")
                                        .font(.subheadline).foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }.padding(.top, 10)
                        }.font(.subheadline.weight(.semibold))
                    }
                } else {
                    FindInsightRow(text: analyzing ? "Taking a closer look at what you saved." : "Your find is here. Add a little context to make it yours.", index: 0)
                    if !CaptureIntelligence.isConfigured {
                        Text("Connect shopping intelligence in Profile for ideas tailored to this find.").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
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
                    TextEditor(text: $text).frame(minHeight: 130).disabled(recorder.isRecording || startingVoice)
                    Text("\(text.count)/500").font(.caption).foregroundStyle(.secondary)
                    Button {
                        if recorder.isRecording || startingVoice { stopVoice() }
                        else { startVoice() }
                    } label: { Label(recorder.isRecording ? "Stop recording" : startingVoice ? "Starting microphone…" : "Say it out loud", systemImage: recorder.isRecording ? "stop.circle.fill" : "mic.fill") }
                }
                Section { Text("This detail helps shape Explore. You can edit or remove it whenever you like.").font(.footnote).foregroundStyle(.secondary) }
                if let errorMessage = errorMessage ?? recorder.errorMessage { Text(errorMessage).foregroundStyle(.red).font(.footnote) }
            }
            .navigationTitle("What caught your eye?").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { stopVoice(); dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save detail") {
                        stopVoice(); busy = true
                        Task {
                            if await save(text.trimmingCharacters(in: .whitespacesAndNewlines)) { dismiss() }
                            else { errorMessage = "Couldn’t save your detail. Please try again." }
                            busy = false
                        }
                    }.bold().disabled(busy || startingVoice || recorder.isRecording || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.count > 500)
                }
            }
            .task { text = initial }
        }.presentationDetents([.medium, .large]).interactiveDismissDisabled(busy)
            .onDisappear { stopVoice() }
            .onChange(of: scenePhase) { _, phase in if phase != .active { stopVoice() } }
    }
    private func startVoice() {
        let prefix = text.trimmingCharacters(in: .whitespacesAndNewlines)
        startingVoice = true; errorMessage = nil
        voiceTask = Task { @MainActor in
            defer { startingVoice = false }
            do { try await recorder.start { transcript in text = [prefix, transcript].filter { !$0.isEmpty }.joined(separator: " ") } }
            catch is CancellationError {} catch { errorMessage = error.localizedDescription }
        }
    }
    private func stopVoice() { voiceTask?.cancel(); voiceTask = nil; startingVoice = false; recorder.stop() }
}
