import SwiftUI
import CommonThreadKit
import PhotosUI
import UniformTypeIdentifiers

/// The same immutable request and key survive retries through the shared outbox.
struct CaptureForm: View {
    let connection: SharedEnvironment?
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var voiceRecorder = VoiceNoteRecorder()
    @State private var transcriptText: String?
    @State private var transcriptWasEdited = false
    @State private var reviewedTranscript: String?
    @State private var showingDiscardRecording = false
    @State private var link = ""
    @State private var title = ""
    @State private var titleWasEdited = false
    @State private var selectedIntents: [String] = []
    @State private var refinement: IntentRefinementContext?
    @State private var note = ""
    @State private var savedText = ""
    @State private var attachments: [DraftAttachment] = []
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var detailPhoto: DraftAttachment?
    @State private var showingFiles = false
    @State private var showingCamera = false
    @State private var loadingMedia = false
    @State private var localDestination = false
    @State private var format: CaptureFormat = .link
    private enum CaptureFormat: String, CaseIterable, Identifiable {
        case link = "Link", photos = "Photos", text = "Text", files = "Files"
        var id: String { rawValue }
        var symbol: String { switch self { case .link: "link"; case .photos: "photo.on.rectangle"; case .text: "text.alignleft"; case .files: "doc" } }
    }
    private var effectiveConnection: SharedEnvironment? { localDestination ? nil : connection }
    private var cloudCompatible: Bool {
        let images = attachments.filter { $0.value.typeIdentifier == UTType.jpeg.identifier }
        let audio = attachments.filter { ["m4a", "wav"].contains(($0.value.filename as NSString).pathExtension.lowercased()) }
        return images.count <= 4 && audio.count <= 1 && images.count + audio.count == attachments.count
            && attachments.allSatisfy { $0.value.data.count <= 4 * 1024 * 1024 }
            && attachments.reduce(0, { $0 + $1.value.data.count }) <= 16 * 1024 * 1024
    }
    @State private var saving = false
    @State private var pending: PendingCapture?
    @State private var pendingMultimodal: PendingSharedMultimodal?
    @State private var localRecoveryID = UUID().uuidString
    @State private var receipt: CaptureReceipt?
    @State private var message: String?
    @State private var canRetry = true
    @State private var maxURL = 2048
    @State private var maxTitle = 300
    @State private var maxNote = 2000
    @State private var analysis: CaptureIntelligenceResult?
    @State private var analysisInput: AnalysisInput?
    @State private var analysisError: String?
    @State private var analyzing = false
    @State private var analysisRequestID = UUID()
    @State private var analysisRetry = 0
    private struct AnalysisInput: Equatable {
        let url: String
        let title: String
        let text: String
        let attachmentIDs: [UUID]
        let note: String
        let reviewedTranscript: String?
    }
    private struct AnalysisRequest: Equatable {
        let input: AnalysisInput
        let ready: Bool
        let retry: Int
    }
    @FocusState private var focused: Field?
    private enum Field: Hashable { case link, title, note }
    private var cleanedLink: String { link.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var resolvedTitle: String {
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return text }
        if !cleanedLink.isEmpty { return "A new find" }
        if let attachment = attachments.first {
            return attachment.preview == nil ? (attachment.value.filename as NSString).deletingPathExtension : "A photo worth saving"
        }
        return String(savedText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
    }
    private var connectedNote: String { ([note] + selectedIntents).filter { !$0.isEmpty }.joined(separator: "\n") }
    private var valid: Bool {
        if !cleanedLink.isEmpty {
            guard let url = URL(string: cleanedLink), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  let host = url.host, host.contains("."), url.user == nil, url.password == nil else { return false }
        }
        return (!cleanedLink.isEmpty || !attachments.isEmpty || !savedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && !resolvedTitle.isEmpty && cleanedLink.count <= maxURL && resolvedTitle.count <= maxTitle
            && note.count <= maxNote && savedText.count <= 12000 && !loadingMedia
            && (effectiveConnection == nil || (cloudCompatible && connectedNote.count <= maxNote))
    }
    private var frozen: Bool { pending != nil || pendingMultimodal != nil || saving || receipt != nil }
    private var voiceBusy: Bool { voiceRecorder.isPreparing || voiceRecorder.isRecording || voiceRecorder.isFinishing }
    private var hasVoice: Bool { attachments.contains { UTType($0.value.typeIdentifier)?.conforms(to: .audio) == true } }
    private var canSave: Bool { !voiceBusy && !saving && canRetry && receipt == nil && (pending != nil || pendingMultimodal != nil || valid) }
    private var currentAnalysisInput: AnalysisInput {
        AnalysisInput(url: cleanedLink, title: titleWasEdited ? title.trimmingCharacters(in: .whitespacesAndNewlines) : "",
                      text: savedText.trimmingCharacters(in: .whitespacesAndNewlines), attachmentIDs: attachments.map(\.id), note: note, reviewedTranscript: reviewedTranscript)
    }
    private var analysisRequest: AnalysisRequest {
        AnalysisRequest(input: currentAnalysisInput,
                        ready: CaptureIntelligence.isConfigured && valid && !frozen && !voiceBusy && scenePhase == .active,
                        retry: analysisRetry)
    }
    private var currentAnalysis: CaptureIntelligenceResult? { analysisInput == currentAnalysisInput ? analysis : nil }

    var body: some View {
        captureWithLifecycle
        .sheet(item: $detailPhoto) { attachment in
            PhotoDetailSelector(attachment: attachment, productTitle: currentAnalysis?.productName ?? resolvedTitle) { preference in
                guard selectedIntents.count < 8 else { return false }
                if !selectedIntents.contains(preference) { selectedIntents.append(preference) }
                return true
            }
        }
        .sheet(item: $refinement) { context in
            IntentRefinementSheet(context: context) { choice in
                guard selectedIntents.count < 8 || selectedIntents.contains(choice) else { return false }
                if !selectedIntents.contains(choice) { selectedIntents.append(choice) }
                FindsHaptics.selection()
                return true
            }
        }
        .onChange(of: photoSelection) { _, selection in
            Task { await loadPhotos(selection) }
        }
        .fileImporter(isPresented: $showingFiles, allowedContentTypes: [.image, .pdf, .plainText, .movie, .audio], allowsMultipleSelection: true) { result in
            do { for url in try result.get() { try addAttachment(CaptureMedia.file(url)) } }
            catch { message = error.localizedDescription }
        }
        .fullScreenCover(isPresented: $showingCamera) {
            CameraPicker { image in
                do {
                    guard let data = image.jpegData(compressionQuality: 0.95) else { throw LocalLibrary.LocalError.invalidMedia }
                    try addAttachment(CaptureMedia.image(data, name: "Camera find.jpg"))
                } catch { message = error.localizedDescription }
            }.ignoresSafeArea()
        }
    }

    private var captureNavigation: some View {
        NavigationStack {
            Group {
                if let receipt { confirmation(receipt) }
                else { editor }
            }
            .background(NativeTheme.bg)
            .navigationTitle(receipt == nil ? "Save a find" : "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(receipt == nil ? "Close" : "Done") {
                        if voiceBusy { showingDiscardRecording = true } else { dismiss() }
                    }.disabled(saving)
                }
            }
        }
    }

    private var captureWithLifecycle: some View {
        captureNavigation
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(saving || voiceBusy)
        .confirmationDialog("Discard this recording?", isPresented: $showingDiscardRecording, titleVisibility: .visible) {
            Button("Discard recording", role: .destructive) { voiceRecorder.cancel(); dismiss() }
            Button("Keep recording", role: .cancel) { }
        } message: { Text("This voice note has not been attached to your find yet.") }
        .task { await prepareCapture() }
        .task(id: analysisRequest) { await analyzeCapture(analysisRequest) }
        .onChange(of: scenePhase) { _, phase in
            voiceRecorder.handleSceneChange(isActive: phase == .active, isBackground: phase == .background)
        }
        .onDisappear { voiceRecorder.cancel() }
        .onChange(of: currentAnalysisInput) { _, _ in
            if !frozen { localRecoveryID = UUID().uuidString }
            analysis = nil; analysisInput = nil; analysisError = nil; analyzing = false
            if !titleWasEdited { title = "" }
        }
    }

    @MainActor private func prepareCapture() async {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-verifyMultimodalDraft"), attachments.isEmpty {
            let metadata = (try? await LocalLibrary.shared.metadata()) ?? [:]
            let originals = metadata.values.flatMap(\.attachments).filter(\.isImage)
            for attachment in Array(originals.sorted { $0.id.uuidString < $1.id.uuidString }.prefix(2)) {
                if let bytes = try? await LocalLibrary.shared.attachmentData(attachment) {
                    try? addAttachment(CaptureMedia.image(bytes, name: attachment.filename))
                }
            }
            note = "Compare the dials and straps in these watches. Do not assume they are the same model."
        }
        if ProcessInfo.processInfo.arguments.contains("-demoWatchDraft"), link.isEmpty, title.isEmpty, savedText.isEmpty {
            format = .text
            title = "Vintage-style digital watch"
            savedText = "A compact rectangular digital wristwatch with a silver stainless-steel bracelet, a black LCD face, and a retro 1980s look. No brand or model is identified."
        }
        #endif
        if let connection, let limits = try? await connection.client().capabilities().capture {
            maxURL = limits.maxUrlLength; maxTitle = limits.maxTitleLength; maxNote = limits.maxNoteLength
        }
    }

    private var editor: some View {
        ScrollViewReader { proxy in
          ScrollView {
            VStack(alignment: .leading, spacing: 25) {
                HStack(spacing: 14) {
                    Image(systemName: "link").font(.title2.bold()).foregroundStyle(.blue)
                        .frame(width: 58, height: 58).background(.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 18))
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Keep what caught your eye.").font(.title3.bold())
                        Text("Links, photos, files, and little ideas.").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Picker("Save format", selection: $format) {
                    ForEach(CaptureFormat.allCases) { Label($0.rawValue, systemImage: $0.symbol).tag($0) }
                }.pickerStyle(.segmented).disabled(frozen).accessibilityIdentifier("captureFormat")

                if format == .photos || format == .files {
                    HStack(spacing: 12) {
                        PhotosPicker(selection: $photoSelection, maxSelectionCount: max(1, 10 - attachments.count), matching: .images) {
                            Label("Photos", systemImage: "photo.on.rectangle")
                        }.buttonStyle(.bordered).disabled(frozen || loadingMedia || voiceBusy)
                        if UIImagePickerController.isSourceTypeAvailable(.camera) {
                            Button { showingCamera = true } label: { Label("Camera", systemImage: "camera") }
                                .buttonStyle(.bordered).disabled(frozen || voiceBusy)
                        }
                        Button { showingFiles = true } label: { Label("Files", systemImage: "folder") }
                            .buttonStyle(.bordered).disabled(frozen || voiceBusy)
                    }
                    Text("Photos are optimized for your library. You can also keep PDFs, text files, short videos, and audio files on this iPhone.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if loadingMedia { ProgressView("Preparing your photos…") }
                if !attachments.isEmpty { attachmentPreviews }
                VStack(alignment: .leading, spacing: 13) {
                    Text(format == .text ? "The thought" : "The original").font(.headline.bold())
                    if format == .text {
                        TextField("A product idea, a quote, something to come back to…", text: $savedText, axis: .vertical)
                            .lineLimit(4...9).accessibilityIdentifier("captureText")
                        Divider()
                    }
                    TextField(format == .link ? "Paste a public link" : "Original link (optional)", text: $link)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($focused, equals: .link).accessibilityIdentifier("captureURL")
                    Divider()
                    TextField("A name for your find", text: Binding(get: { title }, set: { title = $0; titleWasEdited = true }))
                        .focused($focused, equals: .title).accessibilityIdentifier("captureTitle")
                }.padding(20).background(NativeTheme.surface, in: RoundedRectangle(cornerRadius: 24)).disabled(frozen)
                if connection != nil {
                    Toggle("Keep on this iPhone", isOn: $localDestination).disabled(frozen)
                    if !localDestination && !cloudCompatible {
                        Text("Shared finds support up to four photos and one M4A or WAV voice note. Keep other file types on this iPhone.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 13) {
                    Text("What caught your eye?").font(.title3.bold())
                    TextField("The shape, the feeling, something you need…", text: $note, axis: .vertical)
                        .lineLimit(2...6).focused($focused, equals: .note)
                        .disabled(frozen)
                        .accessibilityIdentifier("captureNote")
                    HStack {
                        Text("Optional. Keep a little context for later.")
                        Spacer()
                        if note.count > maxNote - 200 { Text("\(note.count)/\(maxNote)").foregroundStyle(note.count > maxNote ? .red : .secondary) }
                    }.font(.caption).foregroundStyle(.secondary)
                    voiceNoteControls.id("captureVoiceControls")
                    if pending == nil && pendingMultimodal == nil { predictiveNotes.id("capturePredictiveNotes") }
                    if effectiveConnection != nil && connectedNote.count > maxNote {
                        Text("Shorten your note or remove a selection before saving to your shared library.")
                            .font(.caption).foregroundStyle(.red)
                    }
                }.padding(20).background(NativeTheme.surface, in: RoundedRectangle(cornerRadius: 24))
                if let text = message {
                    Label(text, systemImage: "info.circle").font(.subheadline).foregroundStyle(.secondary)
                        .accessibilityIdentifier("captureStatus")
                }
                if let pending, !saving {
                    Button("Discard pending save and edit", role: .destructive) {
                        Task {
                            do {
                                try await SharedEnvironment.outbox().remove(pending)
                                self.pending = nil; message = nil; canRetry = true
                            } catch { message = error.localizedDescription }
                        }
                    }.font(.subheadline)
                }
                if saving { ProgressView("Saving your find…").frame(maxWidth: .infinity) }
                Button {
                    FindsHaptics.selection()
                    focused = nil; Task { await save() }
                } label: {
                    Text(pending == nil && pendingMultimodal == nil ? "Save find" : canRetry ? "Retry save" : "Reconnect or edit to continue")
                        .font(.headline.bold())
                        .foregroundStyle(canSave ? Color.black : Color.secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 19)
                        .background(canSave ? Color.white : Color(.tertiarySystemFill), in: Capsule())
                        .overlay { Capsule().strokeBorder(Color.primary.opacity(canSave ? 0.16 : 0.06), lineWidth: 1) }
                }.buttonStyle(.plain)
                    .disabled(!canSave)
                    .animation(.easeInOut(duration: 0.18), value: canSave)
                    .accessibilityIdentifier("captureSave")
                Text(effectiveConnection != nil
                     ? "Your photos and voice are analyzed together, then saved to your shared Library. A recovery copy stays on this iPhone."
                     : CaptureIntelligence.isConfigured
                        ? "Your photos and note are analyzed together. You can save now; insights appear in your Library when ready."
                        : "Your note stays with your find.")
                    .font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }.padding(24).frame(maxWidth: 600).frame(maxWidth: .infinity)
          }.scrollDismissesKeyboard(.interactively)
          .onChange(of: hasVoice) { _, present in
              if present {
                  withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo("captureVoiceControls", anchor: .center) }
              }
          }
          #if DEBUG
          .onChange(of: currentAnalysis?.analyzedAt) { _, analyzedAt in
              guard analyzedAt != nil, ProcessInfo.processInfo.arguments.contains("-demoWatchDraft") else { return }
              withAnimation(.easeInOut(duration: 0.3)) {
                  proxy.scrollTo("capturePredictiveNotes", anchor: .top)
              }
          }
          #endif
        }
    }

    private var voiceNoteControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            if voiceRecorder.isPreparing {
                ProgressView("Starting microphone…")
            } else if voiceRecorder.isFinishing {
                ProgressView("Preparing your voice note…")
            } else if voiceRecorder.isRecording {
                Button { voiceRecorder.stop() } label: {
                    Label("Stop recording · \(voiceRecorder.elapsed)s / 60s", systemImage: "stop.circle.fill")
                }.tint(.red).accessibilityIdentifier("captureStopVoice")
            } else if !hasVoice {
                Button {
                    focused = nil
                    Task { await voiceRecorder.start { value in
                        do { try addAttachment(value) } catch { message = error.localizedDescription }
                    } }
                } label: { Label("Record a voice note", systemImage: "mic") }
                    .disabled(frozen || loadingMedia || voiceRecorder.isPreparing).accessibilityIdentifier("captureRecordVoice")
            }
            Text(voiceRecorder.isPreparing ? "Starting microphone" : voiceRecorder.isFinishing ? "Preparing voice note" : voiceRecorder.isRecording ? "Recording" : hasVoice ? "Voice note attached" : "Ready to record")
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("captureVoiceState")
                .accessibilityValue(voiceRecorder.isPreparing ? "preparing" : voiceRecorder.isFinishing ? "finishing" : voiceRecorder.isRecording ? "recording" : "idle")
            if let error = voiceRecorder.errorMessage {
                Text(error).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("voiceRecordError")
            }
            if hasVoice && transcriptText == nil && !CaptureIntelligence.isConfigured {
                Text("Sign in through Profile to transcribe this voice note. You can save the recording on this iPhone now.")
                    .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("voiceSignInRequired")
            }
            if transcriptText != nil {
                Text("Your voice note").font(.subheadline.bold())
                TextField("Review the transcript", text: Binding(get: { transcriptText ?? "" }, set: { transcriptText = $0; transcriptWasEdited = true }), axis: .vertical)
                    .lineLimit(3...8).disabled(frozen).accessibilityIdentifier("captureTranscript")
                Button("Use corrected transcript") {
                    reviewedTranscript = transcriptText?.trimmingCharacters(in: .whitespacesAndNewlines)
                    transcriptWasEdited = false
                }.disabled(frozen || (transcriptText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                    || (transcriptText?.count ?? 0) > 8000 || transcriptText == (reviewedTranscript ?? currentAnalysis?.transcript))
                Text("Corrections update your suggestions. Your recording remains with this find until you remove it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var predictiveNotes: some View {
        VStack(alignment: .leading, spacing: 12) {
            if analyzing {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(hasVoice && transcriptText == nil ? "Transcribing your voice…" : "Finding what makes this interesting…").font(.subheadline).foregroundStyle(.secondary)
                }.accessibilityIdentifier("captureAnalysisLoading")
            } else if let analysis = currentAnalysis {
                if !analysis.prompts.isEmpty {
                    ForEach(Array(analysis.prompts.filter { !selectedIntents.contains($0.text) }.prefix(3).enumerated()), id: \.element.id) { index, prompt in
                        intentionButton(prompt.text, index: index)
                    }
                } else {
                    Text("Tell us what you like in your own words.").font(.subheadline).foregroundStyle(.secondary)
                }
            } else if let analysisError {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Suggestions couldn’t load yet. Your find can still be saved.").font(.subheadline).foregroundStyle(.secondary)
                    Text(analysisError).font(.caption).foregroundStyle(.secondary)
                    Button("Try suggestions again") { self.analysisError = nil; analysisRetry += 1 }
                        .font(.subheadline.bold()).disabled(!analysisRequest.ready)
                }.accessibilityIdentifier("captureAnalysisError")
            } else if CaptureIntelligence.isConfigured {
                Text("Add a link, photo, or text to get suggestions for this find.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            SelectedIntentChips(values: selectedIntents, onRefine: { openRefinement($0) },
                onRemove: { value in selectedIntents.removeAll { $0 == value } }, disabled: frozen)
            if CaptureIntelligence.isConfigured {
                Text("Your shared content is sent to OpenAI for these suggestions.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func intentionButton(_ text: String, index: Int) -> some View {
        let selected = selectedIntents.contains(text)
        let color: Color = [.blue, .purple, .orange][index % 3]
        let symbol = ["sparkles", "heart.fill", "slider.horizontal.3"][index % 3]
        return Button {
            toggleIntention(text)
        } label: {
            HStack(spacing: 13) {
                Image(systemName: symbol).font(.title3.weight(.semibold)).foregroundStyle(color)
                    .frame(width: 44, height: 44).background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 14))
                Text(text).font(.body.weight(.semibold)).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: selected ? "checkmark.circle.fill" : "plus.circle")
                    .font(.title3.weight(.semibold)).foregroundStyle(selected ? color : .secondary)
            }.padding(14).background(color.opacity(selected ? 0.11 : 0.035), in: RoundedRectangle(cornerRadius: 20))
                .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(color.opacity(selected ? 0.7 : 0.13), lineWidth: 1) }
        }.buttonStyle(.plain).disabled(frozen)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func toggleIntention(_ text: String) {
        if !selectedIntents.contains(text) {
            guard selectedIntents.count < 8 else { message = "You can keep up to eight details. Hold one to remove it."; return }
            selectedIntents.append(text)
        }
        FindsHaptics.selection()
        openRefinement(text)
    }
    private func openRefinement(_ text: String) {
        guard let analysis = currentAnalysis, analysis.productName != nil, CaptureIntelligence.isConfigured else { return }
        focused = nil
        refinement = IntentRefinementContext(analysis: analysis, selectedIntent: text, existingIntents: selectedIntents)
    }

    @MainActor private func analyzeCapture(_ request: AnalysisRequest) async {
        let requestID = UUID()
        analysisRequestID = requestID
        defer { if requestID == analysisRequestID { analyzing = false } }
        guard request.ready else {
            analyzing = false
            return
        }
        if currentAnalysis != nil { return }
        analysis = nil; analysisInput = nil; analysisError = nil; analyzing = true
        do {
            try await Task.sleep(for: .milliseconds(700))
            try Task.checkCancellation()
            guard request == analysisRequest, requestID == analysisRequestID else { return }
            analyzing = true
            let images = attachments.filter { UTType($0.value.typeIdentifier)?.conforms(to: .image) == true }.map { $0.value.data }
            let recordings = attachments.filter { UTType($0.value.typeIdentifier)?.conforms(to: .audio) == true }
            guard recordings.count <= 1 else { throw MultimodalDraftAnalysis.Failure.unsupportedAudio }
            let audio = try recordings.first.map { try MultimodalDraftAnalysis.Audio(data: $0.value.data, filename: $0.value.filename) }
            let result = try await CaptureIntelligence.analyze(url: request.input.url.isEmpty ? nil : request.input.url,
                title: request.input.title, text: request.input.text, note: request.input.note, imageData: images.first, additionalImages: Array(images.dropFirst()), audio: audio, reviewedTranscript: request.input.reviewedTranscript,
                onTranscript: { text in
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        guard !Task.isCancelled, request == analysisRequest, requestID == analysisRequestID, !transcriptWasEdited else { return }
                        transcriptText = text
                    }
                })
            try Task.checkCancellation()
            guard request == analysisRequest, requestID == analysisRequestID else { return }
            analysis = result; analysisInput = request.input
            if let transcript = result.transcript, !transcriptWasEdited { transcriptText = transcript }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-verifyMultimodalDraft") {
                let report = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("multimodal-device-verification.json")
                try? JSONEncoder().encode(result).write(to: report, options: .atomic)
            }
            #endif
            if !titleWasEdited, let name = result.productName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                title = String(name.prefix(maxTitle))
            }
        } catch {
            guard requestID == analysisRequestID else { return }
            analysis = nil; analysisInput = nil
            if !Task.isCancelled && !(error is CancellationError) { analysisError = error.localizedDescription }
        }
    }

    private func confirmation(_ receipt: CaptureReceipt) -> some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: receipt.duplicate ? "bookmark.fill" : "checkmark")
                .font(.system(size: 42, weight: .bold)).foregroundStyle(.blue)
                .frame(width: 100, height: 100).background(.blue.opacity(0.10), in: Circle())
            Text(receipt.duplicate ? "Already in your library" : "Saved!").font(.largeTitle.bold()).multilineTextAlignment(.center)
            Text(receipt.duplicate
                 ? "This link was already saved. Its original note and text have been kept."
                 : "\(resolvedTitle)\n\(effectiveConnection == nil ? "Saved on this iPhone." : "Saved to your library.")")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            Spacer()
            NativePrimaryButton(title: "Done") { dismiss() }.accessibilityIdentifier("captureDone")
        }.padding(28)
    }

    @MainActor private func save() async {
        guard !saving, !voiceBusy else { return }
        let analysisToSave = currentAnalysis
        saving = true; message = nil
        defer { saving = false }
        do {
            guard let connection = effectiveConnection else {
                let saved = try await LocalLibrary.shared.captureContent(url: cleanedLink.isEmpty ? nil : cleanedLink, title: resolvedTitle,
                    text: savedText, note: note, source: captureSource, attachments: attachments.map(\.value),
                    intents: selectedIntents, analysis: analysisToSave, userEditedTitle: titleWasEdited)
                if let reviewedTranscript { try await LocalLibrary.shared.setReviewedTranscript(saved.id, reviewedTranscript) }
                receipt = saved
                LocalAnalysisCoordinator.shared.resume()
                FindsHaptics.success(); onSave()
                return
            }
            let outbox = SharedMultimodalOutbox.shared
            let draft: PendingSharedMultimodal
            if let existing = pendingMultimodal { draft = existing }
            else {
                // Save a recoverable original before any network request.
                _ = try await LocalLibrary.shared.captureContent(url: cleanedLink.isEmpty ? nil : cleanedLink,
                    title: resolvedTitle, text: savedText, note: note, source: captureSource, attachments: attachments.map(\.value),
                    id: localRecoveryID, intents: selectedIntents, analysis: analysisToSave, userEditedTitle: titleWasEdited)
                let entry = PendingSharedMultimodal(id: UUID().uuidString, accountID: connection.accountId,
                    origin: connection.baseURL, localID: localRecoveryID,
                    request: .init(title: resolvedTitle, text: savedText, note: connectedNote,
                        url: cleanedLink.isEmpty ? nil : cleanedLink, client: .iosApp), attachments: attachments.map(\.value),
                    reviewedTranscript: reviewedTranscript)
                try await outbox.enqueue(entry)
                pendingMultimodal = entry; draft = entry
            }
            let client = try connection.client()
            try await connection.verify(client)
            try await outbox.retryAnalysis(draft.id, client: client, accountID: connection.accountId, origin: connection.baseURL)
            receipt = try await outbox.send(draft.id, client: client, accountID: connection.accountId, origin: connection.baseURL)
            pendingMultimodal = nil
            FindsHaptics.success(); onSave()
        } catch {
            if let api = error as? APIError { canRetry = api.retryable }
            message = pending == nil && pendingMultimodal == nil ? error.localizedDescription
                : "Pending on this device. \(error.localizedDescription) You can close this sheet and manage it in Profile."
        }
    }
    private var attachmentPreviews: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(attachments) { attachment in
                    VStack(alignment: .leading, spacing: 8) {
                        Group {
                            if let preview = attachment.preview { Image(uiImage: preview).resizable().scaledToFill() }
                            else { Image(systemName: "doc.fill").font(.largeTitle).frame(maxWidth: .infinity, maxHeight: .infinity).background(NativeTheme.surface) }
                        }.frame(width: 276, height: 270).clipped()
                            .overlay(alignment: .bottomLeading) {
                                if attachment.preview != nil, let prompt = currentAnalysis?.prompts.first {
                                    Button { toggleIntention(prompt.text) } label: {
                                        HStack(alignment: .top, spacing: 10) {
                                            Image(systemName: "sparkles").foregroundStyle(.yellow)
                                            VStack(alignment: .leading, spacing: 5) {
                                                Text(prompt.question ?? "What stands out to you?").font(.headline.bold())
                                                Text(prompt.text).font(.subheadline.weight(.medium)).foregroundStyle(.white.opacity(0.85))
                                            }.multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                                            Image(systemName: selectedIntents.contains(prompt.text) ? "checkmark.circle.fill" : "plus.circle")
                                        }.foregroundStyle(.white).padding(14)
                                            .background(.black.opacity(0.64), in: RoundedRectangle(cornerRadius: 18))
                                    }.buttonStyle(.plain).padding(12).disabled(frozen)
                                        .accessibilityHint("Selects: " + prompt.text)
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 24))
                            .onLongPressGesture { if !frozen && attachment.preview != nil { focused = nil; detailPhoto = attachment } }
                        if attachment.preview != nil {
                            Button { focused = nil; detailPhoto = attachment } label: {
                                Label("Highlight a detail", systemImage: "lasso").font(.subheadline.bold())
                            }.tint(.purple).disabled(frozen)
                        }
                        HStack {
                            Text(attachment.value.filename).font(.caption).lineLimit(1)
                                .accessibilityIdentifier(UTType(attachment.value.typeIdentifier)?.conforms(to: .audio) == true ? "voiceAttachment" : "captureAttachment")
                            Spacer()
                            Button("Remove", role: .destructive) {
                                attachments.removeAll { $0.id == attachment.id }
                                if UTType(attachment.value.typeIdentifier)?.conforms(to: .audio) == true { transcriptText = nil; reviewedTranscript = nil; transcriptWasEdited = false }
                            }
                                .font(.caption).disabled(frozen)
                        }.frame(width: 276)
                    }
                }
            }
        }
    }
    private func addAttachment(_ value: LocalCaptureAttachment) throws {
        guard attachments.count < 10, value.data.count <= 12 * 1024 * 1024,
              attachments.reduce(value.data.count, { $0 + $1.value.data.count }) <= 24 * 1024 * 1024 else { throw LocalLibrary.LocalError.mediaTooLarge }
        attachments.append(DraftAttachment(value: value))
    }
    @MainActor private func loadPhotos(_ selection: [PhotosPickerItem]) async {
        guard !selection.isEmpty else { return }
        loadingMedia = true; message = nil
        defer { loadingMedia = false; photoSelection = [] }
        for item in selection {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { throw LocalLibrary.LocalError.invalidMedia }
                try addAttachment(CaptureMedia.image(data, name: "Photo \(attachments.count + 1).jpg"))
            } catch { message = error.localizedDescription; break }
        }
    }
    private var captureSource: CaptureSource {
        let host = URL(string: cleanedLink)?.host?.lowercased() ?? ""
        if host == "instagram.com" || host.hasSuffix(".instagram.com") { return .instagram }
        if host == "pinterest.com" || host.hasSuffix(".pinterest.com") || host == "pin.it" { return .pinterest }
        return .web
    }
}
