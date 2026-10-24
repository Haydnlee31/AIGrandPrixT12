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

/// Real local intent editing plus explicitly authored examples of the future AI presentation.
/// Nothing in this view claims the user's image was analyzed.
struct LocalIntelligencePreview: View {
    let item: SavedItem
    var onChanged: () -> Void = {}
    @State private var intent: String?
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var acknowledgment: String?
    @State private var showingEditor = false
    @State private var showingExample = false
    @State private var analysis: CaptureIntelligenceResult?
    @State private var analyzing = false
    @State private var analysisError: String?
    private var choices: [String] { analysis?.prompts.map(\.text) ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PreviewSection(title: "What caught your eye?", symbol: "sparkles") {
                Text(choices.isEmpty ? "Tell us what draws you to this find." : "Suggestions from your find. Choose one, or tell us in your own words.").font(.subheadline).foregroundStyle(.secondary)
                if analyzing { ProgressView("Looking at your find…").font(.subheadline) }
                HStack(spacing: 12) {
                    Label(item.hasImage ? "Photo saved" : "Original saved", systemImage: item.hasImage ? "photo" : "bookmark")
                    if !item.note.isEmpty { Label("Your note", systemImage: "quote.bubble") }
                }.font(.caption).foregroundStyle(.secondary)
                ForEach(choices, id: \.self) { choice in
                    Button { Task { await saveIntent(choice) } } label: {
                        HStack {
                            Image(systemName: intent == choice ? "checkmark.circle.fill" : "plus.circle")
                            Text(choice).font(.subheadline.weight(.semibold))
                            Spacer()
                        }.padding(14).foregroundStyle(intent == choice ? Color.blue : Color.primary)
                            .background(NativeTheme.bg, in: RoundedRectangle(cornerRadius: 16))
                    }.buttonStyle(.plain).disabled(busy)
                }
                if let intent, !choices.contains(intent) {
                    Label(intent, systemImage: "checkmark.circle.fill").font(.subheadline).foregroundStyle(.blue)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Button(intent == nil ? "Add your own · type or speak" : "Edit your intention", systemImage: "mic") { showingEditor = true }
                    Spacer()
                    Menu {
                        Button("Clear choice") { Task { await saveIntent(nil, message: "Choice cleared") } }
                        Button("Skip for now") { acknowledgment = "Skipped for now" }
                        if intent != nil { Button("Remove intention", role: .destructive) { Task { await saveIntent(nil, message: "Intention removed") } } }
                    } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.accessibilityLabel("Intention options")
                }.font(.subheadline).disabled(busy)
                Text(analysis == nil ? "Your intention stays with this find." : "Generated with OpenAI from the saved context. Your choice remains editable.").font(.caption).foregroundStyle(.secondary)
                if let analysisError {
                    Text(analysisError).font(.caption).foregroundStyle(.secondary)
                    Button("Try suggestions again") { Task { await analyzeFind() } }.disabled(analyzing)
                }
                if let acknowledgment { Label(acknowledgment, systemImage: "checkmark.circle").font(.caption).foregroundStyle(.green) }
                if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(.red) }
            }

            PreviewSection(title: "Understand this find", symbol: "viewfinder") {
                if let analysis {
                    Label("Analyzed with OpenAI", systemImage: "sparkles").font(.caption.bold()).foregroundStyle(.blue)
                    Text(analysis.productName ?? "More context needed").font(.headline.bold())
                    Text(analysis.summary).font(.subheadline).foregroundStyle(.secondary)
                    LabeledContent("Category", value: analysis.categoryPath.isEmpty ? "Unknown" : analysis.categoryPath.joined(separator: " › "))
                    LabeledContent("Brand", value: analysis.brand ?? "Unknown")
                    LabeledContent("Style", value: analysis.style.isEmpty ? "Unknown" : analysis.style.joined(separator: " · "))
                    if !analysis.evidence.isEmpty {
                        Text("Based on your find").font(.subheadline.bold())
                        ForEach(analysis.evidence, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                    }
                    ForEach(analysis.uncertainties, id: \.self) { Label($0, systemImage: "questionmark.circle").font(.caption).foregroundStyle(.secondary) }
                } else {
                HStack {
                    Label(analyzing ? "Analyzing your find" : "Not analyzed yet", systemImage: "clock").font(.subheadline.weight(.semibold))
                    Spacer()
                }
                Text("Your original, photos and notes are safe here. Product recognition becomes available when analysis is connected.").font(.subheadline).foregroundStyle(.secondary)
                LabeledContent("Product & category", value: "Not identified")
                LabeledContent("Brand & model", value: "Unknown")
                LabeledContent("Style & details", value: "Not analyzed")
                Button { withAnimation(.easeInOut(duration: 0.2)) { showingExample.toggle() } } label: {
                    HStack { Text(showingExample ? "Hide example breakdown" : "See an example breakdown"); Spacer(); Image(systemName: showingExample ? "chevron.up" : "chevron.down") }
                }.font(.subheadline.weight(.semibold))
                if showingExample { WatchAnalysisExample() }
                }
            }

            PreviewSection(title: "Made personal by you", symbol: "person.crop.circle.badge.checkmark") {
                if let intent {
                    Text(intent).font(.headline)
                    Text("Your chosen intention. You can search for it in Library.").font(.subheadline).foregroundStyle(.secondary)
                } else {
                    Text("A feeling, a constraint, a little context.").font(.headline)
                    Text("Try “I like this shape, but it needs to fit a small desk.” Nothing is assumed until you tell us.").font(.subheadline).foregroundStyle(.secondary)
                }
                if !item.note.isEmpty {
                    Text("Your note").font(.caption.bold()).foregroundStyle(.secondary)
                    Text(item.note).font(.subheadline).textSelection(.enabled)
                }
            }
        }
        .task(id: "\(item.id)|\(item.revision)") {
            do {
                let saved = try await LocalLibrary.shared.metadata()[item.id]
                intent = saved?.intent; analysis = saved?.analysis
                if analysis == nil, CaptureIntelligence.isConfigured, item.client != "sample" { await analyzeFind() }
            }
            catch { errorMessage = error.localizedDescription }
        }
        .sheet(isPresented: $showingEditor) {
            LocalIntentEditor(initial: intent ?? "") { value in
                await saveIntent(value)
                return errorMessage == nil
            }
        }
    }

    @MainActor private func analyzeFind() async {
        guard !analyzing, CaptureIntelligence.isConfigured else { return }
        analyzing = true; analysisError = nil
        defer { analyzing = false }
        do {
            let metadata = try await LocalLibrary.shared.metadata()[item.id]
            var image: Data?
            if let attachment = metadata?.attachments.first(where: \.isImage) { image = try await LocalLibrary.shared.attachmentData(attachment) }
            let result = try await CaptureIntelligence.analyze(url: item.originalUrl.isEmpty ? nil : item.originalUrl,
                title: item.title, text: item.selectedText, note: item.note, imageData: image)
            try Task.checkCancellation()
            try await LocalLibrary.shared.setAnalysis(item.id, result)
            analysis = result; onChanged()
        } catch is CancellationError {} catch { analysisError = error.localizedDescription }
    }

    @MainActor private func saveIntent(_ value: String?, message: String = "Intention saved on this iPhone") async {
        guard !busy else { return }; busy = true; errorMessage = nil
        defer { busy = false }
        do {
            try await LocalLibrary.shared.setIntent(item.id, value)
            intent = value; acknowledgment = message; onChanged()
            FindsHaptics.success()
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct WatchAnalysisExample: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Divider()
            ExamplePreviewBadge()
            HStack(spacing: 14) {
                Image(systemName: "applewatch").font(.system(size: 45)).foregroundStyle(.blue)
                    .frame(width: 76, height: 88).background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 20))
                VStack(alignment: .leading, spacing: 6) {
                    Text("A vintage-inspired digital watch").font(.headline.bold())
                    Text("Illustrative watch example.").font(.caption).foregroundStyle(.secondary)
                }
            }
            LabeledContent("Category", value: "Accessories › Watches › Digital")
            LabeledContent("Brand", value: "Unknown")
            LabeledContent("Model", value: "Unknown")
            LabeledContent("Display", value: "Digital · example detail")
            LabeledContent("Style", value: "Vintage-inspired · interpretation")
            LabeledContent("Material", value: "Unknown · needs confirmation")
            Text("The future analysis would separate visible evidence from style interpretations, and leave unsupported brand or model claims unknown.")
                .font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                Text("Example prompts").font(.subheadline.bold())
                Text("“I like the retro face.”\n“Find something similar with a smaller case.”\n“Compare it with the watch I already own.”")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
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
                Section("What are you drawn to?") {
                    TextEditor(text: $text).frame(minHeight: 130).disabled(recorder.isRecording || startingVoice)
                    Text("\(text.count)/2,000").font(.caption).foregroundStyle(.secondary)
                    Button {
                        if recorder.isRecording || startingVoice { stopVoice() }
                        else { startVoice() }
                    } label: { Label(recorder.isRecording ? "Stop recording" : startingVoice ? "Starting microphone…" : "Tell us in your own words", systemImage: recorder.isRecording ? "stop.circle.fill" : "mic") }
                }
                Section { Text("Voice becomes editable text. Nothing is sent to an AI service.").font(.footnote).foregroundStyle(.secondary) }
                if let errorMessage = errorMessage ?? recorder.errorMessage { Text(errorMessage).foregroundStyle(.red).font(.footnote) }
            }
            .navigationTitle("Your intention").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { stopVoice(); dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        stopVoice(); busy = true
                        Task {
                            if await save(text.trimmingCharacters(in: .whitespacesAndNewlines)) { dismiss() }
                            else { errorMessage = "Couldn’t save your intention. Please try again." }
                            busy = false
                        }
                    }.bold().disabled(busy || startingVoice || recorder.isRecording || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.count > 2000)
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

private struct PreviewCatalogIdea: Identifiable {
    let id: String
    let title: String
    let asset: String?
    let category: String
    let style: String
    let detail: String
    let reason: String
    static let all: [Self] = [
        .init(id: "lamp", title: "A softer kind of light", asset: "sculptural-lamp", category: "Lighting", style: "Sculptural · warm · curved", detail: "An illustrative table-lamp direction with a sculptural silhouette.", reason: "Example match: a warm-lighting preference could connect to a soft, sculptural lamp."),
        .init(id: "reading", title: "A corner just for you", asset: "reading-corner", category: "Small spaces", style: "Calm · natural · cozy", detail: "A reading-corner concept for exploring comfort and a quieter room.", reason: "Example match: a wish for a calmer room could connect to a reading-corner concept."),
        .init(id: "balcony", title: "Your small outdoor escape", asset: "balcony", category: "Small spaces", style: "Compact · green · outdoor", detail: "A small-balcony concept with greenery and room to pause.", reason: "Example match: a small-space constraint could connect to a compact outdoor arrangement."),
        .init(id: "ceramics", title: "Little everyday objects", asset: "ceramics", category: "Objects", style: "Ceramic · textured · earthy", detail: "Illustrative ceramic objects for exploring texture and an earthy palette.", reason: "Example match: an interest in earthy textures could connect to ceramic objects."),
        .init(id: "watch", title: "A little retro on your wrist", asset: nil, category: "Accessories", style: "Digital · vintage-inspired · watch", detail: "A digital-watch direction demonstrating a category and style breakdown. No exact product is identified.", reason: "Example match: a vintage-inspired style preference could connect to a digital-watch direction.")
    ]
}

/// Content-only Explore preview: its parent owns NavigationStack and the search field.
struct ExplorePreviewScreen: View {
    @Binding var query: String
    var libraryRevision: String = ""
    var onChanged: () -> Void = {}
    @State private var category = "All"
    @State private var showsLibrary = false
    @State private var items: [SavedItem] = []
    @State private var metadata: [String: LocalFindMetadata] = [:]
    @State private var errorMessage: String?
    private let categories = ["All", "Lighting", "Small spaces", "Objects", "Accessories"]
    private var ideas: [PreviewCatalogIdea] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return PreviewCatalogIdea.all.filter { (category == "All" || $0.category == category) &&
            (text.isEmpty || [$0.title, $0.category, $0.style, $0.detail].contains { $0.localizedStandardContains(text) }) }
    }
    private var savedMatches: [SavedItem] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return items.filter { item in
            !(metadata[item.id]?.isArchived ?? false) && (text.isEmpty ||
                [item.title, item.note, item.selectedText, metadata[item.id]?.intent ?? "", metadata[item.id]?.analysis?.searchableText ?? ""].contains { $0.localizedStandardContains(text) })
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Follow your curiosity.").font(.title2.bold())
                    Text("A feel for what comes next.").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                ExamplePreviewBadge()
            }
            Picker("Explore content", selection: $showsLibrary) {
                Text("Example ideas").tag(false)
                Text("Your finds").tag(true)
            }.pickerStyle(.segmented)
            if showsLibrary {
                Text("Your real local saves and the intentions you chose. Search matches those words; no AI inference has run.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(savedMatches) { item in
                    NavigationLink {
                        SavedContentView(item: item, stillSaved: items.contains { $0.id == item.id }, localOnly: true,
                                         onChanged: { Task { await load() }; onChanged() }, onDelete: { id, _ in
                            try await LocalLibrary.shared.delete(id); await load(); onChanged()
                        })
                    } label: {
                        VStack(alignment: .leading, spacing: 9) {
                            SavedContentCard(item: item, compact: true)
                            if let intent = metadata[item.id]?.intent { Label(intent, systemImage: "checkmark.bubble").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 18) }
                        }
                    }.buttonStyle(.plain)
                }
                if savedMatches.isEmpty { ContentUnavailableView.search(text: query) }
            } else {
                Text("Explore example ideas by category and style. Personalized recommendations will appear when analysis is connected.")
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(categories, id: \.self) { value in
                            Button { category = value } label: {
                                Text(value).font(.subheadline.weight(.semibold)).padding(.horizontal, 15).padding(.vertical, 10)
                                    .foregroundStyle(category == value ? NativeTheme.bg : Color.primary)
                                    .background(category == value ? Color.primary : NativeTheme.surface, in: Capsule())
                            }.buttonStyle(.plain).accessibilityAddTraits(category == value ? .isSelected : [])
                        }
                    }
                }
                ForEach(ideas) { idea in
                    NavigationLink { PreviewIdeaDetail(idea: idea) { Task { await load() }; onChanged() } } label: { PreviewIdeaCard(idea: idea) }.buttonStyle(.plain)
                }
                if ideas.isEmpty { ContentUnavailableView.search(text: query) }
            }
            if let errorMessage { Text(errorMessage).font(.footnote).foregroundStyle(.red) }
        }.task(id: libraryRevision) { await load() }
    }
    @MainActor private func load() async {
        do { items = try await LocalLibrary.shared.collection(); metadata = try await LocalLibrary.shared.metadata(); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }
}

private struct PreviewIdeaCard: View {
    let idea: PreviewCatalogIdea
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let asset = idea.asset {
                Image(asset).resizable().scaledToFill().frame(height: 220).clipped().accessibilityLabel("Illustrative \(idea.category.lowercased()) image")
            } else {
                Color.blue.opacity(0.08).frame(height: 160).overlay { Image(systemName: "applewatch").font(.system(size: 76, weight: .light)).foregroundStyle(.blue) }
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack { Text(idea.category).font(.caption.weight(.semibold)).foregroundStyle(.secondary); Spacer(); ExamplePreviewBadge() }
                Text(idea.title).font(.title3.bold()).foregroundStyle(.primary)
                Text(idea.style).font(.subheadline).foregroundStyle(.secondary)
                HStack { Text("See the idea & why it connects").font(.subheadline.weight(.semibold)); Spacer(); Image(systemName: "arrow.up.right") }.foregroundStyle(.blue)
            }.padding(18)
        }.background(NativeTheme.surface, in: RoundedRectangle(cornerRadius: 26)).clipShape(RoundedRectangle(cornerRadius: 26))
    }
}

private struct PreviewIdeaDetail: View {
    let idea: PreviewCatalogIdea
    var onSaved: () -> Void = {}
    @State private var saving = false
    @State private var saved = false
    @State private var captureID = UUID().uuidString
    @State private var errorMessage: String?
    @State private var note = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PreviewIdeaCard(idea: idea)
                Text(idea.detail).font(.body)
                PreviewSection(title: "Product details", symbol: "viewfinder") {
                    LabeledContent("Category", value: idea.category)
                    LabeledContent("Style", value: idea.style)
                    LabeledContent("Brand & model", value: "Unknown")
                    LabeledContent("Price & availability", value: "Not provided")
                    Text("These fields demonstrate the interface. They were authored for this preview, not extracted by AI.").font(.caption).foregroundStyle(.secondary)
                }
                PreviewSection(title: "Why this example?", symbol: "sparkles") {
                    ExamplePreviewBadge()
                    Text(idea.reason).font(.subheadline)
                    Text("This explanation demonstrates how a future recommendation could cite a confirmed preference. It is not evidence about your preferences.").font(.caption).foregroundStyle(.secondary)
                    NavigationLink { PreviewSourceView(idea: idea) } label: { Label("View example source", systemImage: "link") }
                }
                PreviewSection(title: "Make this direction yours", symbol: "bookmark") {
                    TextField("What do you like about it?", text: $note, axis: .vertical).lineLimit(3...6)
                    Button(saved ? "Saved to your library" : "Save this inspiration", systemImage: saved ? "checkmark.circle.fill" : "plus") { Task { await save() } }
                        .font(.headline).disabled(saving || saved || note.count > 2000)
                    Text("Saves this labeled example and your note locally. No product is purchased.").font(.caption).foregroundStyle(.secondary)
                    if saving { ProgressView("Saving inspiration") }
                    if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(.red) }
                }
            }.padding(20)
        }.navigationTitle("Explore an idea").navigationBarTitleDisplayMode(.inline)
    }
    @MainActor private func save() async {
        guard !saving, !saved else { return }; saving = true; errorMessage = nil
        defer { saving = false }
        do {
            var attachments: [LocalCaptureAttachment] = []
            if let asset = idea.asset, let data = UIImage(named: asset)?.jpegData(compressionQuality: 0.8) {
                attachments.append(.init(filename: "Example inspiration.jpg", typeIdentifier: "public.jpeg", data: data))
            }
            _ = try await LocalLibrary.shared.captureContent(title: "Example inspiration: \(idea.title)",
                text: "Example preview. \(idea.detail) Category: \(idea.category). Style: \(idea.style). This is authored illustrative content, not a live product or AI analysis.",
                note: note, source: .product, attachments: attachments, id: "preview-idea-\(captureID)")
            saved = true; FindsHaptics.success(); onSaved()
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct PreviewSourceView: View {
    let idea: PreviewCatalogIdea
    var body: some View {
        List {
            Section {
                ExamplePreviewBadge()
                Text(idea.title).font(.title2.bold())
                Text("Source: the app’s bundled illustrative collection.")
                Text("This example source is included to demonstrate the citation interface. There is no merchant, product record, verified price or checkout URL attached.").font(.subheadline).foregroundStyle(.secondary)
            }
            Section("What this source supports") {
                LabeledContent("Authored category", value: idea.category)
                Text(idea.style).font(.subheadline)
            }

        }.navigationTitle("Example source").navigationBarTitleDisplayMode(.inline)
    }
}
