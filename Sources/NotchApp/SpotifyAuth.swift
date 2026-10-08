import AppKit
import Combine
import CryptoKit
import Foundation
import Network

enum SpotifyAuthError: LocalizedError {
    case noClientID
    case cancelled
    case callbackFailed(String)
    case tokenRequestFailed(String)
    case notConnected

    var errorDescription: String? {
        switch self {
        case .noClientID: "Add your Spotify Client ID first."
        case .cancelled: "Sign-in was cancelled."
        case .callbackFailed(let why): "Spotify didn't finish sign-in: \(why)"
        case .tokenRequestFailed(let why): "Spotify rejected the request: \(why)"
        case .notConnected: "Not signed in to Spotify."
        }
    }
}

/// OAuth against the Spotify Web API using Authorization Code with PKCE — the flow meant for
/// desktop apps, which have nowhere safe to keep a client secret.
///
/// Only the refresh token is persisted, in the Keychain. The access token lives in memory and is
/// renewed on demand, so quitting the app leaves nothing short-lived behind.
@MainActor
final class SpotifyAuth: ObservableObject {
    @Published private(set) var isConnected = false
    @Published private(set) var isConnecting = false
    /// Not a secret — a public client id identifies the app, it doesn't authorize anything on its
    /// own — so `UserDefaults` is the right home for it.
    @Published var clientID: String {
        didSet { UserDefaults.standard.set(clientID, forKey: Self.clientIDKey) }
    }

    /// Must match the redirect URI registered on the Spotify app byte for byte. A loopback
    /// address is the one plain-http redirect Spotify still accepts.
    static let redirectURI = "http://127.0.0.1:8888/callback"
    private static let port: UInt16 = 8888
    private static let scopes = "user-library-read user-library-modify"
    private static let clientIDKey = "spotify.clientID"
    private static let keychainAccount = "refresh-token"

    private var token: String?
    private var expiry: Date?

    init() {
        clientID = UserDefaults.standard.string(forKey: Self.clientIDKey) ?? ""
        isConnected = Keychain.password(
            account: Self.keychainAccount,
            service: Keychain.spotifyService
        ) != nil
    }

    // MARK: Signing in

    func connect() async throws {
        let clientID = clientID.trimmingCharacters(in: .whitespaces)
        guard !clientID.isEmpty else { throw SpotifyAuthError.noClientID }

        isConnecting = true
        defer { isConnecting = false }

        let verifier = Self.randomToken()
        let state = Self.randomToken()
        guard let url = Self.authorizeURL(
            clientID: clientID,
            challenge: Self.challenge(for: verifier),
            state: state
        ) else {
            throw SpotifyAuthError.callbackFailed("could not build the authorize URL")
        }

        let server = LoopbackServer()
        defer { server.stop() }

        // The listener has to be waiting before the browser can redirect back into it.
        async let callback = server.awaitCallback(port: Self.port)
        NSWorkspace.shared.open(url)
        let result = try await callback

        // Guards against a redirect this app didn't initiate.
        guard result.state == state else { throw SpotifyAuthError.callbackFailed("state mismatch") }
        guard let code = result.code else {
            throw SpotifyAuthError.callbackFailed(result.error ?? "no authorization code")
        }

        let response = try await postToken([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": Self.redirectURI,
            "client_id": clientID,
            "code_verifier": verifier,
        ])
        apply(response)
        isConnected = true
    }

    func disconnect() {
        Keychain.delete(account: Self.keychainAccount, service: Keychain.spotifyService)
        token = nil
        expiry = nil
        isConnected = false
    }

    // MARK: Tokens

    /// A valid access token, refreshed if the one in hand has expired or is about to.
    func accessToken() async throws -> String {
        if let token, let expiry, expiry > Date().addingTimeInterval(30) { return token }

        guard let refresh = Keychain.password(
            account: Self.keychainAccount,
            service: Keychain.spotifyService
        ) else {
            isConnected = false
            throw SpotifyAuthError.notConnected
        }
        let clientID = clientID.trimmingCharacters(in: .whitespaces)
        guard !clientID.isEmpty else { throw SpotifyAuthError.noClientID }

        let response = try await postToken([
            "grant_type": "refresh_token",
            "refresh_token": refresh,
            "client_id": clientID,
        ])
        apply(response)
        return response.access_token
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let expires_in: Double
        let refresh_token: String?
    }

    private func apply(_ response: TokenResponse) {
        token = response.access_token
        expiry = Date().addingTimeInterval(response.expires_in)
        // Spotify sometimes rotates the refresh token; when it does, the previous one stops
        // working, so the new one has to replace it immediately.
        if let rotated = response.refresh_token {
            Keychain.setPassword(
                rotated,
                account: Self.keychainAccount,
                service: Keychain.spotifyService
            )
        }
    }

    private func postToken(_ fields: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncoded(fields)
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SpotifyAuthError.tokenRequestFailed("no response")
        }
        guard http.statusCode == 200 else {
            // Spotify's error bodies name the actual problem (bad redirect URI, expired code),
            // which is far more use than the status code alone.
            let detail = String(data: data, encoding: .utf8) ?? "status \(http.statusCode)"
            if http.statusCode == 400 || http.statusCode == 401 { disconnect() }
            throw SpotifyAuthError.tokenRequestFailed(detail)
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    // MARK: Request building

    private static func authorizeURL(clientID: String, challenge: String, state: String) -> URL? {
        var components = URLComponents(string: "https://accounts.spotify.com/authorize")
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "scope", value: scopes),
        ]
        return components?.url
    }

    /// Form bodies must escape everything outside the unreserved set — `URLComponents` leaves
    /// `+` alone, which a server then reads as a space.
    nonisolated static func formEncoded(_ fields: [String: String]) -> Data? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)
    }

    /// 64 characters from the PKCE unreserved set, used for both the verifier and the state.
    private static func randomToken() -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var generator = SystemRandomNumberGenerator()
        return String((0..<64).map { _ in alphabet[Int(generator.next(upperBound: UInt64(alphabet.count)))] })
    }

    nonisolated static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8)))
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// A one-shot HTTP listener on loopback, alive just long enough to catch the redirect the
/// browser is sent back to. Deliberately not a general server: it answers one request and stops.
/// What comes back on the redirect. Parsed from the raw request line, so it is pulled out of
/// the listener to be testable on its own.
struct OAuthCallback: Equatable {
    let code: String?
    let state: String?
    let error: String?

    /// Reads the query off an HTTP request line — `GET /callback?code=…&state=… HTTP/1.1`.
    static func parse(_ request: String) -> OAuthCallback {
        guard let line = request.split(whereSeparator: \.isNewline).first,
              let path = line.split(separator: " ").dropFirst().first,
              let components = URLComponents(string: "http://127.0.0.1\(path)")
        else { return OAuthCallback(code: nil, state: nil, error: "unreadable request") }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        return OAuthCallback(code: value("code"), state: value("state"), error: value("error"))
    }
}

private final class LoopbackServer: @unchecked Sendable {
    private var listener: NWListener?
    private var continuation: CheckedContinuation<OAuthCallback, Error>?
    private let lock = NSLock()

    func awaitCallback(port: UInt16) async throws -> OAuthCallback {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            do {
                let parameters = NWParameters.tcp
                // The port must be reusable, or a cancelled sign-in blocks the next attempt.
                parameters.allowLocalEndpointReuse = true
                guard let port = NWEndpoint.Port(rawValue: port) else {
                    throw SpotifyAuthError.callbackFailed("bad port")
                }
                let listener = try NWListener(using: parameters, on: port)
                listener.newConnectionHandler = { [weak self] in self?.handle($0) }
                listener.start(queue: .global(qos: .userInitiated))
                self.listener = listener
            } catch {
                finish(.failure(error))
            }
        }
    }

    func stop() {
        // A no-op once the callback has landed — `finish` only resumes the first time.
        finish(.failure(SpotifyAuthError.cancelled))
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, _ in
            guard let self else { return }
            let callback = OAuthCallback.parse(data.flatMap { String(data: $0, encoding: .utf8) } ?? "")
            let body = Self.page(success: callback.code != nil)
            let response = "HTTP/1.1 200 OK\r\n"
                + "Content-Type: text/html; charset=utf-8\r\n"
                + "Content-Length: \(body.utf8.count)\r\n"
                + "Connection: close\r\n\r\n"
                + body
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
            self.finish(.success(callback))
        }
    }

    private func finish(_ result: Result<OAuthCallback, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        guard let continuation else { return }
        listener?.cancel()
        listener = nil
        continuation.resume(with: result)
    }

    private static func page(success: Bool) -> String {
        let heading = success ? "Connected." : "Sign-in failed."
        let detail = success
            ? "You can close this tab and go back to Notch."
            : "Close this tab and try again from Notch."
        return """
        <!doctype html><meta charset="utf-8"><title>Notch</title>
        <body style="font: 15px -apple-system, system-ui; margin: 0; display: grid;
                     place-items: center; height: 100vh; background: #111; color: #eee;">
        <div style="text-align: center">
        <h2 style="font-weight: 600; margin: 0 0 8px">\(heading)</h2>
        <p style="margin: 0; opacity: .6">\(detail)</p>
        </div></body>
        """
    }
}
