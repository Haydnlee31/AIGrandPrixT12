import Foundation
import Security
import CryptoKit

/// A short-lived local handoff. The app moves each draft to its ordinary file store,
/// then removes it from this inbox. No content is uploaded or synchronized to iCloud.
struct LocalShareDraft: Codable, Identifiable, Sendable {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var title: String
    var url: String?
    var text: String
    var note: String
    var attachments: [LocalShareAttachment]
    var intents: [String]? = nil
    var analysis: CaptureIntelligenceResult? = nil
    var userEditedTitle: Bool? = nil
}

struct LocalShareAttachment: Codable, Identifiable, Sendable {
    var id: UUID = UUID()
    var filename: String
    var typeIdentifier: String
    var data: Data
}

enum LocalShareInboxError: Error, LocalizedError {
    case configuration, keychain(OSStatus), tooLarge, full, incomplete, empty, fieldTooLong(String)
    var errorDescription: String? {
        switch self {
        case .fieldTooLong(let field): return field
        case .configuration: return "Sharing isn't configured in this build. Open Mymah Finds and try again."
        case .keychain: return "This find couldn't be saved securely. Keep this sheet open and try again."
        case .tooLarge: return "Share up to 10 attachments, 4 MB per file and 12 MB in total. Try smaller files or share their link."
        case .full: return "Open Mymah Finds to finish importing your pending saves, then try again."
        case .incomplete: return "A pending save is incomplete. It has been kept so you can retry importing it."
        case .empty: return "Add a link, text, or a photo before saving."
        }
    }
}

/// Keychain Sharing works with the cached development signing profile, unlike App
/// Groups. Payloads are split into bounded entries; the manifest is written LAST.
/// This is a development handoff, not the permanent media store or a cloud queue.
/// A normally provisioned build can replace this adapter with an App Group folder.
enum LocalShareInbox {
    static let maxAttachmentBytes = 4 * 1_024 * 1_024
    static let maxTotalBytes = 12 * 1_024 * 1_024
    static let maxAttachments = 10
    private static let chunkBytes = 192 * 1_024
    private static let service = "MymahFinds.LocalShareInbox.v1"
    private struct Manifest: Codable {
        let id: UUID
        let count: Int
        let byteCount: Int
        let digest: Data
    }
    private static var group: String {
        Bundle.main.object(forInfoDictionaryKey: "CommonThreadKeychainGroup") as? String ?? ""
    }
    private static func query(service suffix: String, account: String? = nil) throws -> [String: Any] {
        guard !group.isEmpty, !group.contains("$(") else { throw LocalShareInboxError.configuration }
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service + suffix, kSecAttrAccessGroup as String: group,
            kSecAttrSynchronizable as String: false]
        if let account { query[kSecAttrAccount as String] = account }
        return query
    }
    private static func put(_ data: Data, service: String, account: String) throws {
        var attributes = try query(service: service, account: account)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw LocalShareInboxError.keychain(status) }
    }
    private static func read(service: String, account: String) throws -> Data? {
        var attributes = try query(service: service, account: account)
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw LocalShareInboxError.keychain(status) }
        return data
    }
    private static func manifests() throws -> [Manifest] {
        var attributes = try query(service: ".manifest")
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let entries = result as? [Data] else { throw LocalShareInboxError.keychain(status) }
        return try entries.map { try JSONDecoder().decode(Manifest.self, from: $0) }
    }
    static func validationIssue(_ draft: LocalShareDraft) -> String? {
        if draft.title.count > 300 { return "Shorten the title to 300 characters (currently \(draft.title.count))." }
        if (draft.url?.count ?? 0) > 2048 { return "Use a shorter link, up to 2,048 characters." }
        if let link = draft.url, !link.isEmpty {
            guard let parts = URLComponents(string: link), ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
                  let host = parts.host, host.contains("."), parts.user == nil, parts.password == nil else {
                return "Use a public http or https link without a username or password."
            }
        }
        if draft.text.count > 12_000 { return "Shorten the captured text to 12,000 characters (currently \(draft.text.count))." }
        if draft.note.count > 2_000 { return "Shorten your note to 2,000 characters (currently \(draft.note.count))." }
        if let intents = draft.intents, intents.count > 8 || intents.contains(where: { $0.count > 500 }) || intents.reduce(0, { $0 + $1.count }) > 4000 {
            return "Choose up to 8 details, with up to 500 characters each."
        }
        return nil
    }
    static func save(_ draft: LocalShareDraft) throws {
        guard draft.attachments.count <= maxAttachments,
              draft.attachments.allSatisfy({ $0.data.count <= maxAttachmentBytes }),
              draft.attachments.reduce(0, { $0 + $1.data.count }) <= maxTotalBytes else { throw LocalShareInboxError.tooLarge }
        if let issue = validationIssue(draft) { throw LocalShareInboxError.fieldTooLong(issue) }
        guard !(draft.url ?? "").isEmpty || !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draft.attachments.isEmpty else { throw LocalShareInboxError.empty }
        let existing = try manifests()
        if existing.contains(where: { $0.id == draft.id }) { return }
        guard existing.count < 20 else { throw LocalShareInboxError.full }
        let encoded = try JSONEncoder().encode(draft)
        let count = (encoded.count + chunkBytes - 1) / chunkBytes
        var written = 0
        do {
            for index in 0..<count {
                let start = index * chunkBytes
                let chunk = encoded.subdata(in: start..<min(start + chunkBytes, encoded.count))
                // A killed process may leave uncommitted chunks for this same draft.
                try delete(service: ".chunk", account: "\(draft.id.uuidString).\(index)")
                try put(chunk, service: ".chunk", account: "\(draft.id.uuidString).\(index)")
                written += 1
            }
            let manifest = Manifest(id: draft.id, count: count, byteCount: encoded.count, digest: Data(SHA256.hash(data: encoded)))
            try put(JSONEncoder().encode(manifest), service: ".manifest", account: draft.id.uuidString)
        } catch {
            for index in 0..<written { try? delete(service: ".chunk", account: "\(draft.id.uuidString).\(index)") }
            throw error
        }
    }
    static func pending() throws -> [LocalShareDraft] {
        try manifests().map { manifest in
            guard (1...100).contains(manifest.count), manifest.byteCount <= maxTotalBytes * 2 else { throw LocalShareInboxError.incomplete }
            var payload = Data()
            for index in 0..<manifest.count {
                guard let part = try read(service: ".chunk", account: "\(manifest.id.uuidString).\(index)") else { throw LocalShareInboxError.incomplete }
                payload.append(part)
            }
            guard payload.count == manifest.byteCount, Data(SHA256.hash(data: payload)) == manifest.digest else { throw LocalShareInboxError.incomplete }
            return try JSONDecoder().decode(LocalShareDraft.self, from: payload)
        }.sorted { $0.createdAt < $1.createdAt }
    }
    static func remove(_ draft: LocalShareDraft) throws { try remove(id: draft.id) }
    static func remove(id: UUID) throws {
        guard let data = try read(service: ".manifest", account: id.uuidString) else { return }
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        // Only called AFTER the host's durable, idempotent import. If cleanup is
        // interrupted, an absent manifest prevents any duplicate library entry.
        try delete(service: ".manifest", account: id.uuidString)
        for index in 0..<manifest.count { try delete(service: ".chunk", account: "\(id.uuidString).\(index)") }
    }
    private static func delete(service: String, account: String) throws {
        let status = SecItemDelete(try query(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw LocalShareInboxError.keychain(status) }
    }
}
