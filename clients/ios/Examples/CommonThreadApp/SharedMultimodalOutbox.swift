import Foundation
import CommonThreadKit

/// Keeps the exact payload and mutation identities across app closure and network failures.
/// Credentials never enter this document. Each entry belongs to one origin and account.
struct PendingSharedMultimodal: Codable, Identifiable, Sendable {
    let id: String
    let accountID: String
    let origin: URL
    let localID: String
    let request: MultimodalCaptureRequest
    let attachments: [LocalCaptureAttachment]
    let reviewedTranscript: String?
    var captureID: String?
    var revision: Int?
    var uploaded = 0
    var corrected = false
    var analyzed = false
}

actor SharedMultimodalOutbox {
    static let shared = SharedMultimodalOutbox(file: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MymahFinds/shared-multimodal-outbox.json"))
    private let file: URL
    private var active = Set<String>()
    init(file: URL) { self.file = file }
    private func read() throws -> [PendingSharedMultimodal] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try JSONDecoder().decode([PendingSharedMultimodal].self, from: Data(contentsOf: file))
    }
    private func write(_ entries: [PendingSharedMultimodal]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(entries)
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    func pending(accountID: String, origin: URL) throws -> [PendingSharedMultimodal] {
        try read().filter { $0.accountID == accountID && $0.origin == origin }
    }
    func enqueue(_ entry: PendingSharedMultimodal) throws {
        var entries = try read()
        guard !entries.contains(where: { $0.id == entry.id }) else { return }
        guard entries.count < 100, entries.flatMap(\.attachments).reduce(0, { $0 + $1.data.count }) + entry.attachments.reduce(0, { $0 + $1.data.count }) <= 128 * 1024 * 1024 else { throw Failure.full }
        entries.append(entry); try write(entries)
    }
    private func checkpoint(_ entry: PendingSharedMultimodal) throws {
        var entries = try read()
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { throw Failure.missing }
        entries[index] = entry; try write(entries)
    }
    private func remove(_ id: String) throws { try write(read().filter { $0.id != id }) }

    func send(_ id: String, client: CommonThreadClient, accountID: String, origin: URL) async throws -> CaptureReceipt {
        guard !active.contains(id) else { throw Failure.busy }
        guard var entry = try read().first(where: { $0.id == id }), entry.accountID == accountID, entry.origin == origin else { throw Failure.missing }
        active.insert(id); defer { active.remove(id) }
        guard try await client.account().userId == accountID else { throw Failure.account }
        func key(_ operation: String) throws -> MutationKey { try MutationKey(id + "-" + operation) }
        if entry.captureID == nil {
            let capture = try await client.createMultimodalCapture(entry.request, key: key("create"))
            entry.captureID = capture.id; entry.revision = capture.revision; try checkpoint(entry)
        }
        let captureID = entry.captureID!
        while entry.uploaded < entry.attachments.count {
            let asset = entry.attachments[entry.uploaded]
            let ext = (asset.filename as NSString).pathExtension.lowercased()
            let media = asset.typeIdentifier == "public.jpeg" ? "image/jpeg" : ext == "wav" ? "audio/wav" : "audio/mp4"
            let capture = try await client.uploadMultimodalAsset(to: captureID,
                request: .init(revision: entry.revision!, mediaType: media, data: asset.data), key: key("asset-\(entry.uploaded)"))
            entry.revision = capture.revision; entry.uploaded += 1; try checkpoint(entry)
        }
        if !entry.corrected, let text = entry.reviewedTranscript {
            let capture = try await client.multimodalCapture(captureID)
            if let audio = capture.assets.first(where: { $0.kind == "audio" }) {
                let changed = try await client.updateMultimodalTranscript(audio.id, in: captureID,
                    edit: .init(revision: entry.revision!, transcript: text), key: key("transcript"))
                entry.revision = changed.revision
            }
            entry.corrected = true; try checkpoint(entry)
        }
        if !entry.analyzed {
            let capture = try await client.analyzeMultimodalCapture(captureID, revision: entry.revision!, key: key("analyze"))
            entry.revision = capture.revision; entry.analyzed = true; try checkpoint(entry)
        }
        _ = try await client.waitForMultimodalCapture(captureID, expectedRevision: entry.revision, timeout: 110)
        let receipt = try await client.publishMultimodalCapture(captureID, revision: entry.revision!, key: key("publish"))
        try remove(id)
        return receipt
    }

    func discard(_ id: String, client: CommonThreadClient, accountID: String, origin: URL) async throws {
        guard !active.contains(id) else { throw Failure.busy }
        guard let entry = try read().first(where: { $0.id == id }), entry.accountID == accountID, entry.origin == origin else { throw Failure.missing }
        if let captureID = entry.captureID {
            do {
                let capture = try await client.multimodalCapture(captureID)
                // Publication may have succeeded before its response was interrupted.
                // Cancel only the pending queue entry in that case, never a shared save.
                if capture.publishedSaveId == nil {
                    _ = try await client.deleteMultimodalCapture(captureID, key: MutationKey(id + "-discard"))
                }
            } catch let error as APIError where error.status == 410 || error.status == 404 { }
        }
        try remove(id)
    }

    /// A failed analysis is retried only after a deliberate user action, with its own retained key.
    func retryAnalysis(_ id: String, client: CommonThreadClient, accountID: String, origin: URL) async throws {
        guard var entry = try read().first(where: { $0.id == id }), entry.accountID == accountID, entry.origin == origin,
              let captureID = entry.captureID else { return }
        let capture = try await client.multimodalCapture(captureID)
        guard capture.status == "enrichment_failed" else { return }
        // Revision is unchanged by processing. A distinct action key records this deliberate retry.
        let retried = try await client.analyzeMultimodalCapture(captureID, revision: capture.revision,
            key: MutationKey(id + "-retry-" + String(Int(capture.updatedAt * 1000))))
        entry.analyzed = true; entry.revision = retried.revision; try checkpoint(entry)
    }

    enum Failure: LocalizedError {
        case busy, missing, account, full
        var errorDescription: String? {
            switch self {
            case .busy: "This find is already syncing."
            case .missing: "This pending find belongs to another connection or has already synced."
            case .account: "Sign in to the original account to sync this find."
            case .full: "Sync your pending finds before adding more."
            }
        }
    }
}
