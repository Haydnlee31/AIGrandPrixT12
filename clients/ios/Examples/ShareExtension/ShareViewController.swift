import UIKit
import SwiftUI
import UniformTypeIdentifiers
import CommonThreadKit

final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: ShareCaptureView(items: extensionContext?.inputItems as? [NSExtensionItem] ?? []) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        })
        addChild(host); view.addSubview(host.view); host.view.translatesAutoresizingMaskIntoConstraints = false
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
    @State private var url = ""
    @State private var title = ""
    @State private var selectedText = ""
    @State private var note = ""
    @State private var message = "Review the link, then tap Save."
    @State private var loading = true
    @State private var saving = false
    @State private var pending: PendingCapture?
    @State private var saved = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Save to Mymah Finds") {
                    TextField("Public link", text: $url).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Title", text: $title)
                    TextField("Selected text (optional)", text: $selectedText, axis: .vertical)
                    TextField("Add a note (optional)", text: $note, axis: .vertical)
                }.disabled(pending != nil || saving || saved)
                Text(message).font(.footnote).accessibilityIdentifier("shareStatus")
                if loading || saving { ProgressView() }
                if pending != nil && !saved && !saving {
                    Button("Discard pending save and edit", role: .destructive) {
                        Task {
                            do {
                                if let pending { try await SharedEnvironment.outbox().remove(pending) }
                                pending = nil; message = "Edit the draft and tap Save when ready."
                            } catch { message = error.localizedDescription }
                        }
                    }
                }
            }
            .navigationTitle("Save to Library")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(saved ? "Done" : "Close", action: close).disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(pending == nil ? "Save" : "Retry") { Task { await save() } }.disabled(loading || saving || saved || url.isEmpty || title.isEmpty)
                }
            }
            .task { await loadItems() }
        }
    }
    @MainActor private func loadItems() async {
        defer { loading = false }
        for item in items {
            if title.isEmpty { title = item.attributedTitle?.string ?? "" }
            for provider in item.attachments ?? [] {
                do {
                    if url.isEmpty && provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                        let object = try await load(provider, type: UTType.url.identifier)
                        if let value = object as? URL { url = value.absoluteString }
                        else if let value = object as? String { url = value }
                    } else if selectedText.isEmpty && provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                        let object = try await load(provider, type: UTType.plainText.identifier)
                        if let value = object as? String { selectedText = value }
                    }
                } catch { message = "Some shared content could not be read. You can enter a link below." }
            }
        }
        if url.isEmpty, let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let range = NSRange(selectedText.startIndex..., in: selectedText)
            url = detector.matches(in: selectedText, range: range).compactMap(\.url).first(where: { ["https", "http"].contains($0.scheme ?? "") })?.absoluteString ?? ""
        }
        if title.isEmpty { title = URL(string: url)?.host ?? "" }
        if url.isEmpty { message = "This share has no web link. Add a public URL to save it. Images and text-only saves are not supported yet." }
    }
    private func load(_ provider: NSItemProvider, type: String) async throws -> NSSecureCoding? {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type, options: nil) { value, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: value) }
            }
        }
    }
    @MainActor private func save() async {
        saving = true; defer { saving = false }
        do {
            let environment = try SharedEnvironment.read()
            let draft = pending ?? PendingCapture(request: CaptureRequest(url: url, title: title, selectedText: selectedText, note: note, client: .iosShareExtension), accountId: environment.accountId, baseURL: environment.baseURL)
            guard draft.accountId == environment.accountId, draft.baseURL == environment.baseURL else { throw SetupError.accountChanged }
            let outbox = try SharedEnvironment.outbox()
            try await outbox.enqueue(draft); pending = draft
            // Persist first: extension termination must not lose an explicitly saved capture.
            let client = try environment.client(); try await environment.verify(client)
            let receipt = try await client.capture(draft.request, key: draft.key)
            try await outbox.remove(draft); saved = true
            message = receipt.duplicate
                ? "Already in your library. The existing note and text were kept; this save hasn’t added your changes."
                : "Saved to your library. Find it in Mymah Finds whenever you need it."
        } catch {
            message = pending == nil ? error.localizedDescription : "Pending on this device. Retry, or open Mymah Finds later to sync. \(error.localizedDescription)"
        }
    }
}
