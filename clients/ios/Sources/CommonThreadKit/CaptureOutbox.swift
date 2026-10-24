import Foundation

/// Immutable capture intent. Credentials are deliberately absent. Scope drafts to the verified account and API.
public struct PendingCapture: Codable, Sendable, Identifiable {
    public let id: String
    public let key: MutationKey
    public let request: CaptureRequest
    public let accountId: String
    public let baseURL: URL
    public let createdAt: Date
    /// Local provenance, used only to prevent importing the same original twice.
    public let sourceId: String?
    public init(request: CaptureRequest, accountId: String, baseURL: URL, sourceId: String? = nil) {
        id = UUID().uuidString; key = MutationKey(); self.request = request
        self.accountId = accountId; self.baseURL = baseURL; createdAt = Date()
        self.sourceId = sourceId
    }
}

/// One immutable, atomically written file per save supports separate app/extension processes.
/// Call enqueue only after explicit Save; remove only after a successful API receipt.
public actor CaptureOutbox {
    private let directory: URL
    public init(directory: URL) { self.directory = directory }
    private func location(_ draft: PendingCapture) throws -> URL {
        guard UUID(uuidString: draft.id) != nil else { throw CocoaError(.fileWriteInvalidFileName) }
        return directory.appendingPathComponent(draft.id).appendingPathExtension("json")
    }
    public func enqueue(_ draft: PendingCapture) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = try location(draft)
        // Retrying never rewrites an existing intent under the same key.
        if FileManager.default.fileExists(atPath: url.path) { return }
        if FileManager.default.fileExists(atPath: try receiptLocation(draft).path) { return }
        let data = try JSONEncoder().encode(draft)
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: url, options: .atomic)
        #endif
    }
    public func pending(accountId: String, baseURL: URL) throws -> [PendingCapture] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { try JSONDecoder().decode(PendingCapture.self, from: Data(contentsOf: $0)) }
            .filter { $0.accountId == accountId && $0.baseURL == baseURL }
            .sorted { $0.createdAt < $1.createdAt }
    }
    public func remove(_ draft: PendingCapture) throws {
        let url = try location(draft)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        let failure = try failureLocation(draft)
        if FileManager.default.fileExists(atPath: failure.path) { try FileManager.default.removeItem(at: failure) }
    }

    private struct ImportReceipt: Codable {
        let sourceId: String
        let accountId: String
        let baseURL: URL
        let savedItemId: String
    }
    private func receiptLocation(_ draft: PendingCapture) throws -> URL {
        directory.appendingPathComponent("Receipts").appendingPathComponent(try location(draft).lastPathComponent)
    }
    private func failureLocation(_ draft: PendingCapture) throws -> URL {
        directory.appendingPathComponent("Rejected").appendingPathComponent(try location(draft).lastPathComponent)
    }
    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: url, options: .atomic)
        #endif
    }
    /// Persist the mapping BEFORE removing the request. Reopening/reimporting cannot
    /// recreate a shared find, including after it has been deleted on another client.
    public func complete(_ draft: PendingCapture, receipt: CaptureReceipt) throws {
        if let sourceId = draft.sourceId {
            try write(JSONEncoder().encode(ImportReceipt(sourceId: sourceId, accountId: draft.accountId,
                baseURL: draft.baseURL, savedItemId: receipt.id)), to: receiptLocation(draft))
        }
        try remove(draft)
    }
    public func hasImported(sourceId: String, accountId: String, baseURL: URL) throws -> Bool {
        if try pending(accountId: accountId, baseURL: baseURL).contains(where: { $0.sourceId == sourceId }) { return true }
        let receipts = directory.appendingPathComponent("Receipts")
        guard FileManager.default.fileExists(atPath: receipts.path) else { return false }
        for url in try FileManager.default.contentsOfDirectory(at: receipts, includingPropertiesForKeys: nil) where url.pathExtension == "json" {
            let receipt = try JSONDecoder().decode(ImportReceipt.self, from: Data(contentsOf: url))
            if receipt.sourceId == sourceId && receipt.accountId == accountId && receipt.baseURL == baseURL { return true }
        }
        return false
    }
    public func enqueueImport(request: CaptureRequest, sourceId: String, accountId: String, baseURL: URL) throws -> Bool {
        guard try !hasImported(sourceId: sourceId, accountId: accountId, baseURL: baseURL) else { return false }
        try enqueue(PendingCapture(request: request, accountId: accountId, baseURL: baseURL, sourceId: sourceId))
        return true
    }
    /// Only a definite permanent rejection pauses automatic replay. Network failures,
    /// expired credentials, rate limits and server failures retain their original key.
    public func recordFailure(_ error: Error, for draft: PendingCapture) throws {
        guard let api = error as? APIError, !api.retryable, (400..<500).contains(api.status),
              ![401, 403, 408, 429].contains(api.status) else { return }
        try write(Data(api.localizedDescription.utf8), to: failureLocation(draft))
    }
    public func rejection(_ draft: PendingCapture) throws -> String? {
        let url = try failureLocation(draft)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }

    public struct SyncResult: Sendable {
        public var errors: [String: String] = [:]
        public var duplicates = 0
    }
    public enum SyncError: Error, LocalizedError {
        case accountChanged
        public var errorDescription: String? { "The account changed. Reconnect before syncing these saves." }
    }
    public func sync(using client: CommonThreadClient, accountId: String, baseURL: URL, retryRejected: Bool = false) async throws -> SyncResult {
        guard try await client.account().userId == accountId else { throw SyncError.accountChanged }
        var result = SyncResult()
        for draft in try pending(accountId: accountId, baseURL: baseURL) {
            try Task.checkCancellation()
            if !retryRejected, let reason = try rejection(draft) {
                result.errors[draft.id] = reason; continue
            }
            do {
                let receipt = try await client.capture(draft.request, key: draft.key)
                try complete(draft, receipt: receipt)
                if receipt.duplicate { result.duplicates += 1 }
            } catch is CancellationError { throw CancellationError() }
            catch {
                try recordFailure(error, for: draft)
                result.errors[draft.id] = error.localizedDescription
                // Stop a disconnected batch promptly; retry on the next foreground cycle.
                if error is URLError { break }
                if let api = error as? APIError, [401, 403, 429].contains(api.status) || api.status >= 500 { break }
            }
        }
        return result
    }
}
