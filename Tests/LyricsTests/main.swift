import Foundation

// Pins down the LRC parsing and playhead lookup that drive the lyrics panel. Every lyric line
// below is invented filler — the real sheets are fetched at runtime and never stored in the repo.

var failures = 0
var passed = 0

func check(_ name: String, _ condition: @autoclosure () -> Bool, _ detail: @autoclosure () -> String = "") {
    if condition() {
        passed += 1
    } else {
        failures += 1
        let detail = detail()
        print("FAIL  \(name)" + (detail.isEmpty ? "" : "\n      \(detail)"))
    }
}

func checkEqual<T: Equatable>(_ name: String, _ got: T, _ expect: T) {
    check(name, got == expect, "expected \(expect), got \(got)")
}

// MARK: Stamp formats

let formats = LyricsProvider.parseLRC("""
[00:12.34]line with hundredths
[01:05.678]line with thousandths
[02:40]line with no fraction
[03:01,50]line with a comma separator
""")

checkEqual("all four stamp formats parse", formats.count, 4)
checkEqual("hundredths", formats[0].time, 12.34)
checkEqual("thousandths", formats[1].time, 65.678)
checkEqual("whole seconds", formats[2].time, 160)
checkEqual("comma separator", formats[3].time, 181.5)
checkEqual("text follows the stamp", formats[0].text, "line with hundredths")

// MARK: Metadata, gaps and repeats

let sheet = LyricsProvider.parseLRC("""
[ar:An Artist]
[ti:A Song]
[by:someone]
[00:04.00]
[00:08.00]first sung line
[00:12.00]second sung line
""")

checkEqual("metadata tags are skipped", sheet.count, 3)
check("blank stamped line is kept as a gap", sheet[0].isGap)
check("sung line is not a gap", !sheet[1].isGap)
checkEqual("line after metadata", sheet[1].text, "first sung line")

let repeated = LyricsProvider.parseLRC("[00:30.00][01:30.00][02:30.00]a repeated chorus line")
checkEqual("one line with three stamps becomes three entries", repeated.count, 3)
checkEqual("repeats keep the same text", Set(repeated.map(\.text)).count, 1)
checkEqual("second repeat is stamped correctly", repeated[1].time, 90)

let unsorted = LyricsProvider.parseLRC("""
[00:20.00]later
[00:10.00]earlier
""")
checkEqual("out-of-order input is sorted", unsorted.map(\.text), ["earlier", "later"])

// MARK: Offset tag

let shifted = LyricsProvider.parseLRC("""
[offset:+500]
[00:10.00]shifted later
""")
checkEqual("positive offset delays the line", shifted[0].time, 10.5)

let pulled = LyricsProvider.parseLRC("""
[offset:-2000]
[00:10.00]shifted earlier
""")
checkEqual("negative offset advances the line", pulled[0].time, 8)

let clamped = LyricsProvider.parseLRC("""
[offset:-5000]
[00:01.00]would land before zero
""")
checkEqual("offset never pushes a line negative", clamped[0].time, 0)

// MARK: Junk input

checkEqual("empty source", LyricsProvider.parseLRC("").count, 0)
checkEqual("plain text with no stamps", LyricsProvider.parseLRC("just a line\nand another").count, 0)
checkEqual("metadata only", LyricsProvider.parseLRC("[ar:Someone]\n[al:Something]").count, 0)
checkEqual("unterminated bracket", LyricsProvider.parseLRC("[00:10.00 no closing bracket").count, 0)
checkEqual("nonsense inside the stamp", LyricsProvider.parseLRC("[ab:cd.ef]text").count, 0)

let bracketed = LyricsProvider.parseLRC("[00:10.00][Chorus] a section label in the text")
checkEqual("a bracketed word in the text is left alone", bracketed.count, 1)
checkEqual("bracketed text survives intact", bracketed[0].text, "[Chorus] a section label in the text")

// MARK: Following the playhead

let timed = [
    LyricLine(time: 10, text: "first"),
    LyricLine(time: 20, text: "second"),
    LyricLine(time: 30, text: "third"),
]

check("before the first line nothing is current", LyricsProvider.index(at: 0, in: timed) == nil)
check("still nothing a moment before the first line", LyricsProvider.index(at: 9.99, in: timed) == nil)
checkEqual("exactly on a stamp selects that line", LyricsProvider.index(at: 10, in: timed), 0)
checkEqual("between stamps holds the earlier line", LyricsProvider.index(at: 19.5, in: timed), 0)
checkEqual("next stamp advances", LyricsProvider.index(at: 20, in: timed), 1)
checkEqual("last line stays current to the end", LyricsProvider.index(at: 999, in: timed), 2)
check("no lines means no index", LyricsProvider.index(at: 42, in: []) == nil)

let single = [LyricLine(time: 5, text: "only")]
check("single line, before", LyricsProvider.index(at: 1, in: single) == nil)
checkEqual("single line, after", LyricsProvider.index(at: 60, in: single), 0)

// A chorus repeat must resolve to the right occurrence, not the first one.
let chorus = (0..<5).map { LyricLine(time: Double($0) * 30, text: "chorus") }
checkEqual("binary search lands on the right repeat", LyricsProvider.index(at: 95, in: chorus), 3)

// MARK: Lookups that LRCLIB never answered
//
// A 503 (LRCLIB sheds load under traffic) must not be remembered as "this track has no lyrics".
// It used to be, which left a track blank for the rest of the session however often you came
// back to it.

/// Serves a given number of 503s, then real synced lyrics.
final class FlakyLRCLIB: URLProtocol {
    nonisolated(unsafe) static var failuresLeft = 0
    nonisolated(unsafe) static var requests = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }
    override func stopLoading() {}

    override func startLoading() {
        Self.requests += 1
        let failing = Self.failuresLeft > 0
        if failing { Self.failuresLeft -= 1 }

        let body: Data
        if failing {
            body = Data(#"{"name":"ServerOverloaded","statusCode":503}"#.utf8)
        } else if request.url?.path == "/api/get" {
            body = Data(#"{"instrumental":false,"syncedLyrics":"[00:01.00] one\n[00:05.00] two"}"#.utf8)
        } else {
            body = Data("[]".utf8)
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: failing ? 503 : 200,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@MainActor
func stubbedProvider() -> LyricsProvider {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [FlakyLRCLIB.self]
    return LyricsProvider(session: URLSession(configuration: config))
}

@MainActor
func settle(_ provider: LyricsProvider) async {
    // Long enough to cover the one retry the provider makes after a failed lookup.
    for _ in 0..<200 {
        try? await Task.sleep(nanoseconds: 25_000_000)
        if provider.status != .loading { return }
    }
}

await MainActor.run { }

await { @MainActor in
    // One transient 503 on each endpoint, then the service recovers.
    FlakyLRCLIB.failuresLeft = 2
    FlakyLRCLIB.requests = 0
    let provider = stubbedProvider()

    provider.load(title: "Queued Song", artist: "Some Artist", duration: 200)
    await settle(provider)
    checkEqual("a transient 503 is retried, not taken as the answer", provider.status, .synced)
    checkEqual("the retry brings the lyrics back", provider.lines.count, 2)

    // A failure that outlives the retry must still leave nothing cached.
    FlakyLRCLIB.failuresLeft = 99
    let stubborn = stubbedProvider()
    stubborn.load(title: "Other Song", artist: "Some Artist", duration: 180)
    await settle(stubborn)
    checkEqual("a lookup that never lands reads as unavailable", stubborn.status, .unavailable)

    // The service comes back. Looking again must actually ask again.
    FlakyLRCLIB.failuresLeft = 0
    let before = FlakyLRCLIB.requests
    stubborn.load(title: "Other Song", artist: "Some Artist", duration: 180)
    await settle(stubborn)
    check("a failed lookup is asked again rather than cached", FlakyLRCLIB.requests > before)
    checkEqual("and it recovers once LRCLIB answers", stubborn.status, .synced)

    // A real "no lyrics here" answer is settled, and is allowed to stick.
    checkEqual("lines survive the recovery", stubborn.lines.count, 2)
}()

// MARK: Preferring timings over an exact match
//
// /api/get matches on duration, so it often lands on an untimed sheet while a timed copy of the
// same song sits in the search results. Settling for the exact match leaves the panel showing
// words that never follow the playhead.

/// Serves whatever each endpoint is set to for the test at hand.
final class ShapedLRCLIB: URLProtocol {
    nonisolated(unsafe) static var get = "{}"
    nonisolated(unsafe) static var search = "[]"
    nonisolated(unsafe) static var searchRequests = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }
    override func stopLoading() {}

    override func startLoading() {
        let isGet = request.url?.path == "/api/get"
        if !isGet { Self.searchRequests += 1 }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((isGet ? Self.get : Self.search).utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

// Every sheet carries the length of the copy it was written against, as LRCLIB's own do: it is
// what says whether a set of stamps belongs to the track being played.
let plainSheet = #"{"duration":200,"instrumental":false,"plainLyrics":"one\ntwo\nthree"}"#
let syncedSheet = #"{"duration":200,"instrumental":false,"syncedLyrics":"[00:01.00] one\n[00:05.00] two"}"#
/// A timed sheet for a different, shorter cut of the same song.
let otherCut = #"{"duration":170,"instrumental":false,"plainLyrics":"one\ntwo","syncedLyrics":"[00:01.00] one\n[00:04.00] two"}"#

await { @MainActor in
    @MainActor func provider() -> LyricsProvider {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ShapedLRCLIB.self]
        return LyricsProvider(session: URLSession(configuration: config))
    }

    // The exact match is untimed, but a timed copy exists in the search results.
    ShapedLRCLIB.get = plainSheet
    ShapedLRCLIB.search = "[\(syncedSheet)]"
    let upgraded = provider()
    upgraded.load(title: "A", artist: "Artist", duration: 200)
    await settle(upgraded)
    checkEqual("an untimed exact match falls through to the timed one", upgraded.status, .synced)
    checkEqual("and it is the timed sheet that is shown", upgraded.lines.count, 2)

    // The only timed copy is another cut. Its words are the song's, so they are worth showing —
    // but its stamps are not this recording's, and following them walks the highlight off the
    // line being sung.
    ShapedLRCLIB.get = plainSheet
    ShapedLRCLIB.search = "[\(otherCut)]"
    let wrongCut = provider()
    wrongCut.load(title: "A2", artist: "Artist", duration: 200)
    await settle(wrongCut)
    checkEqual("a timed sheet from another cut is not followed", wrongCut.status, .plain)

    // Listed first is not the same as right: the matching copy has to win on length.
    ShapedLRCLIB.get = #"{}"#
    ShapedLRCLIB.search = "[\(otherCut),\(syncedSheet)]"
    let laterMatch = provider()
    laterMatch.load(title: "A3", artist: "Artist", duration: 200)
    await settle(laterMatch)
    checkEqual("the copy matching the track is found further down the list", laterMatch.status, .synced)
    checkEqual("and it is that copy's timings that are used", laterMatch.lines.count, 2)

    // Nothing is timed anywhere, so the exact match is still the best answer available.
    ShapedLRCLIB.get = plainSheet
    ShapedLRCLIB.search = "[]"
    let noTimings = provider()
    noTimings.load(title: "B", artist: "Artist", duration: 200)
    await settle(noTimings)
    checkEqual("with no timings anywhere the plain sheet still shows", noTimings.status, .plain)
    checkEqual("plain keeps all its lines", noTimings.lines.count, 3)

    // A timed exact match is already the best answer; the search endpoint is not worth asking.
    ShapedLRCLIB.get = syncedSheet
    ShapedLRCLIB.search = "[]"
    ShapedLRCLIB.searchRequests = 0
    let direct = provider()
    direct.load(title: "C", artist: "Artist", duration: 200)
    await settle(direct)
    checkEqual("a timed exact match is taken as is", direct.status, .synced)
    checkEqual("and the search endpoint is left alone", ShapedLRCLIB.searchRequests, 0)

    // Instrumental is a fact about the track, not a gap to go looking past.
    ShapedLRCLIB.get = #"{"instrumental":true}"#
    ShapedLRCLIB.search = "[\(syncedSheet)]"
    ShapedLRCLIB.searchRequests = 0
    let instrumental = provider()
    instrumental.load(title: "D", artist: "Artist", duration: 200)
    await settle(instrumental)
    checkEqual("instrumental settles the lookup", instrumental.status, .instrumental)
    checkEqual("without chasing a mislabelled sheet", ShapedLRCLIB.searchRequests, 0)
}()

// MARK: Centring the sheet

// The lyric sheet is slid rather than scrolled, so where it sits is this arithmetic rather than
// the framework's — worth pinning down, since getting it wrong parks the sung line off-centre.

let layout = LyricsLayout(spacing: 10, estimatedRow: 20)
// Six lines, each a measured 20 tall, in a panel 100 tall: line 0's centre is 10 from the top of
// the sheet, and the middle of the panel is 50 down.
let even = Dictionary(uniqueKeysWithValues: (0..<6).map { ($0, CGFloat(20)) })

checkEqual(
    "the opening line is centred",
    layout.offset(centring: 0, of: 6, in: 100, heights: even),
    40
)
// Line 2 sits 60 into the sheet (two 20pt lines and two 10pt gaps), with its own centre 10 below
// that — so the sheet has to ride 20 above the panel's top edge.
checkEqual(
    "a line further down pulls the sheet up",
    layout.offset(centring: 2, of: 6, in: 100, heights: even),
    -20
)
checkEqual(
    "each line moves the sheet by its height plus the gap",
    layout.offset(centring: 2, of: 6, in: 100, heights: even)
        - layout.offset(centring: 3, of: 6, in: 100, heights: even),
    30
)

// A line that wraps to two rows takes its own height into account, and shifts everything after it.
var wrapped = even
wrapped[1] = 44
checkEqual(
    "a wrapped line is centred on its own height",
    layout.offset(centring: 1, of: 6, in: 100, heights: wrapped),
    50 - 30 - 22
)
checkEqual(
    "and pushes the lines below it down",
    layout.offset(centring: 2, of: 6, in: 100, heights: wrapped),
    layout.offset(centring: 2, of: 6, in: 100, heights: even) - 24
)

// Lines are measured a frame after they are first laid out, so the estimate has to stand in
// without throwing the sheet somewhere absurd.
checkEqual(
    "an unmeasured line falls back to the estimate",
    layout.offset(centring: 2, of: 6, in: 100, heights: [:]),
    -20
)

// Nothing here should be able to put the sheet somewhere there is no line.
checkEqual("no current line centres the opening one", layout.offset(centring: nil, of: 6, in: 100, heights: even), 40)
checkEqual("an index past the end clamps", layout.offset(centring: 99, of: 6, in: 100, heights: even),
           layout.offset(centring: 5, of: 6, in: 100, heights: even))
checkEqual("a negative index clamps", layout.offset(centring: -3, of: 6, in: 100, heights: even), 40)
checkEqual("an empty sheet sits still", layout.offset(centring: 3, of: 0, in: 100, heights: even), 0)
checkEqual("so does a panel with no height yet", layout.offset(centring: 3, of: 6, in: 0, heights: even), 0)
// MARK: Browsing the sheet by hand

// Scrolling by hand slides the same offset the follow animates, so it is held to the range that
// keeps at least one line on the panel — otherwise a flick would leave it looking at nothing.

let reach = layout.browsing(6, in: 100, heights: even)
checkEqual("the sheet cannot be pulled below its opening line", reach.upperBound, 40)
checkEqual(
    "nor above its closing line",
    reach.lowerBound,
    layout.offset(centring: 5, of: 6, in: 100, heights: even)
)
checkEqual(
    "a flick downwards stops at the first line",
    layout.clamped(5000, count: 6, in: 100, heights: even),
    40
)
checkEqual(
    "a flick upwards stops at the last line",
    layout.clamped(-5000, count: 6, in: 100, heights: even),
    layout.offset(centring: 5, of: 6, in: 100, heights: even)
)
checkEqual(
    "anywhere in between is left alone",
    layout.clamped(-20, count: 6, in: 100, heights: even),
    -20
)
// A sheet shorter than the panel has nowhere to go.
checkEqual("a single line pins the sheet", layout.clamped(-400, count: 1, in: 100, heights: even), 40)
checkEqual("an empty sheet cannot be browsed", layout.clamped(-400, count: 0, in: 100, heights: even), 0)

// MARK: Picking the right copy of a song

// The search endpoint lists every copy LRCLIB holds, in no useful order and with no regard for
// how long the playing track is. Stamps only mean anything for the recording they were written
// against, so the copy that matches the track's length is the one worth following.

typealias Copy = (duration: Double?, isTimed: Bool)

// The case that started this: a 4:15 track, with a 3:53 cut listed first.
let listing: [Copy] = [
    (233.0, true),
    (255.0, true),
    (151.0, true),
    (254.84, true),
]
checkEqual("the copy matching the track wins, not the first listed",
           LyricsProvider.timedMatch(among: listing, trackDuration: 254.876), 3)
checkEqual("rounding in either direction still matches",
           LyricsProvider.timedMatch(among: [(255.0, true)], trackDuration: 254.876), 0)
checkEqual("a cut of another length is not this recording",
           LyricsProvider.timedMatch(among: [(233.0, true)], trackDuration: 254.876), nil)
checkEqual("an untimed copy is never the match, however well it fits",
           LyricsProvider.timedMatch(among: [(254.9, false)], trackDuration: 254.876), nil)
checkEqual("a copy that never says how long it is cannot be matched",
           LyricsProvider.timedMatch(among: [(nil, true)], trackDuration: 254.876), nil)
checkEqual("nothing listed, nothing matched",
           LyricsProvider.timedMatch(among: [], trackDuration: 254.876), nil)
// The tolerance is a boundary, so pin both sides of it.
let edge = LyricsProvider.durationTolerance
checkEqual("a copy exactly at the tolerance still counts",
           LyricsProvider.timedMatch(among: [(200 + edge, true)], trackDuration: 200), 0)
checkEqual("a copy just past it does not",
           LyricsProvider.timedMatch(among: [(200 + edge + 0.01, true)], trackDuration: 200), nil)
// Ties go to whichever is listed first, which is LRCLIB's own idea of relevance.
checkEqual("equally close copies fall back to the listed order",
           LyricsProvider.timedMatch(among: [(201.0, true), (199.0, true)], trackDuration: 200), 0)

print("\n\(passed) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
