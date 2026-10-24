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
    @State private var link = ""
    @State private var title = ""
    @State private var note = ""
    @State private var savedText = ""
    @State private var attachments: [DraftAttachment] = []
    @State private var photoSelection: [PhotosPickerItem] = []
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
        (!cleanedLink.isEmpty || attachments.count == 1) && attachments.count <= 1 && attachments.allSatisfy { $0.value.typeIdentifier == UTType.jpeg.identifier }
    }
    @State private var recorder = VoiceNoteRecorder()
    @State private var voiceTask: Task<Void, Never>?
    @State private var startingVoice = false
    @State private var saving = false
    @State private var pending: PendingCapture?
    @State private var receipt: CaptureReceipt?
    @State private var message: String?
    @State private var canRetry = true
    @State private var maxURL = 2048
    @State private var maxTitle = 300
    @State private var maxNote = 2000
    @FocusState private var focused: Field?
    private enum Field: Hashable { case link, title, note }
    private var cleanedLink: String { link.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var resolvedTitle: String {
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return text }
        if let host = URL(string: cleanedLink)?.host { return host }
        if let attachment = attachments.first { return (attachment.value.filename as NSString).deletingPathExtension }
        return String(savedText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
    }
    private var valid: Bool {
        if !cleanedLink.isEmpty {
            guard let url = URL(string: cleanedLink), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  let host = url.host, host.contains("."), url.user == nil, url.password == nil else { return false }
        }
        return (!cleanedLink.isEmpty || !attachments.isEmpty || !savedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && !resolvedTitle.isEmpty && cleanedLink.count <= maxURL && resolvedTitle.count <= maxTitle
            && note.count <= maxNote && savedText.count <= 12000 && !loadingMedia
            && (effectiveConnection == nil || cloudCompatible)
    }
    private var frozen: Bool { pending != nil || saving || receipt != nil }

    var body: some View {
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
                    Button(receipt == nil ? "Close" : "Done") { dismiss() }.disabled(saving)
                }
            }
        }
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(saving)
        .task {
            if let connection, let limits = try? await connection.client().capabilities().capture {
                maxURL = limits.maxUrlLength; maxTitle = limits.maxTitleLength; maxNote = limits.maxNoteLength
            }
        }
        .onDisappear { stopVoice() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { stopVoice() } }
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

    private var editor: some View {
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
                        }.buttonStyle(.bordered).disabled(frozen || loadingMedia)
                        if UIImagePickerController.isSourceTypeAvailable(.camera) {
                            Button { showingCamera = true } label: { Label("Camera", systemImage: "camera") }
                                .buttonStyle(.bordered).disabled(frozen)
                        }
                        Button { showingFiles = true } label: { Label("Files", systemImage: "folder") }
                            .buttonStyle(.bordered).disabled(frozen)
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
                    TextField("Give it a title (optional)", text: $title)
                        .focused($focused, equals: .title).accessibilityIdentifier("captureTitle")
                }.padding(20).background(NativeTheme.surface, in: RoundedRectangle(cornerRadius: 24)).disabled(frozen)
                if connection != nil {
                    Toggle("Keep on this iPhone", isOn: $localDestination).disabled(frozen)
                    if !localDestination && !cloudCompatible {
                        Text("The shared library accepts one image and an optional link. Turn on ‘Keep on this iPhone’ for multiple photos, files, or text-only finds.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 13) {
                    HStack {
                        Text("Why are you saving this?").font(.headline.bold())
                        Spacer()
                        Button { toggleVoice() } label: {
                            Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill")
                                .font(.body.bold()).foregroundStyle(recorder.isRecording ? .red : .blue)
                                .frame(width: 44, height: 44)
                                .background(.blue.opacity(0.09), in: Circle())
                        }.buttonStyle(.plain).disabled(frozen)
                            .accessibilityLabel(recorder.isRecording || startingVoice ? "Stop voice note" : "Record a voice note")
                            .accessibilityIdentifier("captureMicrophone")
                    }
                    TextField("Love the shape? Perfect for your room? Add a note…", text: $note, axis: .vertical)
                        .lineLimit(4...8).focused($focused, equals: .note)
                        .disabled(frozen || recorder.isRecording || startingVoice)
                        .accessibilityIdentifier("captureNote")
                    HStack {
                        Text(recorder.isRecording ? "Listening… tap stop to edit." : startingVoice ? "Starting microphone…" : "Optional. Type it or say it.")
                        Spacer()
                        if note.count > maxNote - 200 { Text("\(note.count)/\(maxNote)").foregroundStyle(note.count > maxNote ? .red : .secondary) }
                    }.font(.caption).foregroundStyle(.secondary)
                }.padding(20).background(NativeTheme.surface, in: RoundedRectangle(cornerRadius: 24))

                if pending == nil {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 9) {
                            ForEach(["Love the look", "For my space", "Compare later"], id: \.self) { hint in
                                Button(hint) { note += note.isEmpty ? hint : " · \(hint)" }
                                    .font(.subheadline.weight(.medium)).padding(.horizontal, 16).padding(.vertical, 12)
                                    .background(NativeTheme.surface, in: Capsule()).buttonStyle(.plain)
                                    .disabled(saving || recorder.isRecording || startingVoice)
                            }
                        }
                    }
                }
                if let text = message ?? recorder.errorMessage {
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
                NativePrimaryButton(title: pending == nil ? "Save to library" : canRetry ? "Retry save" : "Reconnect or edit to continue") {
                    focused = nil; stopVoice(); Task { await save() }
                }.disabled(saving || !canRetry || (!valid && pending == nil))
                    .accessibilityIdentifier("captureSave")
                Text("Your note stays with your find. Photos and files are private.")
                    .font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }.padding(24).frame(maxWidth: 600).frame(maxWidth: .infinity)
        }.scrollDismissesKeyboard(.interactively)
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
                 : "\(resolvedTitle)\n\(effectiveConnection == nil ? "Saved on this iPhone." : "Ready whenever you want to come back to it.")")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            Spacer()
            NativePrimaryButton(title: "Done") { dismiss() }.accessibilityIdentifier("captureDone")
        }.padding(28)
    }

    private func toggleVoice() {
        if recorder.isRecording || startingVoice { stopVoice(); return }
        focused = nil; startingVoice = true
        let prefix = note.trimmingCharacters(in: .whitespacesAndNewlines)
        voiceTask = Task { @MainActor in
            defer { startingVoice = false }
            do {
                try await recorder.start { words in note = prefix.isEmpty ? words : prefix + " " + words }
            } catch is CancellationError {} catch { recorder.errorMessage = error.localizedDescription }
        }
    }
    private func stopVoice() { voiceTask?.cancel(); voiceTask = nil; startingVoice = false; recorder.stop() }

    @MainActor private func save() async {
        guard !saving else { return }
        saving = true; message = nil
        defer { saving = false }
        do {
            guard let connection = effectiveConnection else {
                receipt = try await LocalLibrary.shared.captureContent(url: cleanedLink.isEmpty ? nil : cleanedLink, title: resolvedTitle,
                    text: savedText, note: note, source: captureSource, attachments: attachments.map(\.value))
                FindsHaptics.success(); onSave()
                return
            }
            let draft = pending ?? PendingCapture(
                request: CaptureRequest(url: cleanedLink.isEmpty ? nil : cleanedLink, title: resolvedTitle, source: captureSource,
                    selectedText: savedText, note: note, client: .iosApp,
                    imageDataUrl: attachments.first.map { "data:image/jpeg;base64," + $0.value.data.base64EncodedString() }),
                accountId: connection.accountId, baseURL: connection.baseURL)
            let outbox = try SharedEnvironment.outbox()
            try await outbox.enqueue(draft)
            pending = draft // Only describe an on-device save after durable enqueue succeeds.
            let client = try connection.client()
            try await connection.verify(client)
            let result = try await client.capture(draft.request, key: draft.key)
            receipt = result
            do { try await outbox.remove(draft) }
            catch { message = "Saved online. A local queue entry will be reconciled on your next sync." }
            onSave()
        } catch {
            if let api = error as? APIError { canRetry = api.retryable }
            message = pending == nil ? error.localizedDescription
                : "Pending on this device. \(error.localizedDescription) You can close this sheet and manage it in Profile."
        }
    }
    private var attachmentPreviews: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(attachments) { attachment in
                    VStack(alignment: .leading, spacing: 8) {
                        Group {
                            if let preview = attachment.preview { Image(uiImage: preview).resizable().scaledToFill() }
                            else { Image(systemName: "doc.fill").font(.largeTitle).frame(maxWidth: .infinity, maxHeight: .infinity).background(NativeTheme.surface) }
                        }.frame(width: 120, height: 140).clipShape(RoundedRectangle(cornerRadius: 18))
                        Text(attachment.value.filename).font(.caption).lineLimit(1).frame(width: 120)
                        Button("Remove", role: .destructive) { attachments.removeAll { $0.id == attachment.id } }
                            .font(.caption).disabled(frozen)
                    }
                }
            }
        }
    }
    private func addAttachment(_ value: LocalCaptureAttachment) throws {
        guard attachments.count < 10, value.data.count <= 12 * 1024 * 1024,
              attachments.reduce(value.data.count, { $0 + $1.value.data.count }) <= 24 * 1024 * 1024 else { throw LocalLibrary.LocalError.mediaTooLarge }
        attachments.append(DraftAttachment(value: value))
        if attachments.count > 1 || value.typeIdentifier != UTType.jpeg.identifier { localDestination = true }
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
