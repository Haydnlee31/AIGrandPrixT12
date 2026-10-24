import Foundation
import Security
import CommonThreadKit

enum SetupError: Error, LocalizedError {
    case missingConfiguration, sharedContainerUnavailable, keychain(OSStatus), accountChanged
    var errorDescription: String? {
        switch self {
        case .missingConfiguration: return "Open Mynah Finds and connect your account in Profile first."
        case .sharedContainerUnavailable: return "This build declares an App Group that is unavailable. Check App Group signing for both targets, or use the local device build."
        case .keychain(let status): return "Secure credential storage failed (\(status)). Check signing and Keychain Sharing."
        case .accountChanged: return "The signed-in account changed. Reconnect before syncing this account’s saves."
        }
    }
}

/// A fully provisioned build uses the App Group for nonsecret cloud configuration
/// and queued captures. The explicitly group-free local device build uses its host
/// sandbox instead. Credentials always remain in the shared Keychain access group.
/// The Share Extension reads a nonsecret destination from Keychain Sharing, which
/// also works in group-free builds. Its durable payload handoff uses LocalShareInbox.
struct SharedEnvironment: Codable {
    let baseURL: URL
    let accountId: String
    var loginSubject: String? = nil
    var email: String? = nil
    static var group: String { Bundle.main.object(forInfoDictionaryKey: "CommonThreadAppGroup") as? String ?? "" }
    static var keychainGroup: String { Bundle.main.object(forInfoDictionaryKey: "CommonThreadKeychainGroup") as? String ?? "" }
    /// An absent App Group is an explicit local-build choice. A configured but
    /// unavailable group is an error; it must never silently split a shared queue.
    static var usesSharedAppGroup: Bool { !group.isEmpty }
    private static func sharedContainerRoot() throws -> URL {
        guard !group.isEmpty,
              let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            throw SetupError.sharedContainerUnavailable
        }
        return root
    }
    private static func configurationDefaults() throws -> UserDefaults {
        if !usesSharedAppGroup { return .standard }
        _ = try sharedContainerRoot()
        guard let defaults = UserDefaults(suiteName: group) else { throw SetupError.sharedContainerUnavailable }
        return defaults
    }
    static func read() throws -> Self {
        guard let data = try configurationDefaults().data(forKey: "connection") else { throw SetupError.missingConfiguration }
        return try JSONDecoder().decode(Self.self, from: data)
    }
    func store() throws {
        let defaults = try Self.configurationDefaults()
        try publishShareDestination()
        defaults.set(try JSONEncoder().encode(self), forKey: "connection")
    }
    private static var shareDestinationQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "MynahFinds.SharedDestination.v1",
         kSecAttrAccount as String: "active", kSecAttrAccessGroup as String: keychainGroup]
    }
    static func readForSharing() throws -> Self? {
        var query = shareDestinationQuery
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw SetupError.keychain(status) }
        return try JSONDecoder().decode(Self.self, from: data)
    }
    func publishShareDestination() throws {
        let values: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(self),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(Self.shareDestinationQuery as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(Self.shareDestinationQuery.merging(values) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw SetupError.keychain(status) }
    }
    static func outbox() throws -> CaptureOutbox {
        let root: URL
        if usesSharedAppGroup {
            root = try sharedContainerRoot()
        } else {
            root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                              appropriateFor: nil, create: true)
                .appendingPathComponent("MynahFinds", isDirectory: true)
        }
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
        let defaults = try Self.configurationDefaults()
        if let shared = try Self.readForSharing(), shared.accountId == accountId, shared.baseURL == baseURL {
            let removal = SecItemDelete(Self.shareDestinationQuery as CFDictionary)
            guard removal == errSecSuccess || removal == errSecItemNotFound else { throw SetupError.keychain(removal) }
        }
        let status = SecItemDelete(credentialQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SetupError.keychain(status) }
        // Clear only this account's connection. Queued captures remain scoped by
        // both accountId and baseURL in CaptureOutbox when another account connects.
        if let data = defaults.data(forKey: "connection"),
           let stored = try? JSONDecoder().decode(Self.self, from: data),
           stored.accountId == accountId, stored.baseURL == baseURL {
            defaults.removeObject(forKey: "connection")
        }
        // Pending drafts remain account-scoped for recovery. A production account-deletion flow must erase them.
    }
    func client() throws -> CommonThreadClient {
        try CommonThreadClient(baseURL: baseURL) { try await self.accessToken() }
    }
    func accessToken() async throws -> String {
        if loginSubject == nil { return try token() }
        return try await SharedLoginTokens.shared.token(for: self)
    }
    func verify(_ client: CommonThreadClient) async throws {
        guard try await client.account().userId == accountId else { throw SetupError.accountChanged }
    }
}

/// Coalesce refreshes across screens. Re-read Keychain before using the cache,
/// and never restore a credential after another task signed the account out.
private actor SharedLoginTokens {
    static let shared = SharedLoginTokens()
    private var cached: [String:(credential: String, token: String, expires: Date)] = [:]
    private var flights: [String:Task<String,Error>] = [:]
    func token(for environment: SharedEnvironment) async throws -> String {
        let key = environment.baseURL.absoluteString + "|" + environment.accountId
        let stored = try environment.token()
        if let value = cached[key], value.credential == stored, value.expires.timeIntervalSinceNow > 60 { return value.token }
        if let task = flights[key] { return try await task.value }
        let task = Task { () throws -> String in
            let credential = try JSONDecoder().decode(LoginCredential.self, from: Data(stored.utf8))
            guard credential.subject == environment.loginSubject else { throw SetupError.accountChanged }
            let result = try await NeonSessionClient(baseURL: environment.baseURL).token(for: credential)
            guard try environment.token() == stored else { throw SetupError.accountChanged }
            let updated = String(decoding: try JSONEncoder().encode(result.credential), as: UTF8.self)
            try environment.store(token: updated)
            self.cached[key] = (updated, result.token, result.expires)
            return result.token
        }
        flights[key] = task
        defer { flights[key] = nil }
        return try await task.value
    }
}
