import UIKit
import SwiftUI
import UniformTypeIdentifiers
import ImageIO

final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: ShareCaptureView(items: extensionContext?.inputItems as? [NSExtensionItem] ?? []) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        }.preferredColorScheme(SharedAppearance.colorScheme))
        addChild(host)
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor), host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor), host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        host.didMove(toParent: self)
    }
}

struct ShareCaptureView: View {
    let items: [NSExtensionItem]
    let close: () -> Void
    @State private var draft = LocalShareDraft(title: "", url: nil, text: "", note: "", attachments: [])
    @State private var loading = true
    @State private var saving = false
    @State private var saved = false
    @State private var message: String?
    @State private var importWarnings: [String] = []
    @State private var acceptedPartial = false
    @State private var titleWasEdited = false
    @State private var sourceTitle = ""
    @State private var selectedIntents: [String] = []
    @State private var refinement: IntentRefinementContext?
    @State private var completed = false
    @State private var intelligence: CaptureIntelligenceResult?
    @State private var intelligenceSourceContext = ""
    @State private var intelligenceLoading = false
    @State private var intelligenceFailed = false
    @State private var intelligenceRequestID = UUID()
    @State private var intelligenceRetryID = UUID()
    @State private var hasRequestedIntelligence = false
    @FocusState private var noteFocused: Bool

    private var hasContent: Bool {
        !(draft.url ?? "").isEmpty || !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draft.attachments.isEmpty
    }
    private var canSave: Bool {
        !loading && !saving && hasContent && LocalShareInbox.validationIssue(draft) == nil
            && (importWarnings.isEmpty || acceptedPartial)
    }
    // Editing a note must not trigger another request or replace the user's words.
    private var intelligenceContext: String {
        ([titleWasEdited ? draft.title : sourceTitle, draft.url ?? "", draft.text, String(loading), String(saved), intelligenceRetryID.uuidString]
            + draft.attachments.map { $0.id.uuidString }).joined(separator: "\u{1F}")
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if saved {
                        VStack(spacing: 16) {
                            Image(systemName: "checkmark.circle.fill").font(.system(size: 64)).foregroundStyle(.green)
                            Text("Saved!").font(.system(.largeTitle, weight: .bold))
                            Text("Returning to where you left off…")
                                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            if !draft.title.isEmpty {
                                Text(draft.title).font(.headline).lineLimit(3).multilineTextAlignment(.center)
                                    .padding(16).frame(maxWidth: .infinity)
                                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
                            }
                        }.frame(maxWidth: .infinity).padding(.vertical, 50)
                    } else {
                        HStack(spacing: 12) {
                            Image(systemName: "bookmark.fill").font(.system(size: 27, weight: .bold))
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Keep a good find.").font(.system(.title2, weight: .bold))
                                Text("Saved on this iPhone").font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        if loading { ProgressView("Getting your find…").frame(maxWidth: .infinity).padding() }
                        if !draft.attachments.isEmpty { attachmentPreviews }
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Name your find").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                Spacer()
                                Image(systemName: "pencil").font(.caption).foregroundStyle(.secondary)
                            }
                            TextField("A name for your find", text: Binding(get: { draft.title }, set: { draft.title = $0; titleWasEdited = true }))
                                .font(.system(.title3, weight: .bold))
                                .accessibilityIdentifier("shareTitle")
                            if draft.url != nil {
                                TextField("Link", text: Binding(get: { draft.url ?? "" }, set: { draft.url = $0.isEmpty ? nil : $0 }))
                                    .font(.subheadline).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                            }
                            if !draft.text.isEmpty {
                                TextField("Captured text", text: $draft.text, axis: .vertical).font(.subheadline).lineLimit(3...8)
                            }
                        }.padding(18).background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
                        VStack(alignment: .leading, spacing: 12) {
                            Text("What caught your eye?").font(.system(.title3, weight: .bold))
                            TextField("The shape, the feeling, something you need…", text: $draft.note, axis: .vertical)
                                .lineLimit(2...6).focused($noteFocused).accessibilityIdentifier("shareNote")
                            predictivePrompts
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "mic").foregroundStyle(.secondary)
                                Text("Type a note or use your keyboard’s microphone.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(18).background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
                        if !importWarnings.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("Some content needs attention", systemImage: "exclamationmark.triangle").font(.headline)
                                ForEach(Array(importWarnings.enumerated()), id: \.offset) { _, warning in Text(warning).font(.caption) }
                                if hasContent { Toggle("Save only the available content", isOn: $acceptedPartial).font(.subheadline) }
                            }.padding(16).background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
                        }
                        if !loading && !hasContent {
                            ContentUnavailableView("Nothing to save yet", systemImage: "square.and.arrow.up", description: Text("Share a web link, text, a photo, or a file. Up to 10 attachments, 4 MB each and 12 MB total."))
                        }
                    }
                    if let issue = LocalShareInbox.validationIssue(draft) { Text(issue).font(.footnote).foregroundStyle(.red) }
                    if let message { Text(message).font(.footnote).foregroundStyle(.red).accessibilityIdentifier("shareStatus") }
                }.padding(24).disabled(saving)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Mynah Finds").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(saved ? "Done" : "Cancel", action: completeShare).disabled(saving) } }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 12) {
                    Button { if saved { completeShare() } else { Task { await save() } } } label: {
                        HStack(spacing: 8) {
                            if saving { ProgressView().tint(.primary) }
                            else if saved { Image(systemName: "checkmark") }
                            Text(saved ? "Done" : saving ? "Saving…" : "Save find")
                                .font(.system(.headline, weight: .bold))
                        }.frame(maxWidth: .infinity).frame(height: 54)
                            .foregroundStyle(saved || canSave ? Color.black : Color.secondary)
                            .background(saved || canSave ? Color.white : Color(.tertiarySystemFill), in: Capsule())
                            .overlay(Capsule().strokeBorder(.black.opacity(0.12), lineWidth: 1))
                    }
                    .disabled(!saved && !canSave)
                    .accessibilityIdentifier(saved ? "shareDone" : "shareSave")
                }
                .padding(.horizontal, 24).padding(.vertical, 12).background(.bar)
            }
            .sheet(item: $refinement) { context in
                IntentRefinementSheet(context: context) { choice in
                    guard selectedIntents.count < 8 || selectedIntents.contains(choice) else { return false }
                    if !selectedIntents.contains(choice) { selectedIntents.append(choice) }
                    return true
                }
            }
            .task { await loadItems() }
            .task(id: intelligenceContext) { await loadIntelligence() }
            .task(id: saved) {
                guard saved else { return }
                do { try await Task.sleep(for: .milliseconds(850)); completeShare() }
                catch is CancellationError {} catch {}
            }
        }.tint(.primary)
    }

    @ViewBuilder private var predictivePrompts: some View {
        if CaptureIntelligence.isConfigured {
            VStack(alignment: .leading, spacing: 12) {
                if loading || intelligenceLoading || (hasContent && !intelligenceFailed && intelligenceSourceContext != intelligenceContext) {
                    suggestionPlaceholder
                } else if let intelligence, intelligenceSourceContext == intelligenceContext {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(intelligence.prompts.filter { !selectedIntents.contains($0.text) }.prefix(3).enumerated()), id: \.element.id) { index, prompt in
                            intentionButton(prompt.text, index: index)
                                .accessibilityIdentifier("sharePredictivePrompt_\(prompt.id)")
                        }
                    }.frame(minHeight: selectedIntents.isEmpty && !intelligence.prompts.isEmpty ? 276 : nil, alignment: .top)
                    if intelligence.prompts.isEmpty {
                        Text("Tell us what you like in your own words.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                } else if intelligenceFailed {
                    Text("Suggestions couldn’t load yet. You can still save your find.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Button("Try suggestions again") { intelligenceRetryID = UUID() }
                        .font(.subheadline.weight(.semibold))
                }
                SelectedIntentChips(values: selectedIntents, onRefine: { openRefinement($0) },
                    onRemove: { value in selectedIntents.removeAll { $0 == value } })
                Text("Your shared content is sent to OpenAI for these suggestions.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var suggestionPlaceholder: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(0..<3) { index in
                HStack(spacing: 13) {
                    RoundedRectangle(cornerRadius: 14).fill(Color(.tertiarySystemFill)).frame(width: 44, height: 44)
                        .overlay { if index == 0 { ProgressView().controlSize(.small) } }
                    VStack(alignment: .leading, spacing: 9) {
                        if index == 0 {
                            Text(loading ? "Reading your shared content…" : "Finding details you might like…")
                                .font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Capsule().fill(Color(.tertiarySystemFill)).frame(height: 8)
                            Capsule().fill(Color(.tertiarySystemFill)).frame(width: index == 1 ? 100 : 135, height: 8)
                        }
                    }
                    Image(systemName: "plus.circle").foregroundStyle(Color(.tertiaryLabel))
                }.padding(14).frame(minHeight: 84)
                    .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
            }.accessibilityHidden(true)
        }.accessibilityElement(children: .ignore)
            .accessibilityLabel(loading ? "Reading your shared content" : "Finding details you might like. You can save while suggestions load.")
            .accessibilityIdentifier("shareIntelligenceLoading")
    }

    private func intentionButton(_ text: String, index: Int) -> some View {
        let selected = selectedIntents.contains(text)
        let color: Color = [.blue, .purple, .orange][index % 3]
        let symbol = ["sparkles", "heart.fill", "slider.horizontal.3"][index % 3]
        return Button { toggleIntention(text) } label: {
            HStack(spacing: 13) {
                Image(systemName: symbol).font(.title3.weight(.semibold)).foregroundStyle(color)
                    .frame(width: 44, height: 44).background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 14))
                Text(text).font(.body.weight(.semibold)).foregroundStyle(.primary).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: selected ? "checkmark.circle.fill" : "plus.circle")
                    .font(.title3.weight(.semibold)).foregroundStyle(selected ? color : .secondary)
            }.padding(14).frame(minHeight: 84).background(color.opacity(selected ? 0.11 : 0.07), in: RoundedRectangle(cornerRadius: 20))
                .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(color.opacity(selected ? 0.7 : 0.13), lineWidth: 1) }
        }.buttonStyle(.plain).disabled(saving)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
    private func toggleIntention(_ text: String) {
        if !selectedIntents.contains(text) {
            guard selectedIntents.count < 8 else { message = "You can keep up to eight details. Hold one to remove it."; return }
            selectedIntents.append(text)
        }
        UISelectionFeedbackGenerator().selectionChanged()
        openRefinement(text)
    }
    private func openRefinement(_ text: String) {
        guard intelligenceSourceContext == intelligenceContext, let intelligence,
              intelligence.productName != nil, CaptureIntelligence.isConfigured else { return }
        noteFocused = false
        refinement = IntentRefinementContext(analysis: intelligence, selectedIntent: text, existingIntents: selectedIntents)
    }
    private func completeShare() {
        guard !completed else { return }
        completed = true
        close()
    }

    private var attachmentPreviews: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(draft.attachments) { attachment in
                    VStack(alignment: .leading, spacing: 8) {
                        Group {
                            if UTType(attachment.typeIdentifier)?.conforms(to: .image) == true,
                               let image = UIImage(data: attachment.data) {
                                Image(uiImage: image).resizable().scaledToFill()
                            } else {
                                Image(systemName: UTType(attachment.typeIdentifier)?.conforms(to: .movie) == true ? "video.fill" : "doc.fill")
                                    .font(.system(size: 35)).frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .background(Color(.tertiarySystemFill))
                            }
                        }.frame(width: 276, height: 270).clipped()
                            .overlay(alignment: .bottomLeading) {
                                if UTType(attachment.typeIdentifier)?.conforms(to: .image) == true,
                                   intelligenceSourceContext == intelligenceContext, let prompt = intelligence?.prompts.first {
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
                                    }.buttonStyle(.plain).padding(12).disabled(saving)
                                        .accessibilityHint("Selects: " + prompt.text)
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 24))
                        HStack {
                            Text(attachment.filename).font(.caption).lineLimit(1)
                            Spacer()
                            Button("Remove", role: .destructive) { draft.attachments.removeAll { $0.id == attachment.id } }
                                .font(.caption)
                        }.frame(width: 276)
                    }
                }
            }
        }
    }

    @MainActor private func loadIntelligence() async {
        let requestID = UUID()
        let context = intelligenceContext
        intelligenceRequestID = requestID
        intelligence = nil
        intelligenceSourceContext = ""
        intelligenceFailed = false
        intelligenceLoading = false
        guard !loading, !saved, hasContent, CaptureIntelligence.isConfigured else { return }
        intelligenceLoading = true
        defer {
            if intelligenceRequestID == requestID { intelligenceLoading = false }
        }
        do {
            // The first imported source starts immediately. Only subsequent edits
            // debounce, so typing cannot launch a request for every keystroke.
            let needsDebounce = hasRequestedIntelligence
            hasRequestedIntelligence = true
            if needsDebounce { try await Task.sleep(for: .milliseconds(250)) }
            try Task.checkCancellation()
            let snapshot = draft
            let image = snapshot.attachments.first { UTType($0.typeIdentifier)?.conforms(to: .image) == true }?.data
            let result = try await CaptureIntelligence.analyze(
                url: snapshot.url, title: titleWasEdited ? snapshot.title : sourceTitle, text: snapshot.text, note: snapshot.note,
                imageData: image, preferCapturedContent: true
            )
            guard !Task.isCancelled, intelligenceRequestID == requestID,
                  intelligenceContext == context, !saved else { return }
            intelligence = result
            intelligenceSourceContext = context
            if !saving, !titleWasEdited, let name = result.productName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                draft.title = String(name.prefix(300))
            }
        } catch is CancellationError {
            // A changed product cancels old suggestions, without affecting local saving.
        } catch {
            guard !Task.isCancelled, intelligenceRequestID == requestID,
                  intelligenceContext == context, !saved else { return }
            intelligenceFailed = true
        }
    }
    @MainActor private func loadItems() async {
        guard loading else { return }
        defer { loading = false }
        for item in items {
            if draft.title.isEmpty { draft.title = item.attributedTitle?.string ?? "" }
            if draft.text.isEmpty { draft.text = item.attributedContentText?.string ?? "" }
            for provider in item.attachments ?? [] {
                do {
                    if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                        let attachment = try await readImage(provider)
                        try append(attachment)
                    } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                        let object = try await load(provider, type: UTType.url.identifier)
                        let value = (object as? URL) ?? (object as? String).flatMap(URL.init(string:))
                        if let value, value.isFileURL {
                            try append(try readFile(value, type: UTType(filenameExtension: value.pathExtension)?.identifier ?? UTType.data.identifier, image: false))
                        } else if let value, ["http", "https"].contains(value.scheme?.lowercased() ?? "") {
                            if draft.url == nil { draft.url = value.absoluteString }
                            else if draft.url != value.absoluteString { draft.text += "\n" + value.absoluteString }
                        } else { throw ShareReadError.unsupported }
                    } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                        let value = try await load(provider, type: UTType.plainText.identifier)
                        if let text = value as? String, !draft.text.contains(text) { draft.text += (draft.text.isEmpty ? "" : "\n") + text }
                    } else if let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .data) == true }) {
                        try append(try await readAttachment(provider, type: type, image: false))
                    } else { throw ShareReadError.unsupported }
                } catch { importWarnings.append("\(provider.suggestedName ?? "Shared item"): \(error.localizedDescription)") }
            }
        }
        if draft.url == nil, let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            draft.url = detector.matches(in: draft.text, range: NSRange(draft.text.startIndex..., in: draft.text))
                .compactMap(\.url).first { ["https", "http"].contains($0.scheme ?? "") }?.absoluteString
        }
        sourceTitle = draft.title
        if draft.title.isEmpty {
            draft.title = draft.attachments.isEmpty ? "A new find" : "A photo worth saving"
        }
    }
    private func append(_ attachment: LocalShareAttachment) throws {
        guard draft.attachments.count < LocalShareInbox.maxAttachments,
              draft.attachments.reduce(attachment.data.count, { $0 + $1.data.count }) <= LocalShareInbox.maxTotalBytes else { throw LocalShareInboxError.tooLarge }
        draft.attachments.append(attachment)
    }
    private func load(_ provider: NSItemProvider, type: String) async throws -> NSSecureCoding? {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type, options: nil) { value, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: value) }
            }
        }
    }
    private func readImage(_ provider: NSItemProvider) async throws -> LocalShareAttachment {
        do { return try await readAttachment(provider, type: UTType.image.identifier, image: true) }
        catch {
            // Some apps provide a UIImage or bytes rather than a temporary file.
            let object = try await load(provider, type: UTType.image.identifier)
            if let url = object as? URL { return try readFile(url, type: UTType.image.identifier, image: true) }
            let bytes: Data?
            if let data = object as? Data { bytes = data }
            else if let image = object as? UIImage { bytes = image.jpegData(compressionQuality: 0.9) }
            else { bytes = nil }
            guard let bytes, let source = CGImageSourceCreateWithData(bytes as CFData, nil) else { throw ShareReadError.unreadable }
            return try compressedImage(source, filename: (provider.suggestedName ?? "Photo") + ".jpg")
        }
    }
    private func compressedImage(_ source: CGImageSource, filename: String) throws -> LocalShareAttachment {
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0,
                [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1600,
                 kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              let data = UIImage(cgImage: thumbnail).jpegData(compressionQuality: 0.78),
              data.count <= LocalShareInbox.maxAttachmentBytes else { throw ShareReadError.unreadable }
        return LocalShareAttachment(filename: filename, typeIdentifier: UTType.jpeg.identifier, data: data)
    }
    private func readAttachment(_ provider: NSItemProvider, type: String, image: Bool) async throws -> LocalShareAttachment {
        let suggestedName = provider.suggestedName
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                do {
                    guard let url else { throw error ?? ShareReadError.unreadable }
                    // Provider files can disappear as soon as this callback returns.
                    var attachment = try readFile(url, type: type, image: image)
                    if let name = suggestedName, !name.isEmpty {
                        attachment.filename = image ? URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent + ".jpg" : name
                    }
                    continuation.resume(returning: attachment)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    private func readFile(_ url: URL, type: String, image: Bool) throws -> LocalShareAttachment {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        if image {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw ShareReadError.unreadable }
            return try compressedImage(source, filename: url.deletingPathExtension().lastPathComponent + ".jpg")
        }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= LocalShareInbox.maxAttachmentBytes else { throw LocalShareInboxError.tooLarge }
        let data = try Data(contentsOf: url)
        guard data.count <= LocalShareInbox.maxAttachmentBytes else { throw LocalShareInboxError.tooLarge }
        return LocalShareAttachment(filename: url.lastPathComponent, typeIdentifier: UTType(filenameExtension: url.pathExtension)?.identifier ?? type, data: data)
    }
    @MainActor private func save() async {
        noteFocused = false
        saving = true
        message = nil
        defer { saving = false }
        if draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { draft.title = "Untitled find" }
        draft.intents = selectedIntents.isEmpty ? nil : selectedIntents
        draft.analysis = intelligenceSourceContext == intelligenceContext ? intelligence : nil
        draft.userEditedTitle = titleWasEdited
        let snapshot = draft
        do {
            try await Task.detached(priority: .userInitiated) { try LocalShareInbox.save(snapshot) }.value
            saved = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch { message = error.localizedDescription }
    }
}
private enum ShareReadError: Error, LocalizedError {
    case unsupported, unreadable
    var errorDescription: String? {
        switch self {
        case .unsupported: return "This format couldn't be imported. Share a link, photo, text, or a file instead."
        case .unreadable: return "This content couldn't be read. Try sharing the original file or a screenshot."
        }
    }
}
