import Combine
import Foundation

enum DashboardError: LocalizedError {
    case notSignedIn
    case signInFailed(String)
    case requestFailed(String)
    case contended

    var errorDescription: String? {
        switch self {
        case .notSignedIn: "Not signed in to the dashboard."
        case .signInFailed(let why): "The dashboard refused the sign-in: \(why)"
        case .requestFailed(let why): "The dashboard didn't answer: \(why)"
        case .contended: "Another device is writing — try again in a moment."
        }
    }
}

/// Where the dashboard lives. The publishable key is safe to ship: what an account may read or
/// write is decided by row-level security on the database, not by this key — it is the same one
/// the web app sends from the browser.
enum Dashboard {
    static let url = "https://bopfqghmrznretqgayht.supabase.co"
    static let anonKey = "sb_publishable_n778yoMXuJOKG0AvKvFZqQ_pBQqTvtc"
}

/// The dashboard sign-in: the same email and password as the web app, since both talk to the one
/// Supabase project.
///
/// Only the refresh token is persisted, in the Keychain — the password is handed over once and
/// never kept, and the access token lives in memory and is renewed on demand. Supabase rotates
/// the refresh token on every renewal, so the new one replaces the old as it arrives.
@MainActor
final class DashboardAccount: ObservableObject {
    @Published private(set) var isSignedIn = false
    @Published private(set) var isSigningIn = false
    /// The address, so the settings window can say whose dashboard this is. Not a secret.
    @Published private(set) var email: String

    private static let emailKey = "dashboard.email"
    private static let keychainAccount = "refresh-token"

    private var token: String?
    private var expiry: Date?
    /// One renewal at a time: a burst of requests waking to an expired token would otherwise each
    /// spend the same refresh token, and Supabase only honours the first — the rest would come
    /// back as a sign-out.
    private var renewal: Task<String, Error>?

    init() {
        email = UserDefaults.standard.string(forKey: Self.emailKey) ?? ""
        isSignedIn = Self.storedRefreshToken != nil
    }

    private static var storedRefreshToken: String? {
        Keychain.password(account: keychainAccount, service: Keychain.dashboardService)
    }

    private static func store(refreshToken: String) {
        Keychain.setPassword(refreshToken, account: keychainAccount, service: Keychain.dashboardService)
    }

    // MARK: Signing in

    func signIn(email: String, password: String) async throws {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty, !password.isEmpty else {
            throw DashboardError.signInFailed("enter your email and password")
        }

        isSigningIn = true
        defer { isSigningIn = false }

        let response = try await postToken(
            grant: "password",
            body: ["email": email, "password": password]
        )
        apply(response)
        self.email = email
        UserDefaults.standard.set(email, forKey: Self.emailKey)
        isSignedIn = true
    }

    func signOut() {
        Keychain.delete(account: Self.keychainAccount, service: Keychain.dashboardService)
        renewal?.cancel()
        renewal = nil
        token = nil
        expiry = nil
        isSignedIn = false
    }

    // MARK: Tokens

    /// A valid access token, renewed if the one in hand has expired or is about to.
    func accessToken() async throws -> String {
        if let token, let expiry, expiry > Date().addingTimeInterval(60) { return token }
        if let renewal { return try await renewal.value }

        let task = Task { [weak self] () throws -> String in
            guard let self else { throw DashboardError.notSignedIn }
            return try await self.renew()
        }
        renewal = task
        defer { renewal = nil }
        return try await task.value
    }

    /// Spend the stored refresh token for a fresh access token. A refusal here means the token
    /// has been revoked or has aged out, which is a sign-out rather than a transient failure —
    /// retrying it forever would just leave the tab claiming to be connected.
    private func renew() async throws -> String {
        guard let refresh = Self.storedRefreshToken else {
            isSignedIn = false
            throw DashboardError.notSignedIn
        }
        do {
            let response = try await postToken(
                grant: "refresh_token",
                body: ["refresh_token": refresh]
            )
            apply(response)
            isSignedIn = true
            return response.access_token
        } catch DashboardError.signInFailed(let why) {
            signOut()
            throw DashboardError.signInFailed("\(why) — sign in again")
        }
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Double?
    }

    private func apply(_ response: TokenResponse) {
        token = response.access_token
        expiry = Date().addingTimeInterval(response.expires_in ?? 3600)
        if let refresh = response.refresh_token { Self.store(refreshToken: refresh) }
    }

    private func postToken(grant: String, body: [String: String]) async throws -> TokenResponse {
        guard let url = URL(string: "\(Dashboard.url)/auth/v1/token?grant_type=\(grant)") else {
            throw DashboardError.requestFailed("bad token URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(Dashboard.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DashboardError.requestFailed("no response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw DashboardError.signInFailed(Self.reason(in: data, status: http.statusCode))
        }
        do {
            return try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            throw DashboardError.requestFailed("unreadable token response")
        }
    }

    /// Supabase explains itself in the body; fall back to the status code when it doesn't.
    private static func reason(in data: Data, status: Int) -> String {
        struct Problem: Decodable {
            let error_description: String?
            let msg: String?
            let message: String?
            let error: String?
        }
        if let problem = try? JSONDecoder().decode(Problem.self, from: data),
           let said = problem.error_description ?? problem.msg ?? problem.message ?? problem.error,
           !said.isEmpty {
            return said
        }
        return "HTTP \(status)"
    }
}
