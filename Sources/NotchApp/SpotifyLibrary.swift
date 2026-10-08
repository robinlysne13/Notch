import Combine
import Foundation

/// Reads and writes "Liked Songs" through the Spotify Web API.
///
/// This is the one thing AppleScript cannot do: Spotify's dictionary exposes `starred` read-only
/// and has no save command, because liking writes to the account rather than to the local player.
@MainActor
final class SpotifyLibrary: ObservableObject {
    enum LikeState: Equatable {
        /// Not looked up yet, or there is nothing to look up.
        case unknown
        case liked
        case notLiked
    }

    @Published private(set) var state: LikeState = .unknown
    @Published private(set) var isBusy = false
    /// Surfaced in the notch so a failed like isn't silent.
    @Published private(set) var lastError: String?

    private let auth: SpotifyAuth
    private var trackID = ""
    private var lookup: Task<Void, Never>?

    init(auth: SpotifyAuth) {
        self.auth = auth
    }

    /// Point at a track. Safe to call repeatedly; only a change does any work.
    func follow(trackID: String) {
        guard trackID != self.trackID else { return }
        self.trackID = trackID
        lookup?.cancel()
        state = .unknown
        lastError = nil
        guard !trackID.isEmpty, auth.isConnected else { return }

        lookup = Task { [weak self] in
            guard let self else { return }
            do {
                let liked = try await self.contains(trackID: trackID)
                guard !Task.isCancelled, self.trackID == trackID else { return }
                self.state = liked ? .liked : .notLiked
            } catch {
                guard !Task.isCancelled, self.trackID == trackID else { return }
                // A failed lookup leaves the heart blank rather than claiming "not liked".
                self.state = .unknown
            }
        }
    }

    /// Like the playing track, or unlike it if it is already liked.
    func toggle() async {
        let trackID = self.trackID
        guard !trackID.isEmpty, !isBusy else { return }
        isBusy = true
        lastError = nil
        defer { isBusy = false }

        // Flip immediately — a like should feel instant — and put it back if the call fails.
        let previous = state
        let liking = state != .liked
        state = liking ? .liked : .notLiked

        do {
            try await write(trackID: trackID, liking: liking)
        } catch {
            guard self.trackID == trackID else { return }
            state = previous
            lastError = (error as? LocalizedError)?.errorDescription ?? "Couldn't reach Spotify."
        }
    }

    // MARK: API

    private func contains(trackID: String) async throws -> Bool {
        let data = try await send(
            path: "/v1/me/tracks/contains",
            method: "GET",
            trackID: trackID
        )
        return try JSONDecoder().decode([Bool].self, from: data).first ?? false
    }

    private func write(trackID: String, liking: Bool) async throws {
        _ = try await send(
            path: "/v1/me/tracks",
            method: liking ? "PUT" : "DELETE",
            trackID: trackID
        )
    }

    private func send(path: String, method: String, trackID: String) async throws -> Data {
        let token = try await auth.accessToken()

        var components = URLComponents(string: "https://api.spotify.com")
        components?.path = path
        components?.queryItems = [URLQueryItem(name: "ids", value: trackID)]
        guard let url = components?.url else {
            throw SpotifyAuthError.tokenRequestFailed("bad request URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SpotifyAuthError.tokenRequestFailed("no response")
        }
        // 200 for the lookup, 200/201 for a write — Spotify isn't consistent, so accept the range.
        guard (200...299).contains(http.statusCode) else {
            throw SpotifyAuthError.tokenRequestFailed(Self.describe(status: http.statusCode))
        }
        return data
    }

    private static func describe(status: Int) -> String {
        switch status {
        case 401: "Spotify sign-in expired — reconnect in settings."
        case 403: "This Spotify account isn't allowed to change the library."
        case 429: "Spotify is rate-limiting; try again in a moment."
        default: "Spotify returned \(status)."
        }
    }
}
