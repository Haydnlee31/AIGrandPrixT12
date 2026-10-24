import Foundation
import CryptoKit
import CommonThreadKit

extension SharedEnvironment {
    /// Reject a retained destination after sign-out/account replacement and verify
    /// that the current credential still belongs to the configured account.
    func intelligenceClient() async throws -> CommonThreadClient {
        try Task.checkCancellation()
        let active = try Self.read()
        guard active.accountId == accountId, active.baseURL == baseURL else { throw SetupError.accountChanged }
        let api = try client()
        try await verify(api)
        try Task.checkCancellation()
        let latest = try Self.read()
        guard latest.accountId == accountId, latest.baseURL == baseURL else { throw SetupError.accountChanged }
        return api
    }
}

/// Retains the exact write payload/key across a screen dismissal or app restart.
/// Account and origin are part of the filename hash; credentials are never written.
actor IntelligenceMutationKeys {
    static let shared = IntelligenceMutationKeys()
    private struct Entry: Codable { let key: MutationKey; let payload: Data }

    func key<Payload: Encodable>(for payload: Payload, scope: String, connection: SharedEnvironment) throws -> MutationKey {
        let data = try CommonThreadClient.encoder().encode(payload)
        let url = try file(payload: data, scope: scope, connection: connection)
        if FileManager.default.fileExists(atPath: url.path) {
            let existing = try JSONDecoder().decode(Entry.self, from: Data(contentsOf: url))
            guard existing.payload == data else { throw CocoaError(.fileReadCorruptFile) }
            return existing.key
        }
        let entry = Entry(key: MutationKey(), payload: data)
        try JSONEncoder().encode(entry).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return entry.key
    }

    func complete<Payload: Encodable>(_ payload: Payload, scope: String, connection: SharedEnvironment) throws {
        let url = try file(payload: CommonThreadClient.encoder().encode(payload), scope: scope, connection: connection)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    private func file(payload: Data, scope: String, connection: SharedEnvironment) throws -> URL {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("MymahFinds/IntelligenceMutations", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var identity = Data("\(connection.baseURL.absoluteString)\n\(connection.accountId)\n\(scope)\n".utf8)
        identity.append(payload)
        let name = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(name + ".json")
    }
}
