import UIKit
import SwiftUI
import UniformTypeIdentifiers
import ImageIO

final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: ShareCaptureView(items: extensionContext?.inputItems as? [NSExtensionItem] ?? []) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        })
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
    @FocusState private var noteFocused: Bool

    private var hasContent: Bool {
        !(draft.url ?? "").isEmpty || !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draft.attachments.isEmpty
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if saved {
                        VStack(spacing: 16) {
                            Image(systemName: "checkmark.circle.fill").font(.system(size: 64)).foregroundStyle(.green)
                            Text("Saved!").font(.system(.largeTitle, weight: .bold))
                            Text("Your find is safe on this iPhone. Open Mynah Finds to see it in your library.")
                                .font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }.frame(maxWidth: .infinity).padding(.vertical, 50)
                    } else {
                        HStack(spacing: 12) {
                            Image(systemName: "bookmark.fill").font(.system(size: 27, weight: .bold))
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Keep a good find.").font(.system(.title2, weight: .bold))
                                Text("Saved privately on this iPhone").font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        if loading { ProgressView("Getting your find…").frame(maxWidth: .infinity).padding() }
                        if !draft.attachments.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 12) {
                                    ForEach(draft.attachments) { attachment in
                                        VStack(spacing: 8) {
                                            if UTType(attachment.typeIdentifier)?.conforms(to: .image) == true,
                                               let image = UIImage(data: attachment.data) {
                                                Image(uiImage: image).resizable().scaledToFill().frame(width: 128, height: 142).clipped()
                                                    .clipShape(RoundedRectangle(cornerRadius: 16))
                                            } else {
                                                Image(systemName: UTType(attachment.typeIdentifier)?.conforms(to: .movie) == true ? "video.fill" : "doc.fill")
                                                    .font(.system(size: 35)).frame(width: 128, height: 142)
                                                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 16))
                                            }
                                            Text(attachment.filename).font(.caption).lineLimit(1).frame(width: 128)
                                            Button("Remove", role: .destructive) { draft.attachments.removeAll { $0.id == attachment.id } }
                                                .font(.caption)
                                        }
                                    }
                                }
                            }
                        }
                        VStack(alignment: .leading, spacing: 12) {
                            TextField("Give it a name", text: $draft.title).font(.system(.title3, weight: .semibold))
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
                            Text("What caught your eye?").font(.system(.headline, weight: .bold))
                            TextField("The shape, a gift idea, or a space it would fit…", text: $draft.note, axis: .vertical)
                                .lineLimit(4...8).focused($noteFocused).accessibilityIdentifier("shareNote")
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "mic").foregroundStyle(.secondary)
                                Text("Tap the note, then the keyboard’s microphone to dictate when available. You can also add a voice note in Mynah Finds.")
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
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(saved ? "Done" : "Cancel", action: close).disabled(saving) } }
            .safeAreaInset(edge: .bottom) {
                Button { if saved { close() } else { Task { await save() } } } label: {
                    HStack(spacing: 8) {
                        if saving { ProgressView().tint(Color(.systemBackground)) }
                        Text(saved ? "Done" : saving ? "Saving…" : "Save find").font(.system(.headline, weight: .bold))
                    }.frame(maxWidth: .infinity).frame(height: 54)
                        .foregroundStyle(Color(.systemBackground)).background(Color.primary, in: Capsule())
                }
                .disabled(!saved && (loading || saving || !hasContent || LocalShareInbox.validationIssue(draft) != nil || (!importWarnings.isEmpty && !acceptedPartial)))
                .accessibilityIdentifier("shareSave")
                .padding(.horizontal, 24).padding(.vertical, 12).background(.bar)
            }
            .task { await loadItems() }
        }.tint(.primary)
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
        if draft.title.isEmpty {
            draft.title = draft.url.flatMap { URL(string: $0)?.host } ?? draft.attachments.first?.filename ?? String(draft.text.prefix(80))
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
