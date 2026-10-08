import AppKit
import Combine

/// Reads and controls "Now Playing" from Spotify or Music via AppleScript.
/// (Apple restricts the private MediaRemote framework to signed system apps, so scripting the
/// player apps directly is the reliable third-party path. First run prompts for Automation access.)
///
/// Two sources feed the playhead, because the lyrics are only as right as it is:
///   - the players' own broadcasts, which arrive the instant playback starts, stops or changes
///     track, Spotify's carrying the playhead with them;
///   - a poll every two seconds, which catches everything a broadcast misses (a seek, Music's
///     missing position, a player started before the app) and corrects drift.
/// `Playhead` reconciles the two and runs the clock in between.
final class MediaController: ObservableObject {
    @Published var title: String = ""
    @Published var artist: String = ""
    @Published var isPlaying: Bool = false
    @Published var hasTrack: Bool = false
    @Published var activeApp: String = ""
    @Published var artwork: NSImage?
    /// Spotify's id for the playing track, bare (no `spotify:track:` prefix). Empty for Music,
    /// which has no equivalent the Web API can address.
    @Published var trackID: String = ""
    /// Elapsed seconds into the current track, kept in step with the player by `Playhead`.
    @Published var position: Double = 0
    @Published var duration: Double = 0

    private var playhead = Playhead()
    private var timer: Timer?
    private var ticker: Timer?
    private var eventTokens: [NSObjectProtocol] = []
    private var pendingEventRead: DispatchWorkItem?
    private var lastArtworkURL: String?
    /// Ignore polled positions briefly after a seek, until the player catches up.
    private var seekGuardUntil: Date?
    /// When the player last told us something itself. A poll that was sent before that is
    /// describing the track that was playing beforehand, and gets dropped rather than applied.
    private var lastEventAt: Date?
    private let queue = DispatchQueue(label: "notch.media", qos: .userInitiated)

    /// Spotify posts this the moment playback starts, stops or moves to another track. The
    /// payload carries `Player State`, `Playback Position` in seconds and `Duration` in
    /// milliseconds — a reading with no round trip behind it, which is as close to the truth as
    /// this app can get.
    private static let spotifyEvent = Notification.Name("com.spotify.client.PlaybackStateChanged")
    /// Music's equivalent. It names the track and the state but never the position, so it serves
    /// as a prompt to go and read the playhead rather than as a reading of it.
    private static let musicEvent = Notification.Name("com.apple.Music.playerInfo")
    /// Spotify posts several events in a row when a track changes; the follow-up read waits this
    /// long for them to settle so one track change costs one read.
    private static let eventReadDelay: Double = 0.3

    func start() {
        observePlayerEvents()
        refresh()
        // Both timers go on in .common rather than the default mode. The panel is only visible
        // while the pointer is inside it, which is exactly when AppKit is apt to be spinning a
        // tracking run loop — scrolling the lyrics, scrubbing the bar, holding a button down.
        // A default-mode timer stops firing for the whole of such a loop, which freezes the
        // playhead and with it the lyric that rides on it.
        timer = schedule(every: 2.0) { $0.refresh() }
        // The lyric highlight can only land as precisely as this tick is fine.
        ticker = schedule(every: 0.1) { $0.tick() }
    }

    private func schedule(every interval: TimeInterval, _ body: @escaping (MediaController) -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            body(self)
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        ticker?.invalidate()
        ticker = nil
        pendingEventRead?.cancel()
        pendingEventRead = nil
        let center = DistributedNotificationCenter.default()
        eventTokens.forEach(center.removeObserver)
        eventTokens = []
    }

    private func tick() {
        guard playhead.isPlaying, playhead.isAnchored else { return }
        playhead.advance(to: Date())
        publish()
    }

    /// Mirror the playhead onto the published properties the views watch. The comparisons keep an
    /// unchanged value from invalidating those views ten times a second.
    private func publish() {
        if abs(position - playhead.position) > 0.005 { position = playhead.position }
        if duration != playhead.duration { duration = playhead.duration }
        if isPlaying != playhead.isPlaying { isPlaying = playhead.isPlaying }
    }

    // MARK: Player broadcasts

    private func observePlayerEvents() {
        let center = DistributedNotificationCenter.default()
        for name in [Self.spotifyEvent, Self.musicEvent] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                self?.handle(note)
            }
            eventTokens.append(token)
        }
    }

    /// Apply a player broadcast. `Date()` here is the event's own moment, so unlike a poll there
    /// is no latency to undo.
    private func handle(_ note: Notification) {
        let at = Date()
        let info = note.userInfo ?? [:]
        let state = (info["Player State"] as? String) ?? ""

        // Spotify is the preferred player whenever it has a track, which is what `readScript`
        // already does — so its events can be trusted straight to the UI. Music's carry no
        // playhead, and a stopped player's say nothing about what is playing instead; both of
        // those only prompt a read.
        guard note.name == Self.spotifyEvent, state == "Playing" || state == "Paused" else {
            scheduleEventRead()
            return
        }

        // The player has spoken for itself, which settles any seek still in flight and makes
        // anything already on its way back from a poll old news.
        seekGuardUntil = nil
        lastEventAt = at
        activeApp = "Spotify"
        hasTrack = true
        if let name = info["Name"] as? String, !name.isEmpty { title = name }
        if let artist = info["Artist"] as? String { self.artist = artist }
        if let id = info["Track ID"] as? String { trackID = Self.spotifyID(id) }
        // Duration first: it is what bounds the position that follows.
        if let milliseconds = (info["Duration"] as? NSNumber)?.doubleValue, milliseconds > 0 {
            playhead.setDuration(milliseconds / 1000)
        }
        playhead.setPlaying(state == "Playing", at: at)
        if let reported = (info["Playback Position"] as? NSNumber)?.doubleValue {
            playhead.snap(to: reported, at: at)
        }
        publish()
        // Artwork, and anything else the payload leaves out, still comes from a read.
        scheduleEventRead()
    }

    private func scheduleEventRead() {
        pendingEventRead?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        pendingEventRead = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.eventReadDelay, execute: work)
    }

    // MARK: Reading

    private func refresh() {
        queue.async { [weak self] in
            guard let self else { return }
            let sentAt = Date()
            let raw = self.runAppleScript(Self.readScript) ?? ""
            let sampledAt = Self.sampleInstant(sentAt: sentAt, receivedAt: Date())
            let lines = raw.components(separatedBy: "\n")
            DispatchQueue.main.async {
                // A reading the player has already superseded would otherwise put the previous
                // track's title and playhead back for as long as it takes to poll again.
                if let lastEventAt = self.lastEventAt, sentAt < lastEventAt { return }
                guard lines.count >= 4, !lines[0].isEmpty else {
                    self.hasTrack = false
                    self.activeApp = ""
                    self.artwork = nil
                    self.lastArtworkURL = nil
                    self.trackID = ""
                    self.playhead.reset()
                    self.publish()
                    return
                }
                self.activeApp = lines[0]
                self.title = lines[1]
                self.artist = lines[2]
                self.hasTrack = true
                self.trackID = Self.spotifyID(lines.count >= 8 ? lines[7] : "")
                let art = lines.count >= 5 ? lines[4] : ""
                self.loadArtwork(urlString: art)
                self.applyTiming(
                    playing: lines[3] == "playing",
                    position: lines.count >= 6 ? Self.number(lines[5]) : nil,
                    duration: lines.count >= 7 ? Self.number(lines[6]) : nil,
                    sampledAt: sampledAt
                )
            }
        }
    }

    /// The instant a reading describes, which is not the instant it arrives.
    ///
    /// The player answers somewhere inside the round trip, so the midpoint is the least-wrong
    /// moment to file the reading at: it leaves at most half the trip as error instead of all of
    /// it. Measured on this machine, the trip breaks down as ~39ms to spawn `osascript`, ~87ms
    /// for the first word with Spotify, then ~10ms per property — and `readScript` asks for the
    /// position early, so the moment it describes (~134ms in) lands within a few milliseconds of
    /// the midpoint of a ~250ms trip. Keep the position early in that script and this stays true.
    private static func sampleInstant(sentAt: Date, receivedAt: Date) -> Date {
        sentAt.addingTimeInterval(receivedAt.timeIntervalSince(sentAt) / 2)
    }

    private func applyTiming(playing: Bool, position: Double?, duration: Double?, sampledAt: Date) {
        playhead.setDuration(duration ?? 0)
        // State before position, for two reasons: whether the clock is running decides how a
        // reading is read, and the state is known even when the playhead is not — Music reports
        // no duration for a live stream, and the play button still has to be right.
        playhead.setPlaying(playing, at: sampledAt)
        // A just-issued seek hasn't necessarily landed in the player yet; keep our own value.
        if let guardUntil = seekGuardUntil, Date() < guardUntil {
            publish()
            return
        }
        seekGuardUntil = nil
        if let position { playhead.observe(position: position, sampledAt: sampledAt) }
        publish()
    }

    /// Spotify reports ids as `spotify:track:<id>`; the Web API wants the bare id.
    private static func spotifyID(_ raw: String) -> String {
        raw.hasPrefix("spotify:track:") ? String(raw.dropFirst("spotify:track:".count)) : ""
    }

    /// AppleScript renders reals with the system decimal separator, which isn't always ".".
    private static func number(_ field: String) -> Double? {
        Double(field.replacingOccurrences(of: ",", with: "."))
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
            DispatchQueue.main.async { self?.artwork = image }
        }.resume()
    }

    // MARK: Controls

    func playPause() { control("playpause") }
    func next() { control("next track") }
    func previous() { control("previous track") }

    /// Scrub to `seconds`. Optimistically moves the bar so dragging feels immediate.
    func seek(to seconds: Double) {
        guard playhead.duration > 0 else { return }
        let target = min(max(seconds, 0), playhead.duration)
        playhead.snap(to: target, at: Date())
        publish()
        seekGuardUntil = Date().addingTimeInterval(1.5)
        let app = activeApp.isEmpty ? nil : activeApp
        queue.async { [weak self] in
            let target = String(format: "%.3f", target)
            let player = app ?? self?.detectRunningPlayer() ?? "Music"
            _ = self?.runAppleScript("tell application \"\(player)\" to set player position to \(target)")
        }
    }

    private func control(_ command: String) {
        let app = activeApp.isEmpty ? nil : activeApp
        queue.async { [weak self] in
            let target = app ?? self?.detectRunningPlayer() ?? "Music"
            _ = self?.runAppleScript("tell application \"\(target)\" to \(command)")
            self?.refresh()
        }
    }

    private func detectRunningPlayer() -> String? {
        let apps = NSWorkspace.shared.runningApplications.compactMap { $0.localizedName }
        if apps.contains("Spotify") { return "Spotify" }
        if apps.contains("Music") { return "Music" }
        return nil
    }

    // MARK: AppleScript

    private func runAppleScript(_ source: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Prefers Spotify if it has a track, otherwise falls back to Music.
    /// Output is 8 linefeed-separated fields: app, title, artist, state, artworkURL, position,
    /// duration, track id (Spotify only).
    /// Position and duration are both normalized to seconds (Spotify reports duration in milliseconds).
    ///
    /// The playhead is read into `ppos` before the slower track properties — the artwork URL
    /// alone costs ~65ms — so that the moment it describes sits near the middle of the round
    /// trip. `sampleInstant` depends on that order; the fields themselves stay in their old
    /// positions in the output.
    private static let readScript = """
    set lf to (ASCII character 10)
    set out to ""
    if application "Spotify" is running then
        tell application "Spotify"
            try
                set pstate to player state as text
                if pstate is not "stopped" then
                    set ppos to (player position as text)
                    set out to "Spotify" & lf & (name of current track) & lf & (artist of current track) & lf & pstate & lf & (artwork url of current track) & lf & ppos & lf & (((duration of current track) / 1000) as text) & lf & (id of current track)
                end if
            end try
        end tell
    end if
    if out is "" then
        if application "Music" is running then
            tell application "Music"
                try
                    if player state is not stopped then
                        set pstate to player state as text
                        set ppos to (player position as text)
                        set out to "Music" & lf & (name of current track) & lf & (artist of current track) & lf & pstate & lf & lf & ppos & lf & ((duration of current track) as text)
                    end if
                end try
            end tell
        end if
    end if
    return out
    """
}
