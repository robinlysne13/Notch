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

    private var timer: Timer?
    private var lastArtworkURL: String?
    private let queue = DispatchQueue(label: "notch.media", qos: .userInitiated)

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
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
                    return
                }
                self.activeApp = lines[0]
                self.title = lines[1]
                self.artist = lines[2]
                self.isPlaying = (lines[3] == "playing")
                self.hasTrack = true
                let art = lines.count >= 5 ? lines[4] : ""
                self.loadArtwork(urlString: art)
            }
        }
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
    /// Output is 5 linefeed-separated fields: app, title, artist, state, artworkURL.
    private static let readScript = """
    set lf to (ASCII character 10)
    set out to ""
    if application "Spotify" is running then
        tell application "Spotify"
            try
                set pstate to player state as text
                if pstate is not "stopped" then
                    set out to "Spotify" & lf & (name of current track) & lf & (artist of current track) & lf & pstate & lf & (artwork url of current track)
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
                        set out to "Music" & lf & (name of current track) & lf & (artist of current track) & lf & pstate & lf
                    end if
                end try
            end tell
        end if
    end if
    return out
    """
}
