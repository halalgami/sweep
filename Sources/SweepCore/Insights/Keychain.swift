import Foundation
import Security

/// API keys live in the login Keychain, never in defaults or files.
public enum Keychain {
    public static let service = "dev.algamthe.sweep"

    public static func save(_ value: String, account: String) throws {
        delete(account: account)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecValueData as String: Data(value.utf8),
                                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked]
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw SQLiteError(description: "Keychain error \(status)") }
    }

    public static func load(account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(decoding: d, as: UTF8.self)
    }

    @discardableResult
    public static func delete(account: String) -> Bool {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        return SecItemDelete(q as CFDictionary) == errSecSuccess
    }
}
