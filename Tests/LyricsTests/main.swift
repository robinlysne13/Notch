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

print("\n\(passed) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
