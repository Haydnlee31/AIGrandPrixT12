import Foundation
import Security
import CommonThreadKit

enum SetupError: Error, LocalizedError {
    case missingConfiguration, keychain(OSStatus), accountChanged
    var errorDescription: String? {
        switch self {
        case .missingConfiguration: return "Open Mynah Finds and connect your account in Profile first."
        case .keychain(let status): return "Secure credential storage failed (\(status)). Check signing and Keychain Sharing."
        case .accountChanged: return "The signed-in account changed. Reconnect before syncing this account’s saves."
        }
    }
}

/// App Group holds nonsecret configuration and queued captures; Keychain holds only the token.
struct SharedEnvironment: Codable {
    let baseURL: URL
    let accountId: String
    static var group: String { Bundle.main.object(forInfoDictionaryKey: "CommonThreadAppGroup") as? String ?? "" }
    static var keychainGroup: String { Bundle.main.object(forInfoDictionaryKey: "CommonThreadKeychainGroup") as? String ?? "" }
    static func read() throws -> Self {
        guard !group.isEmpty, let data = UserDefaults(suiteName: group)?.data(forKey: "connection") else { throw SetupError.missingConfiguration }
        return try JSONDecoder().decode(Self.self, from: data)
    }
    func store() throws {
        guard !Self.group.isEmpty, FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.group) != nil,
              let defaults = UserDefaults(suiteName: Self.group) else { throw SetupError.missingConfiguration }
        defaults.set(try JSONEncoder().encode(self), forKey: "connection")
    }
    static func outbox() throws -> CaptureOutbox {
        guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { throw SetupError.missingConfiguration }
        return CaptureOutbox(directory: root.appendingPathComponent("CaptureOutbox", isDirectory: true))
    }
    private var credentialQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "CommonThread.\(baseURL.absoluteString)",
         kSecAttrAccount as String: accountId, kSecAttrAccessGroup as String: Self.keychainGroup]
    }
    func token() throws -> String {
        var query = credentialQuery
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else { throw SetupError.keychain(status) }
        return value
    }
    func store(token: String) throws {
        let values: [String: Any] = [kSecValueData as String: Data(token.utf8), kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(credentialQuery as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(credentialQuery.merging(values) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw SetupError.keychain(status) }
    }
    func signOut() throws {
        let status = SecItemDelete(credentialQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SetupError.keychain(status) }
        UserDefaults(suiteName: Self.group)?.removeObject(forKey: "connection")
        // Pending drafts remain account-scoped for recovery. A production account-deletion flow must erase them.
    }
    func client() throws -> CommonThreadClient {
        try CommonThreadClient(baseURL: baseURL) { try self.token() }
    }
    func verify(_ client: CommonThreadClient) async throws {
        guard try await client.account().userId == accountId else { throw SetupError.accountChanged }
    }
}
