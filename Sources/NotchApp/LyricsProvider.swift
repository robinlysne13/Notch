import Combine
import Foundation

/// One lyric line and the moment it starts. Lines with empty `text` are the gaps an LRC file
/// leaves for intros and instrumental breaks — kept, because the highlight resting on a gap is
/// what tells you the singing has stopped.
struct LyricLine: Equatable {
    let time: Double
    let text: String

    var isGap: Bool { text.isEmpty }
}

/// Fetches time-synced lyrics for the playing track from LRCLIB (lrclib.net): a free, keyless
/// community lyrics API. Nothing is bundled with the app — a track's lyrics are requested the
/// first time it plays and then held in memory for the session.
@MainActor
final class LyricsProvider: ObservableObject {
    enum Status: Equatable {
        case idle
        case loading
        /// Timestamped lines — these can follow the playhead.
        case synced
        /// Only an unsynced lyric sheet exists, so it scrolls but cannot highlight.
        case plain
        case instrumental
        case unavailable
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var lines: [LyricLine] = []

    /// The track `lines` belongs to, so a late response for a skipped track can be dropped.
    private var loadedKey: String?
    private var inFlight: Task<Void, Never>?
    private var cache: [String: (status: Status, lines: [LyricLine])] = [:]
    private let session: URLSession

    /// LRCLIB asks clients to identify themselves rather than send a browser string.
    private static let userAgent = "Notch/1.0 (https://github.com/robinlysne/Notch)"
    private static let cacheLimit = 64

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Point the provider at a track. Safe to call on every poll — repeat calls for the track
    /// already loaded or in flight do nothing.
    func load(title: String, artist: String, duration: Double) {
        let key = Self.cacheKey(title: title, artist: artist)
        guard !title.isEmpty, key != loadedKey else { return }

        inFlight?.cancel()
        loadedKey = key

        if let hit = cache[key] {
            status = hit.status
            lines = hit.lines
            return
        }

        status = .loading
        lines = []
        inFlight = Task { [weak self] in
            guard let self else { return }
            let result = await Self.fetch(
                title: title,
                artist: artist,
                duration: duration,
                session: self.session,
            )
            guard !Task.isCancelled, self.loadedKey == key else { return }
            self.remember(key: key, result: result)
            self.status = result.status
            self.lines = result.lines
        }
    }

    /// Clear when playback stops, so the next track starts from a blank panel.
    func clear() {
        inFlight?.cancel()
        inFlight = nil
        loadedKey = nil
        status = .idle
        lines = []
    }

    private func remember(key: String, result: (status: Status, lines: [LyricLine])) {
        // A session-lifetime cache; dropping everything at the cap keeps it to a few lines of
        // code, and refetching a handful of tracks costs nothing noticeable.
        if cache.count >= Self.cacheLimit { cache.removeAll() }
        cache[key] = result
    }

    private static func cacheKey(title: String, artist: String) -> String {
        "\(artist.lowercased())\u{1F}\(title.lowercased())"
    }

    // MARK: Fetching

    private static func fetch(
        title: String,
        artist: String,
        duration: Double,
        session: URLSession,
    ) async -> (status: Status, lines: [LyricLine]) {
        // An exact match needs the duration to agree within a couple of seconds, which fails on
        // live or remastered cuts; the search endpoint is the looser second attempt.
        if let track = await get(title: title, artist: artist, duration: duration, session: session) {
            return interpret(track)
        }
        if let track = await search(title: title, artist: artist, session: session) {
            return interpret(track)
        }
        return (.unavailable, [])
    }

    private static func get(
        title: String,
        artist: String,
        duration: Double,
        session: URLSession,
    ) async -> Track? {
        var query = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist),
        ]
        if duration > 0 {
            query.append(URLQueryItem(name: "duration", value: String(Int(duration.rounded()))))
        }
        let tracks: [Track]? = await request(path: "/api/get", query: query, session: session)
            .map { [$0] }
        return tracks?.first
    }

    private static func search(
        title: String,
        artist: String,
        session: URLSession,
    ) async -> Track? {
        let query = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist),
        ]
        let results: [Track]? = await request(path: "/api/search", query: query, session: session)
        // Prefer a hit that actually carries timings over the first one listed.
        return results?.first { $0.syncedLyrics?.isEmpty == false } ?? results?.first
    }

    private static func request<T: Decodable>(
        path: String,
        query: [URLQueryItem],
        session: URLSession,
    ) async -> T? {
        var components = URLComponents(string: "https://lrclib.net")
        components?.path = path
        components?.queryItems = query
        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            // Offline, rate-limited or no match — all of them just mean "no lyrics to show".
            return nil
        }
    }

    private struct Track: Decodable {
        let instrumental: Bool?
        let plainLyrics: String?
        let syncedLyrics: String?
    }

    private static func interpret(_ track: Track) -> (status: Status, lines: [LyricLine]) {
        if track.instrumental == true { return (.instrumental, []) }
        if let synced = track.syncedLyrics, !synced.isEmpty {
            let lines = parseLRC(synced)
            if !lines.isEmpty { return (.synced, lines) }
        }
        if let plain = track.plainLyrics, !plain.isEmpty {
            let lines = plain
                .components(separatedBy: .newlines)
                .map { LyricLine(time: 0, text: $0.trimmingCharacters(in: .whitespaces)) }
            if lines.contains(where: { !$0.isGap }) { return (.plain, lines) }
        }
        return (.unavailable, [])
    }

    // MARK: LRC parsing

    /// Parse an LRC lyric sheet into lines ordered by time.
    ///
    /// Handles the parts of the format that turn up in practice: `[mm:ss]`, `[mm:ss.xx]` and
    /// `[mm:ss.xxx]` stamps, several stamps on one line (a repeated chorus), an `[offset:±ms]`
    /// correction, and `[ar:]`-style metadata tags, which are skipped.
    nonisolated static func parseLRC(_ source: String) -> [LyricLine] {
        var lines: [LyricLine] = []
        var offset: Double = 0

        for raw in source.components(separatedBy: .newlines) {
            var rest = Substring(raw)
            var stamps: [Double] = []

            // Stamps and tags only ever come before the text, so stop at the first other token.
            while rest.first == "[", let close = rest.firstIndex(of: "]") {
                let token = rest[rest.index(after: rest.startIndex)..<close]
                if let time = parseStamp(token) {
                    stamps.append(time)
                } else if let value = parseOffsetTag(token) {
                    offset = value
                } else if !isMetadataTag(token) {
                    break
                }
                rest = rest[rest.index(after: close)...]
            }

            guard !stamps.isEmpty else { continue }
            let text = rest.trimmingCharacters(in: .whitespaces)
            for stamp in stamps {
                lines.append(LyricLine(time: max(stamp + offset, 0), text: text))
            }
        }

        return lines.sorted { $0.time < $1.time }
    }

    nonisolated private static func parseStamp(_ token: Substring) -> Double? {
        let parts = token.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let minutes = Int(parts[0]),
              minutes >= 0
        else { return nil }
        // Some writers use a comma for the fractional separator.
        let seconds = Double(parts[1].replacingOccurrences(of: ",", with: "."))
        guard let seconds, seconds >= 0 else { return nil }
        return Double(minutes) * 60 + seconds
    }

    /// `[offset:+500]` shifts every stamp, in milliseconds, positive meaning later.
    nonisolated private static func parseOffsetTag(_ token: Substring) -> Double? {
        let parts = token.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "offset" else { return nil }
        let value = parts[1].trimmingCharacters(in: .whitespaces)
        guard let milliseconds = Double(value.hasPrefix("+") ? String(value.dropFirst()) : value)
        else { return nil }
        return milliseconds / 1000
    }

    nonisolated private static func isMetadataTag(_ token: Substring) -> Bool {
        guard let colon = token.firstIndex(of: ":") else { return false }
        let name = token[token.startIndex..<colon]
        return !name.isEmpty && name.allSatisfy { $0.isLetter }
    }

    // MARK: Following the playhead

    /// Index of the line being sung at `position`, or nil before the first line starts.
    ///
    /// Lines are sorted, so this is a binary search — it runs on every UI tick.
    nonisolated static func index(at position: Double, in lines: [LyricLine]) -> Int? {
        guard let first = lines.first, position >= first.time else { return nil }
        var low = 0
        var high = lines.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lines[mid].time <= position {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return low
    }
}
