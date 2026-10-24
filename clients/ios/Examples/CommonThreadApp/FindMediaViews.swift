import SwiftUI
import CommonThreadKit
import QuickLook

/// Private server images use the authenticated client, never a token-bearing URL.
struct FindImage: View {
    let item: SavedItem
    var connection: SharedEnvironment?
    @State private var image: UIImage?
    @State private var imageIdentity: String?
    @State private var errorMessage: String?
    @State private var errorIdentity: String?
    @State private var attempt = 0
    @State private var requestID = UUID()
    private var identity: String {
        "\(connection?.baseURL.absoluteString ?? "local")|\(connection?.accountId ?? "local")|\(item.id)|\(item.revision)"
    }
    var body: some View {
        Group {
            if let image, imageIdentity == identity {
                Image(uiImage: image).resizable().scaledToFit().accessibilityLabel("Saved photo")
            } else {
                Rectangle().fill(NativeTheme.surface).aspectRatio(1, contentMode: .fit)
                    .overlay {
                        VStack(spacing: 10) {
                            Image(systemName: "photo").font(.title2).foregroundStyle(.secondary).accessibilityHidden(true)
                            if let errorMessage, errorIdentity == identity {
                                Text(errorMessage).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                                Button("Retry photo") { attempt += 1 }.font(.caption.bold()).buttonStyle(.bordered)
                            } else { ProgressView().accessibilityLabel("Loading saved photo") }
                        }.padding(12)
                    }
            }
        }
        .task(id: "\(identity)|\(attempt)") { await load() }
    }
    @MainActor private func load() async {
        guard !Task.isCancelled else { return }
        let currentID = UUID(); requestID = currentID
        let requestedIdentity = identity
        image = nil; imageIdentity = nil; errorMessage = nil; errorIdentity = nil
        do {
            let data: Data
            if let connection {
                let client = try connection.client()
                try await connection.verify(client)
                data = try await client.savedImage(item.id)
            } else {
                guard let attachment = try await LocalLibrary.shared.metadata()[item.id]?.attachments.first(where: \.isImage) else {
                    throw ImageLoadError.unavailable
                }
                data = try await LocalLibrary.shared.attachmentData(attachment)
            }
            try Task.checkCancellation()
            guard requestID == currentID, identity == requestedIdentity else { return }
            guard let decoded = UIImage(data: data) else { throw ImageLoadError.unavailable }
            image = decoded; imageIdentity = requestedIdentity
        } catch {
            guard !Task.isCancelled, requestID == currentID, identity == requestedIdentity else { return }
            image = nil; imageIdentity = nil
            errorMessage = "Photo unavailable right now."; errorIdentity = requestedIdentity
        }
    }
    private enum ImageLoadError: Error { case unavailable }
}
struct AttachmentGallery: View {
    let attachments: [LocalAttachment]
    @State private var previewURL: URL?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Attachments", systemImage: "paperclip").font(.headline.bold())
            ForEach(attachments) { attachment in
                Button {
                    Task { previewURL = await LocalLibrary.shared.attachmentURL(attachment) }
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: attachment.isImage ? "photo" : "doc").font(.title3).frame(width: 32)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(attachment.filename).font(.subheadline.weight(.semibold)).lineLimit(2)
                            Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.byteCount), countStyle: .file))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(); Image(systemName: "chevron.right").font(.caption.bold())
                    }.padding(14).background(NativeTheme.surface, in: RoundedRectangle(cornerRadius: 18))
                }.buttonStyle(.plain)
            }
        }
        .sheet(isPresented: Binding(get: { previewURL != nil }, set: { if !$0 { previewURL = nil } })) {
            if let previewURL { FilePreview(url: previewURL).presentationDragIndicator(.visible) }
        }
    }
}
struct FilePreview: UIViewControllerRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController(); controller.dataSource = context.coordinator; return controller
    }
    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {}
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(_ url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}

struct EditFindSheet: View {
    let item: SavedItem
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var note: String
    @State private var text: String
    @State private var saving = false
    @State private var errorMessage: String?
    init(item: SavedItem, onSaved: @escaping () -> Void) {
        self.item = item; self.onSaved = onSaved
        _title = State(initialValue: item.title); _note = State(initialValue: item.note); _text = State(initialValue: item.selectedText)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Your find") { TextField("Title", text: $title) }
                Section {
                    TextField("Why did it catch your eye?", text: $note, axis: .vertical).lineLimit(4...10)
                } header: { Text("The feeling behind it") }
                Section("Saved text") { TextField("Add a little more context", text: $text, axis: .vertical).lineLimit(3...10) }
                if let message = errorMessage { Section { Text(message).foregroundStyle(.red) } }
            }
            .navigationTitle("Edit find").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saving = true
                        Task {
                            do {
                                try await LocalLibrary.shared.update(item.id, title: title, note: note, text: text)
                                FindsHaptics.success(); onSaved(); dismiss()
                            } catch { errorMessage = error.localizedDescription; saving = false }
                        }
                    }.bold().disabled(saving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || title.count > 300 || note.count > max(2000, item.note.count) || text.count > max(12000, item.selectedText.count))
                }
            }
        }.interactiveDismissDisabled(saving)
    }
}
