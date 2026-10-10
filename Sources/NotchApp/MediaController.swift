import AppKit
import Combine
import OSLog

/// What one source currently reports.
struct MediaSnapshot {
    var title: String
    var artist: String
    var isPlaying: Bool
    var artworkURL: String
    /// Seconds; nil when the source can't say.
    var position: Double?
    var duration: Double
    /// Shown under the artist: "Spotify · Kitchen", "Sonos · Family Room", "Music".
    var label: String
}

enum MediaSourceKind {
    case spotifyAPI
    case sonos
    case local
}

/// Reads and controls "Now Playing" from every enabled source and shows the one that is actually
/// playing: the Spotify account (any Spotify Connect device), Sonos speakers on the LAN (music
/// started from the Sonos app), and the Spotify or Music app on this Mac. With nothing playing
/// anywhere, a paused source is shown; with none of those, nothing. Controls go to the shown one.
@MainActor
final class MediaController: ObservableObject {
    @Published var title: String = ""
    @Published var artist: String = ""
    @Published var isPlaying: Bool = false
    @Published var hasTrack: Bool = false
    @Published var activeApp: String = ""
    @Published var artwork: NSImage?
    /// Elapsed seconds into the current track, interpolated between polls so the bar moves smoothly.
    @Published var position: Double = 0
    @Published var duration: Double = 0

    private let spotify: SpotifyAuth
    private let spotifyPlayer: SpotifyPlayer
    private let sonos: SonosController
    private let local = LocalPlayerSource()
    private var subscriptions: Set<AnyCancellable> = []

    private var timer: Timer?
    private var ticker: Timer?
    private var poll: Task<Void, Never>?
    private var lastArtworkURL: String?
    /// Position last read from the player, and when it was read — the tick extrapolates from this.
    private var baseline: (position: Double, at: Date)?
    /// Ignore polled positions briefly after a seek, until the player catches up.
    private var seekGuardUntil: Date?
    /// Same for play/pause: remote players report the old state for a beat after a command.
    private var playGuardUntil: Date?
    /// Which source the notch is showing, so controls reach the right player and the view can
    /// offer source-specific extras (Sonos grouping).
    @Published private(set) var activeSource: MediaSourceKind?
    private var spotifyFailures = 0
    private var lastSpotifySnapshot: MediaSnapshot?
    private var lastNote = ""

    init(spotify: SpotifyAuth, sonos: SonosController) {
        self.spotify = spotify
        self.spotifyPlayer = SpotifyPlayer(auth: spotify)
        self.sonos = sonos
        // A source switching on or off mid-track shouldn't leave its state on screen until the
        // next poll; drop it and read fresh.
        spotify.$isConnected.dropFirst().removeDuplicates()
            .merge(with: sonos.$isEnabled.dropFirst().removeDuplicates())
            .sink { [weak self] _ in
                self?.lastSpotifySnapshot = nil
                self?.clear()
                self?.refresh()
            }
            .store(in: &subscriptions)
    }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        guard isPlaying, duration > 0, let baseline else { return }
        position = min(baseline.position + Date().timeIntervalSince(baseline.at), duration)
    }

    // MARK: Reading

    private func refresh() {
        // A slow source shouldn't stack polls behind it.
        guard poll == nil else { return }
        poll = Task { [weak self] in
            defer { self?.poll = nil }
            guard let self else { return }
            async let fromSpotify: MediaSnapshot? = spotify.isConnected ? spotifySnapshot() : nil
            async let fromSonos: MediaSnapshot? = sonos.isEnabled ? sonos.snapshot() : nil
            async let fromLocal: MediaSnapshot? = local.snapshot()
            let candidates: [(MediaSourceKind, MediaSnapshot?)] = [
                (.spotifyAPI, await fromSpotify),
                (.sonos, await fromSonos),
                (.local, await fromLocal),
            ]
            let available = candidates.compactMap { kind, snapshot in snapshot.map { (kind, $0) } }
            guard let (kind, snapshot) = available.first(where: { $0.1.isPlaying }) ?? available.first else {
                note("nothing playing on any source")
                activeSource = nil
                clear()
                return
            }
            note("\(snapshot.isPlaying ? "playing" : "paused") via \(snapshot.label): \(snapshot.title)")
            activeSource = kind
            apply(snapshot)
        }
    }

    /// The Spotify API's view, holding the last good reading through a few transient failures
    /// (offline, rate-limited, token mid-refresh) rather than flashing "Nothing playing".
    private func spotifySnapshot() async -> MediaSnapshot? {
        do {
            guard let state = try await spotifyPlayer.state() else {
                spotifyFailures = 0
                lastSpotifySnapshot = nil
                return nil
            }
            spotifyFailures = 0
            let snapshot = MediaSnapshot(
                title: state.title,
                artist: state.artist,
                isPlaying: state.isPlaying,
                artworkURL: state.artworkURL,
                position: state.position,
                duration: state.duration,
                label: state.device.isEmpty ? "Spotify" : "Spotify · \(state.device)"
            )
            lastSpotifySnapshot = snapshot
            return snapshot
        } catch {
            spotifyFailures += 1
            note("Spotify poll failed: \(error.localizedDescription)")
            if spotifyFailures >= 3 || !spotify.isConnected { lastSpotifySnapshot = nil }
            return lastSpotifySnapshot
        }
    }

    /// Logs each change in what is shown, so the unified log (subsystem com.robin.notch)
    /// explains a "Nothing playing" without a debugger attached.
    private func note(_ line: String) {
        guard line != lastNote else { return }
        lastNote = line
        spotifyLog.notice("\(line, privacy: .public)")
    }

    private func clear() {
        hasTrack = false
        isPlaying = false
        activeApp = ""
        artwork = nil
        lastArtworkURL = nil
        position = 0
        duration = 0
        baseline = nil
    }

    private func apply(_ snapshot: MediaSnapshot) {
        activeApp = snapshot.label
        title = snapshot.title
        artist = snapshot.artist
        if let guardUntil = playGuardUntil, Date() < guardUntil {
            // Keep the optimistic value until the player has caught up.
        } else {
            playGuardUntil = nil
            isPlaying = snapshot.isPlaying
        }
        hasTrack = true
        loadArtwork(urlString: snapshot.artworkURL)
        applyTiming(position: snapshot.position, duration: snapshot.duration)
    }

    private func applyTiming(position: Double?, duration: Double) {
        self.duration = max(duration, 0)
        // A just-issued seek hasn't necessarily landed in the player yet; keep our own value.
        if let guardUntil = seekGuardUntil, Date() < guardUntil { return }
        seekGuardUntil = nil
        guard let position, self.duration > 0 else {
            if self.duration <= 0 { baseline = nil; self.position = 0 }
            return
        }
        let clamped = min(max(position, 0), self.duration)
        baseline = (clamped, Date())
        self.position = clamped
    }

    private func loadArtwork(urlString: String) {
        guard !urlString.isEmpty, urlString.hasPrefix("http") else {
            if !urlString.hasPrefix("http") { artwork = nil }
            return
        }
        guard urlString != lastArtworkURL else { return }
        lastArtworkURL = urlString
        guard let url = URL(string: urlString) else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, let image = NSImage(data: data) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.artwork = image }
            }
        }.resume()
    }

    // MARK: Controls

    func playPause() {
        let wasPlaying = isPlaying
        switch activeSource {
        case .spotifyAPI:
            optimisticToggle(wasPlaying)
            remoteCommand { [spotifyPlayer] in
                if wasPlaying { try await spotifyPlayer.pause() } else { try await spotifyPlayer.play() }
            }
        case .sonos:
            optimisticToggle(wasPlaying)
            remoteCommand { [sonos] in
                if wasPlaying { try await sonos.pause() } else { try await sonos.play() }
            }
        case .local, nil:
            localCommand("playpause")
        }
    }

    func next() {
        switch activeSource {
        case .spotifyAPI: remoteCommand { [spotifyPlayer] in try await spotifyPlayer.next() }
        case .sonos: remoteCommand { [sonos] in try await sonos.next() }
        case .local, nil: localCommand("next track")
        }
    }

    func previous() {
        switch activeSource {
        case .spotifyAPI: remoteCommand { [spotifyPlayer] in try await spotifyPlayer.previous() }
        case .sonos: remoteCommand { [sonos] in try await sonos.previous() }
        case .local, nil: localCommand("previous track")
        }
    }

    /// Scrub to `seconds`. Optimistically moves the bar so dragging feels immediate.
    func seek(to seconds: Double) {
        guard duration > 0 else { return }
        let target = min(max(seconds, 0), duration)
        position = target
        baseline = (target, Date())
        seekGuardUntil = Date().addingTimeInterval(1.5)
        switch activeSource {
        case .spotifyAPI: remoteCommand { [spotifyPlayer] in try await spotifyPlayer.seek(to: target) }
        case .sonos: remoteCommand { [sonos] in try await sonos.seek(to: target) }
        case .local, nil: local.seek(to: target, app: localApp)
        }
    }

    /// Flip the button immediately so it doesn't lag the click by a network round trip.
    private func optimisticToggle(_ wasPlaying: Bool) {
        isPlaying = !wasPlaying
        playGuardUntil = Date().addingTimeInterval(1.5)
        if !wasPlaying { baseline = (position, Date()) }
    }

    /// Runs a network command, then re-reads once the player has had a moment to apply it.
    private func remoteCommand(_ operation: @escaping @MainActor () async throws -> Void) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await operation()
            } catch {
                spotifyLog.error("command failed: \(error.localizedDescription, privacy: .public)")
                if case SpotifyError.premiumRequired = error {
                    spotify.lastError = error.localizedDescription
                }
            }
            try? await Task.sleep(for: .milliseconds(600))
            refresh()
        }
    }

    private func localCommand(_ command: String) {
        local.control(command, app: localApp)
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            self?.refresh()
        }
    }

    /// The scripted player's name while it is the one showing; otherwise let the source pick.
    private var localApp: String? {
        activeSource == .local && !activeApp.isEmpty ? activeApp : nil
    }
}
