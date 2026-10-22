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
    private static let retryDelay: Double = 1.5

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
            var result = await Self.fetch(
                title: title,
                artist: artist,
                duration: duration,
                session: self.session,
            )
            // LRCLIB sheds load with a 503 often enough that one retry is worth the wait before
            // telling someone their track has no lyrics.
            if !result.isSettled {
                try? await Task.sleep(nanoseconds: UInt64(Self.retryDelay * 1_000_000_000))
                guard !Task.isCancelled, self.loadedKey == key else { return }
                result = await Self.fetch(
                    title: title,
                    artist: artist,
                    duration: duration,
                    session: self.session,
                )
            }
            guard !Task.isCancelled, self.loadedKey == key else { return }
            if result.isSettled {
                self.remember(key: key, result: (result.status, result.lines))
            } else {
                // Never remember a verdict LRCLIB didn't actually give. Dropping the key as well
                // means the next look at the panel asks again instead of trusting the failure.
                self.loadedKey = nil
            }
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

    /// What a lookup came back with. "LRCLIB says this track has no lyrics" and "LRCLIB never
    /// answered" both leave the panel empty, but only the first is worth remembering — which is
    /// why they are kept apart here rather than both collapsing into `.unavailable`.
    private struct Outcome {
        let status: Status
        let lines: [LyricLine]
        /// True when LRCLIB answered. A failed request leaves this false, and an unsettled
        /// outcome is neither cached nor allowed to stick.
        let isSettled: Bool
    }

    private static func fetch(
        title: String,
        artist: String,
        duration: Double,
        session: URLSession,
    ) async -> Outcome {
        // An exact match needs the duration to agree within a couple of seconds, which fails on
        // live or remastered cuts; the search endpoint is the looser second attempt.
        //
        // The exact match wins only when it carries timings. Timings are the whole point of the
        // panel, and plenty of tracks have an untimed sheet filed at the exact duration while a
        // timed one sits under a different copy of the same song — so anything less than synced
        // is held back as a fallback while the search endpoint is asked for something better.
        var exact: Outcome?

        switch await get(title: title, artist: artist, duration: duration, session: session) {
        case .ok(let track):
            let found = interpret(track)
            // Synced is as good as it gets, and instrumental is a settled fact about the track
            // rather than a gap in the sheet — looking further would only find a mislabelled one.
            if found.status == .synced || found.status == .instrumental {
                return Outcome(status: found.status, lines: found.lines, isSettled: true)
            }
            exact = Outcome(status: found.status, lines: found.lines, isSettled: true)
        case .empty, .failed:
            break
        }

        switch await search(title: title, artist: artist, duration: duration, session: session) {
        case .ok(let track):
            let found = interpret(track)
            if found.status == .synced {
                return Outcome(status: found.status, lines: found.lines, isSettled: true)
            }
            // No timings anywhere; the exact match is the better of two untimed answers.
            return exact ?? Outcome(status: found.status, lines: found.lines, isSettled: true)
        case .empty:
            return exact ?? Outcome(status: .unavailable, lines: [], isSettled: true)
        case .failed:
            // The panel still has to say something, but with the looser attempt unanswered this
            // verdict is a guess — including a plain sheet that a later look might upgrade — so
            // it is marked unsettled and asked again rather than remembered.
            return Outcome(
                status: exact?.status ?? .unavailable,
                lines: exact?.lines ?? [],
                isSettled: false
            )
        }
    }

    private static func get(
        title: String,
        artist: String,
        duration: Double,
        session: URLSession,
    ) async -> Reply<Track> {
        var query = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist),
        ]
        if duration > 0 {
            query.append(URLQueryItem(name: "duration", value: String(Int(duration.rounded()))))
        }
        return await request(path: "/api/get", query: query, session: session)
    }

    private static func search(
        title: String,
        artist: String,
        duration: Double,
        session: URLSession,
    ) async -> Reply<Track> {
        let query = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist),
        ]
        let results: Reply<[Track]> = await request(path: "/api/search", query: query, session: session)
        switch results {
        case .ok(let tracks):
            return pick(from: tracks, duration: duration).map { .ok($0) } ?? .empty
        case .empty:
            return .empty
        case .failed:
            return .failed
        }
    }

    /// The copy of a song whose sheet is worth showing.
    ///
    /// The search endpoint takes no duration and lists every copy LRCLIB holds — the album cut, a
    /// video rip, a sped-up edit — in no particular order. Stamps belong to one recording, so
    /// taking the first timed hit is how a sheet from a cut twenty seconds shorter gets shown: the
    /// words are right, which is why it looks like it is working, and the highlight falls further
    /// behind with every line. The copy whose length matches the track is the one whose stamps
    /// mean anything.
    ///
    /// When no timed copy is this recording, the words are still the words — so the closest sheet
    /// is kept with its timings dropped. A sheet that scrolls and admits it cannot follow is
    /// better than one that confidently points at the wrong line.
    private static func pick(from tracks: [Track], duration: Double) -> Track? {
        guard duration > 0 else {
            return tracks.first { $0.syncedLyrics?.isEmpty == false } ?? tracks.first
        }
        let candidates = tracks.map {
            (duration: $0.duration, isTimed: $0.syncedLyrics?.isEmpty == false)
        }
        if let match = timedMatch(among: candidates, trackDuration: duration) {
            return tracks[match]
        }
        let closest = tracks.min {
            abs(($0.duration ?? 0) - duration) < abs(($1.duration ?? 0) - duration)
        }
        return (closest ?? tracks.first)?.untimed
    }

    /// How far a copy's length may sit from the playing track and still be the same recording.
    /// Wide enough for rounding and a remaster, far tighter than the gap between a cut and an edit.
    nonisolated static var durationTolerance: Double { 4 }

    /// Index of the timed copy whose length best matches `trackDuration`, or nil when none of them
    /// is close enough to be the same recording.
    nonisolated static func timedMatch(
        among candidates: [(duration: Double?, isTimed: Bool)],
        trackDuration: Double
    ) -> Int? {
        func gap(_ index: Int) -> Double { abs((candidates[index].duration ?? 0) - trackDuration) }
        return candidates.indices
            .filter { candidates[$0].isTimed && gap($0) <= durationTolerance }
            .min { gap($0) < gap($1) }
    }

    /// Whether LRCLIB answered, and what it said. The distinction matters because a `.failed`
    /// lookup must not be mistaken for "this track has no lyrics".
    private enum Reply<T> {
        case ok(T)
        /// LRCLIB answered and has nothing for this track.
        case empty
        /// Offline, rate-limited, or LRCLIB shedding load — no answer at all.
        case failed
    }

    private static func request<T: Decodable>(
        path: String,
        query: [URLQueryItem],
        session: URLSession,
    ) async -> Reply<T> {
        var components = URLComponents(string: "https://lrclib.net")
        components?.path = path
        components?.queryItems = query
        guard let url = components?.url else { return .failed }

        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failed }
            switch http.statusCode {
            case 200:
                guard let decoded = try? JSONDecoder().decode(T.self, from: data) else { return .failed }
                return .ok(decoded)
            case 404:
                // LRCLIB's "nothing here" — an answer, just not a useful one.
                return .empty
            default:
                // 429 and 503 land here: LRCLIB sheds load under traffic, and treating that as
                // "no lyrics" is what used to leave a track blank for the rest of the session.
                return .failed
            }
        } catch {
            // Offline, timed out, or cancelled.
            return .failed
        }
    }

    private struct Track: Decodable {
        /// The length of this copy, in seconds — what says whether its stamps are this recording's.
        let duration: Double?
        let instrumental: Bool?
        let plainLyrics: String?
        let syncedLyrics: String?

        /// The same sheet with its stamps dropped, for when they belong to another cut.
        var untimed: Track {
            Track(
                duration: duration,
                instrumental: instrumental,
                plainLyrics: plainLyrics,
                syncedLyrics: nil
            )
        }
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
