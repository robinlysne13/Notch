import AppKit
import Combine

/// Reads and controls "Now Playing" from Spotify or Music via AppleScript.
/// (Apple restricts the private MediaRemote framework to signed system apps, so scripting the
/// player apps directly is the reliable third-party path. First run prompts for Automation access.)
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

    private var timer: Timer?
    private var ticker: Timer?
    private var lastArtworkURL: String?
    /// Position last read from the player, and when it was read — the tick extrapolates from this.
    private var baseline: (position: Double, at: Date)?
    /// Ignore polled positions briefly after a seek, until the player catches up.
    private var seekGuardUntil: Date?
    private let queue = DispatchQueue(label: "notch.media", qos: .userInitiated)

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.tick()
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
        queue.async { [weak self] in
            guard let self else { return }
            let raw = self.runAppleScript(Self.readScript) ?? ""
            let lines = raw.components(separatedBy: "\n")
            DispatchQueue.main.async {
                guard lines.count >= 4, !lines[0].isEmpty else {
                    self.hasTrack = false
                    self.isPlaying = false
                    self.activeApp = ""
                    self.artwork = nil
                    self.lastArtworkURL = nil
                    self.position = 0
                    self.duration = 0
                    self.baseline = nil
                    return
                }
                self.activeApp = lines[0]
                self.title = lines[1]
                self.artist = lines[2]
                self.isPlaying = (lines[3] == "playing")
                self.hasTrack = true
                let art = lines.count >= 5 ? lines[4] : ""
                self.loadArtwork(urlString: art)
                self.applyTiming(
                    position: lines.count >= 6 ? Self.number(lines[5]) : nil,
                    duration: lines.count >= 7 ? Self.number(lines[6]) : nil
                )
            }
        }
    }

    private func applyTiming(position: Double?, duration: Double?) {
        self.duration = max(duration ?? 0, 0)
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
        guard duration > 0 else { return }
        let target = min(max(seconds, 0), duration)
        position = target
        baseline = (target, Date())
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
    /// Output is 7 linefeed-separated fields: app, title, artist, state, artworkURL, position, duration.
    /// Position and duration are both normalized to seconds (Spotify reports duration in milliseconds).
    private static let readScript = """
    set lf to (ASCII character 10)
    set out to ""
    if application "Spotify" is running then
        tell application "Spotify"
            try
                set pstate to player state as text
                if pstate is not "stopped" then
                    set out to "Spotify" & lf & (name of current track) & lf & (artist of current track) & lf & pstate & lf & (artwork url of current track) & lf & (player position as text) & lf & (((duration of current track) / 1000) as text)
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
                        set out to "Music" & lf & (name of current track) & lf & (artist of current track) & lf & pstate & lf & lf & (player position as text) & lf & ((duration of current track) as text)
                    end if
                end try
            end tell
        end if
    end if
    return out
    """
}
