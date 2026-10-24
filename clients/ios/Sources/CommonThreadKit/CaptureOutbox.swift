import Foundation

/// Immutable capture intent. Credentials are deliberately absent. Scope drafts to the verified account and API.
public struct PendingCapture: Codable, Sendable, Identifiable {
    public let id: String
    public let key: MutationKey
    public let request: CaptureRequest
    public let accountId: String
    public let baseURL: URL
    public let createdAt: Date
    public init(request: CaptureRequest, accountId: String, baseURL: URL) {
        id = UUID().uuidString; key = MutationKey(); self.request = request
        self.accountId = accountId; self.baseURL = baseURL; createdAt = Date()
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
    }
}
