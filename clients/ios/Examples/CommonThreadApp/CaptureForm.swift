import SwiftUI
import CommonThreadKit

/// The same immutable request and key survive retries through the shared outbox.
struct CaptureForm: View {
    let connection: SharedEnvironment?
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var title = ""
    @State private var note = ""
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
        return text.isEmpty ? (URL(string: cleanedLink)?.host ?? "Saved link") : text
    }
    private var valid: Bool {
        guard let url = URL(string: cleanedLink), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, host.contains("."), url.user == nil, url.password == nil else { return false }
        return cleanedLink.count <= maxURL && resolvedTitle.count <= maxTitle && note.count <= maxNote
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
    }

    private var editor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 25) {
                HStack(spacing: 14) {
                    Image(systemName: "link").font(.title2.bold()).foregroundStyle(.blue)
                        .frame(width: 58, height: 58).background(.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 18))
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Keep what caught your eye.").font(.title3.bold())
                        Text("A link, and a little context.").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 13) {
                    Text("The original").font(.headline.bold())
                    TextField("Paste a public link", text: $link)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($focused, equals: .link).accessibilityIdentifier("captureURL")
                    Divider()
                    TextField("Give it a title (optional)", text: $title)
                        .focused($focused, equals: .title).accessibilityIdentifier("captureTitle")
                }.padding(20).background(NativeTheme.surface, in: RoundedRectangle(cornerRadius: 24)).disabled(frozen)

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
                Text("Your note stays with the original link.")
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
                 : "\(resolvedTitle)\n\(connection == nil ? "Saved on this iPhone." : "Ready whenever you want to come back to it.")")
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
            guard let connection else {
                receipt = try await LocalLibrary.shared.capture(CaptureRequest(url: cleanedLink, title: resolvedTitle, source: captureSource, note: note, client: .iosApp))
                onSave()
                return
            }
            let draft = pending ?? PendingCapture(
                request: CaptureRequest(url: cleanedLink, title: resolvedTitle, source: captureSource, note: note, client: .iosApp),
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
    private var captureSource: CaptureSource {
        let host = URL(string: cleanedLink)?.host?.lowercased() ?? ""
        if host == "instagram.com" || host.hasSuffix(".instagram.com") { return .instagram }
        if host == "pinterest.com" || host.hasSuffix(".pinterest.com") || host == "pin.it" { return .pinterest }
        return .web
    }
}
