import Foundation
import Security

/// Minimal generic-password store. App-specific passwords never touch `UserDefaults` — only the
/// account's address and provider live there (see `MailAccountStore`).
enum Keychain {
    /// Mail passwords and Spotify tokens are different kinds of secret, so they get their own
    /// Keychain services — revoking one never disturbs the other.
    static let mailService = "com.robin.notch.mail"
    static let spotifyService = "com.robin.notch.spotify"

    static func setPassword(_ password: String, account: String, service: String = mailService) {
        // Delete-then-add rather than SecItemUpdate: it is one code path for both "new account"
        // and "password rotated", which is all this needs.
        delete(account: account, service: service)
        guard !password.isEmpty, let data = password.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func password(account: String, service: String = mailService) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String, service: String = mailService) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
