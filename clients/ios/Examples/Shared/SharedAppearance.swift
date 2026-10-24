import SwiftUI
import Security

/// The same appearance choice reaches the extension even in the local Keychain build.
enum SharedAppearance {
    private static func query() -> [String: Any]? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "CommonThreadKeychainGroup") as? String,
              !group.isEmpty, !group.contains("$(") else { return nil }
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "MynahFinds.Appearance.v1", kSecAttrAccount as String: "appearance",
                kSecAttrAccessGroup as String: group, kSecAttrSynchronizable as String: false]
    }
    static func set(_ value: String) {
        guard ["system", "light", "dark"].contains(value), let query = query() else { return }
        let data = Data(value.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query; attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(attributes as CFDictionary, nil)
        }
    }
    static var colorScheme: ColorScheme? {
        guard var query = query() else { return nil }
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let value = String(data: data, encoding: .utf8) else { return nil }
        switch value { case "light": return .light; case "dark": return .dark; default: return nil }
    }
}
