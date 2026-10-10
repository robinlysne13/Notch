import AppKit
import CryptoKit
import Foundation
import Network
import OSLog

/// `log show --predicate 'subsystem == "com.robin.notch"' --last 5m` reads these.
let spotifyLog = Logger(subsystem: "com.robin.notch", category: "spotify")

/// Spotify Web API sign-in: Authorization Code with PKCE, so there is no client secret to hide in
/// the binary. The user registers their own app in the Spotify dashboard and pastes its Client ID.
/// The refresh token lives in an owner-only file under Application Support (see `TokenFile`);
/// the short-lived access token only in memory.
///
/// Spotify only accepts HTTPS or loopback redirect URIs, so the sign-in page opens in the default
/// browser and the redirect lands on a one-shot listener bound to 127.0.0.1. The docs say a
/// port-less loopback entry is allowed, but the dashboard rejects it as "not secure", so the port
/// is fixed and part of what the user registers.
@MainActor
final class SpotifyAuth: ObservableObject {
    /// What the user adds under "Redirect URIs" in the Spotify dashboard.
    nonisolated static let callbackPort: UInt16 = 47391
    nonisolated static let registeredRedirectURI = "http://127.0.0.1:\(callbackPort)/callback"
    static let scopes = "user-read-playback-state user-modify-playback-state user-read-currently-playing"

    @Published var clientID: String {
        didSet { UserDefaults.standard.set(clientID, forKey: Self.clientIDKey) }
    }
    @Published private(set) var isConnected: Bool
    @Published private(set) var isConnecting = false
    @Published var lastError: String?

    private static let clientIDKey = "spotifyClientID"

    private var accessToken: String?
    private var accessTokenExpiry = Date.distantPast
    private var refreshTask: Task<String, Error>?
    private var receiver: LoopbackReceiver?
    private var connectTimeout: Task<Void, Never>?

    init() {
        clientID = UserDefaults.standard.string(forKey: Self.clientIDKey) ?? ""
        isConnected = TokenFile.read()?.isEmpty == false
        spotifyLog.notice("connected=\(self.isConnected ? "yes" : "no", privacy: .public)")
    }

    // MARK: Sign-in

    func connect() {
        let clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty, !isConnecting else { return }
        self.clientID = clientID
        lastError = nil
        isConnecting = true

        let verifier = Self.randomVerifier()
        let state = UUID().uuidString

        Task { [weak self] in
            guard let self else { return }
            do {
                let receiver = LoopbackReceiver(port: Self.callbackPort)
                self.receiver = receiver
                try await receiver.start()
                let redirectURI = Self.registeredRedirectURI

                var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
                components.queryItems = [
                    URLQueryItem(name: "client_id", value: clientID),
                    URLQueryItem(name: "response_type", value: "code"),
                    URLQueryItem(name: "redirect_uri", value: redirectURI),
                    URLQueryItem(name: "scope", value: Self.scopes),
                    URLQueryItem(name: "code_challenge_method", value: "S256"),
                    URLQueryItem(name: "code_challenge", value: Self.challenge(for: verifier)),
                    URLQueryItem(name: "state", value: state),
                ]
                NSWorkspace.shared.open(components.url!)

                connectTimeout = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(300))
                    guard !Task.isCancelled else { return }
                    self?.cancelConnect(message: "Spotify sign-in timed out. Try again.")
                }

                let callback = try await receiver.callback()
                connectTimeout?.cancel()
                self.receiver = nil

                let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
                guard items.first(where: { $0.name == "state" })?.value == state else {
                    throw SpotifyError.message("Spotify returned an unexpected response.")
                }
                if let refused = items.first(where: { $0.name == "error" })?.value {
                    throw SpotifyError.message("Spotify refused the sign-in (\(refused)).")
                }
                guard let code = items.first(where: { $0.name == "code" })?.value else {
                    throw SpotifyError.message("Spotify returned no authorization code.")
                }

                let token = try await Self.exchange(form: [
                    "grant_type": "authorization_code",
                    "code": code,
                    "redirect_uri": redirectURI,
                    "client_id": clientID,
                    "code_verifier": verifier,
                ])
                store(token)
                isConnected = true
                spotifyLog.notice("sign-in completed; refresh token stored")
            } catch is CancellationError {
                // cancelConnect already reported.
            } catch {
                lastError = error.localizedDescription
                spotifyLog.error("sign-in failed: \(error.localizedDescription, privacy: .public)")
            }
            connectTimeout?.cancel()
            receiver?.stop()
            receiver = nil
            isConnecting = false
        }
    }

    func cancelConnect(message: String? = nil) {
        receiver?.stop()
        receiver = nil
        connectTimeout?.cancel()
        isConnecting = false
        lastError = message
    }

    func disconnect() {
        cancelConnect()
        TokenFile.delete()
        accessToken = nil
        accessTokenExpiry = .distantPast
        isConnected = false
        lastError = nil
    }

    // MARK: Tokens

    /// A bearer token good for at least another minute, refreshing when the cached one isn't.
    func validAccessToken() async throws -> String {
        if let accessToken, Date() < accessTokenExpiry.addingTimeInterval(-60) {
            return accessToken
        }
        if let refreshTask {
            return try await refreshTask.value
        }
        let task = Task<String, Error> {
            guard let refresh = TokenFile.read(), !refresh.isEmpty else {
                throw SpotifyError.notConnected
            }
            do {
                let token = try await Self.exchange(form: [
                    "grant_type": "refresh_token",
                    "refresh_token": refresh,
                    "client_id": clientID,
                ])
                store(token)
                return token.accessToken
            } catch SpotifyError.invalidGrant {
                // The user revoked the app (or the token was rotated elsewhere): the stored token
                // is dead, so say so instead of failing every poll in silence.
                disconnect()
                lastError = "Spotify sign-in expired. Connect again."
                throw SpotifyError.notConnected
            }
        }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    /// The API answered 401: the cached token is no good regardless of its expiry.
    func invalidateAccessToken() {
        accessToken = nil
        accessTokenExpiry = .distantPast
    }

    private func store(_ token: TokenResponse) {
        accessToken = token.accessToken
        accessTokenExpiry = Date().addingTimeInterval(token.expiresIn)
        // PKCE refreshes rotate the refresh token; the old one stops working.
        if let refresh = token.refreshToken, !refresh.isEmpty {
            TokenFile.write(refresh)
        }
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let expiresIn: Double
        let refreshToken: String?
    }

    private struct TokenError: Decodable {
        let error: String?
        let errorDescription: String?
    }

    private static func exchange(form: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = body.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard status == 200 else {
            let failure = try? decoder.decode(TokenError.self, from: data)
            if failure?.error == "invalid_grant" { throw SpotifyError.invalidGrant }
            throw SpotifyError.message(
                "Spotify token request failed (\(status)): \(failure?.errorDescription ?? failure?.error ?? "no details")"
            )
        }
        return try decoder.decode(TokenResponse.self, from: data)
    }

    // MARK: PKCE

    private static func randomVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    private static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Where the refresh token lives. Not the Keychain: its legacy ACL re-prompts for the login
/// password on every rebuilt binary, which for a side-loaded app means every update. An
/// owner-only file is what the user's other processes could read anyway via that prompt.
private enum TokenFile {
    private static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Notch", isDirectory: true).appendingPathComponent("spotify-refresh-token")
    }

    static func read() -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func write(_ token: String) {
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try Data(token.utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            spotifyLog.error("couldn't save refresh token: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func delete() {
        try? FileManager.default.removeItem(at: url)
    }
}

enum SpotifyError: LocalizedError {
    case notConnected
    case invalidGrant
    case rateLimited
    case premiumRequired
    case http(Int)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Spotify isn't connected."
        case .invalidGrant: return "Spotify rejected the stored sign-in."
        case .rateLimited: return "Spotify is rate-limiting requests."
        case .premiumRequired: return "Spotify Premium is required to control playback."
        case .http(let status): return "Spotify API error (\(status))."
        case .message(let text): return text
        }
    }
}

/// One-shot HTTP listener on 127.0.0.1 that hands back the first `/callback` request it sees.
/// Everything else (favicon probes and the like) gets a 404 and is ignored.
/// All state is touched only on `queue`, which is what makes the Sendable claim hold.
private final class LoopbackReceiver: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "notch.spotify.loopback")
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var callbackContinuation: CheckedContinuation<URL, Error>?
    private var connections: [NWConnection] = []

    init(port: UInt16) {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        params.allowLocalEndpointReuse = true
        listener = try! NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
    }

    /// Resolves once the port is bound; throws if something else already holds it.
    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [weak self] in
                guard let self else { return }
                self.readyContinuation = continuation
                self.listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.readyContinuation?.resume()
                        self.readyContinuation = nil
                    case .failed:
                        let error = SpotifyError.message(
                            "Port \(SpotifyAuth.callbackPort) is in use on this Mac, so the sign-in can't be caught. Quit whatever holds it and try again."
                        )
                        self.readyContinuation?.resume(throwing: error)
                        self.readyContinuation = nil
                        self.callbackContinuation?.resume(throwing: error)
                        self.callbackContinuation = nil
                    case .cancelled:
                        self.readyContinuation?.resume(throwing: CancellationError())
                        self.readyContinuation = nil
                        self.callbackContinuation?.resume(throwing: CancellationError())
                        self.callbackContinuation = nil
                    default:
                        break
                    }
                }
                self.listener.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection)
                }
                self.listener.start(queue: self.queue)
            }
        }
    }

    /// Resolves with the redirect URL once the browser lands on `/callback`.
    func callback() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.callbackContinuation = continuation
            }
        }
    }

    func stop() {
        queue.async {
            self.listener.cancel()
            self.connections.forEach { $0.cancel() }
            self.connections.removeAll()
        }
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self else { return }
            let request = String(data: data ?? Data(), encoding: .utf8) ?? ""
            let path = request.split(separator: "\r\n", maxSplits: 1).first?
                .split(separator: " ")
                .dropFirst().first
                .map(String.init) ?? "/"
            if path.hasPrefix("/callback"), let url = URL(string: "http://127.0.0.1\(path)") {
                self.respond(on: connection, status: "200 OK", body: Self.donePage)
                self.callbackContinuation?.resume(returning: url)
                self.callbackContinuation = nil
            } else {
                self.respond(on: connection, status: "404 Not Found", body: "")
            }
        }
    }

    private func respond(on connection: NWConnection, status: String, body: String) {
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data((head + body).utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static let donePage = """
    <!doctype html><meta charset="utf-8"><title>Notch</title>
    <body style="font-family:-apple-system,system-ui;background:#111;color:#eee;display:grid;place-items:center;height:100vh;margin:0">
    <div style="text-align:center"><h2>Spotify is connected to Notch</h2><p>You can close this tab.</p></div>
    """
}
