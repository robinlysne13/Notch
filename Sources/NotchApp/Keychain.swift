import Foundation
import Security

/// Minimal generic-password store. Secrets never touch `UserDefaults` — only the things that
/// aren't secret (a Spotify client id, the dashboard's email address) live there.
enum Keychain {
    /// Spotify tokens and the dashboard password are different kinds of secret, so they get
    /// their own Keychain services — revoking one never disturbs the other.
    static let spotifyService = "com.robin.notch.spotify"
    static let dashboardService = "com.robin.notch.dashboard"

    static func setPassword(_ password: String, account: String, service: String) {
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

    static func password(account: String, service: String) -> String? {
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

    static func delete(account: String, service: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
