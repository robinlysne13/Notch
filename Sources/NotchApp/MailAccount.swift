import Combine
import Foundation

enum MailProvider: String, Codable, CaseIterable, Identifiable {
    case icloud
    case gmail

    var id: String { rawValue }

    var label: String {
        switch self {
        case .icloud: return "iCloud"
        case .gmail: return "Gmail"
        }
    }

    var host: String {
        switch self {
        case .icloud: return "imap.mail.me.com"
        case .gmail: return "imap.gmail.com"
        }
    }

    /// Where the provider hands out app-specific passwords. Both providers refuse a plain account
    /// password over IMAP once two-factor auth is on, which it is by default.
    var appPasswordURL: String {
        switch self {
        case .icloud: return "https://account.apple.com/account/manage"
        case .gmail: return "https://myaccount.google.com/apppasswords"
        }
    }
}

struct MailAccount: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var provider: MailProvider
    var address: String

    /// Keychain lookups are keyed by id, not address, so re-adding the same address after a
    /// removal can't silently inherit the old password.
    var credentialKey: String { "\(provider.rawValue):\(id.uuidString)" }
}

/// Accounts the code watcher polls. Addresses and providers persist in `UserDefaults`; the
/// app-specific passwords live in the Keychain under `credentialKey`.
@MainActor
final class MailAccountStore: ObservableObject {
    @Published private(set) var accounts: [MailAccount] = []

    private let defaultsKey = "mailAccounts"

    init() {
        load()
    }

    func add(provider: MailProvider, address: String, password: String) {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty, !password.isEmpty else { return }
        let account = MailAccount(provider: provider, address: address)
        Keychain.setPassword(password, account: account.credentialKey)
        accounts.append(account)
        save()
    }

    func remove(_ account: MailAccount) {
        Keychain.delete(account: account.credentialKey)
        accounts.removeAll { $0.id == account.id }
        save()
    }

    func password(for account: MailAccount) -> String? {
        Keychain.password(account: account.credentialKey)
    }

    /// An account whose Keychain entry has gone missing can't be polled; surface it so the UI can
    /// ask for the password again instead of failing silently on every refresh.
    func isUsable(_ account: MailAccount) -> Bool {
        password(for: account)?.isEmpty == false
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([MailAccount].self, from: data)
        else { return }
        accounts = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(accounts) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}
