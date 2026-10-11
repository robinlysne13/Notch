import Foundation

// Pins down the focus clock and the sums drawn from it: that a clock anchored to a moment reads
// correctly however long nobody looked at it, that pausing a count-up doesn't bank the pause as
// focus, that a session is filed under the day it ended where you are rather than in UTC, and
// that the thirty days behind you keep the days you did nothing on.

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

func checkClose(_ name: String, _ got: Double, _ expect: Double, tolerance: Double = 0.001) {
    check(name, abs(got - expect) <= tolerance, "expected \(expect), got \(got)")
}

func checkEqual<T: Equatable>(_ name: String, _ got: T, _ expect: T) {
    check(name, got == expect, "expected \(expect), got \(got)")
}

let start = Date(timeIntervalSinceReferenceDate: 1_000_000)

// MARK: Counting down

do {
    var clock = FocusClock().withLength(minutes: 25)
    checkEqual("a fresh countdown holds its whole length", clock.held, 25 * 60)
    checkEqual("a fresh countdown isn't running", clock.running, false)
    checkEqual("a fresh countdown reads its length", clock.shown(at: start), 25 * 60)

    clock = clock.started(at: start)
    check("starting anchors the end", clock.anchor == start.addingTimeInterval(25 * 60))
    checkClose("a minute in, 24 are left", clock.shown(at: start + 60), 24 * 60)
    checkClose("the elapsed side agrees", clock.elapsed(at: start + 60), 60)
    checkEqual("not done part way through", clock.isDone(at: start + 60), false)

    // The anchor is a moment, not a countdown held in memory, so a Mac that slept through the
    // end wakes to a clock that has already run out rather than one with time left on it.
    checkEqual("done at the anchor", clock.isDone(at: start + 25 * 60), true)
    checkEqual("still done long after", clock.isDone(at: start + 9 * 3600), true)
    checkEqual("the face never goes negative", clock.shown(at: start + 9 * 3600), 0)
    checkClose("elapsed stops at the length", clock.elapsed(at: start + 9 * 3600), 25 * 60)

    let paused = clock.paused(at: start + 10 * 60)
    checkEqual("pausing keeps what was left", paused.held, 15 * 60)
    checkEqual("a paused clock has no anchor", paused.anchor == nil, true)
    checkEqual("a paused clock reads the same whenever", paused.shown(at: start + 3 * 3600), 15 * 60)

    let resumed = paused.started(at: start + 3 * 3600)
    checkClose("resuming gives back the 15 that were left", resumed.shown(at: start + 3 * 3600), 15 * 60)
}

// MARK: Counting up

do {
    var clock = FocusClock().switched(to: .up)
    checkEqual("a fresh stopwatch is at zero", clock.shown(at: start), 0)

    clock = clock.started(at: start)
    checkClose("it counts up", clock.shown(at: start + 90), 90)
    checkEqual("a stopwatch is never done", clock.isDone(at: start + 9 * 3600), false)

    let paused = clock.paused(at: start + 90)
    checkEqual("pausing banks the 90 seconds", paused.held, 90)

    // The pause itself is not focus: resuming backdates the start so the gap isn't counted.
    let resumed = paused.started(at: start + 3600)
    checkClose("the hour paused isn't banked", resumed.shown(at: start + 3600), 90)
    checkClose("it carries on from 90", resumed.shown(at: start + 3600 + 30), 120)
}

// MARK: Switching and resetting

do {
    let running = FocusClock().withLength(minutes: 45).started(at: start)
    let up = running.switched(to: .up)
    checkEqual("switching stops the clock", up.running, false)
    // The minutes left of a countdown mean nothing as a stopwatch reading.
    checkEqual("switching to count-up starts from zero", up.held, 0)
    checkEqual("switching back starts from the length", up.switched(to: .down).held, 45 * 60)
    checkEqual("switching to the way it already runs changes nothing", running.switched(to: .down), running)

    let reset = running.reset()
    checkEqual("reset stops the clock", reset.running, false)
    checkEqual("reset goes back to the length", reset.held, 45 * 60)

    checkEqual("a length is at least a minute", FocusClock().withLength(minutes: 0).length, 60)
    checkEqual("a length is at most ten hours", FocusClock().withLength(minutes: 9_000).length, 600 * 60)
    checkEqual("setting a length implies counting down",
               FocusClock().switched(to: .up).withLength(minutes: 20).dir, .down)
}

// MARK: The ring

do {
    let clock = FocusClock().withLength(minutes: 10).started(at: start)
    checkClose("a full countdown draws a full ring", clock.fraction(at: start), 1)
    checkClose("half way through, half a ring", clock.fraction(at: start + 5 * 60), 0.5)
    checkClose("an expired countdown draws nothing", clock.fraction(at: start + 20 * 60), 0)

    // Counting up there is no end to be a fraction of, so the ring sweeps the minute instead of
    // pretending to measure progress towards a finish line that doesn't exist.
    let up = FocusClock().switched(to: .up).started(at: start)
    checkClose("a stopwatch ring sweeps the minute", up.fraction(at: start + 30), 0.5)
    checkClose("and starts the sweep again each minute", up.fraction(at: start + 90), 0.5)

    checkEqual("a zero-length countdown can't divide by it",
               FocusClock(dir: .down, running: false, anchor: nil, held: 0, length: 0, label: "")
                   .fraction(at: start), 0)
}

// MARK: Which day a session belongs to

do {
    // A stretch finished just after midnight is still the small hours of that day where you
    // are, while in UTC it is the evening before. The dashboard reads the parts off a local date
    // (its `toISODay`), so a notch filing by UTC would put the session on the wrong column of
    // the chart — and, around the turn of the day, on the wrong side of "today".
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Oslo")!
    let smallHours = calendar.date(
        from: DateComponents(year: 2026, month: 10, day: 12, hour: 0, minute: 30)
    )!
    checkEqual("a session is filed under the local day",
               FocusSession.day(of: smallHours, calendar: calendar), "2026-10-12")

    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!
    checkEqual("the same moment is still the day before in UTC",
               FocusSession.day(of: smallHours, calendar: utc), "2026-10-11")

    checkEqual("single digits are padded",
               FocusSession.day(of: calendar.date(from: DateComponents(year: 2026, month: 1, day: 5))!,
                                calendar: calendar),
               "2026-01-05")

    // The id only has to not collide: the web's merge addresses list items by it, so two
    // sessions sharing one would make the dashboard treat them as the same stretch.
    let ids = Set((0..<400).map { _ in FocusSession.freshID() })
    checkEqual("ids don't collide", ids.count, 400)
}

// MARK: Adding it up

do {
    func session(_ day: String, _ minutes: Int) -> FocusSession {
        var s = FocusSession(label: "work", minutes: minutes, endedAt: start)
        s.date = day
        return s
    }

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Oslo")!
    let today = calendar.date(from: DateComponents(year: 2026, month: 10, day: 11))!

    let sessions = [
        session("2026-10-11", 50), session("2026-10-11", 25),
        session("2026-10-10", 120),
        session("2026-10-08", 130),
        session("2025-01-01", 999), // older than the window
    ]

    checkEqual("a day's minutes are its sessions added up",
               FocusMaths.minutes(sessions, on: "2026-10-11"), 75)
    checkEqual("a day with nothing on it is zero",
               FocusMaths.minutes(sessions, on: "2026-10-09"), 0)

    let days = FocusMaths.lastDays(sessions, 5, ending: today, calendar: calendar)
    checkEqual("the window is as long as asked for", days.count, 5)
    checkEqual("oldest first", days.first?.key, "2026-10-07")
    checkEqual("today is last", days.last?.key, "2026-10-11")
    // A chart drawn from only the days that have sessions would space them evenly and quietly
    // turn a fortnight off into a flat week.
    checkEqual("the empty days are present", days.map(\.minutes), [0, 130, 0, 120, 75])
    checkEqual("sessions outside the window are left out",
               days.contains { $0.minutes == 999 }, false)

    // Today not being done yet doesn't break a streak: one you're still working on reads from
    // yesterday back.
    checkEqual("a streak counts back from today",
               FocusMaths.goalStreak(
                   [FocusDay(key: "a", minutes: 120), FocusDay(key: "b", minutes: 130),
                    FocusDay(key: "c", minutes: 10)],
                   goal: 120), 2)
    checkEqual("today over the goal counts too",
               FocusMaths.goalStreak(
                   [FocusDay(key: "a", minutes: 120), FocusDay(key: "b", minutes: 130)],
                   goal: 120), 2)
    checkEqual("a missed day earlier on ends it",
               FocusMaths.goalStreak(
                   [FocusDay(key: "a", minutes: 120), FocusDay(key: "b", minutes: 0),
                    FocusDay(key: "c", minutes: 130)],
                   goal: 120), 1)
    checkEqual("no goal is no streak",
               FocusMaths.goalStreak([FocusDay(key: "a", minutes: 120)], goal: 0), 0)
}

// MARK: Saying a length

do {
    checkEqual("a clock face", FocusMaths.mmss(275), "04:35")
    checkEqual("zero", FocusMaths.mmss(0), "00:00")
    // A countdown read a hair before the second ticks should say the second it is still on.
    checkEqual("part seconds round up", FocusMaths.mmss(0.2), "00:01")
    checkEqual("negative is zero", FocusMaths.mmss(-10), "00:00")
    checkEqual("over an hour keeps counting minutes", FocusMaths.mmss(3700), "61:40")

    checkEqual("minutes in prose", FocusMaths.hm(45), "45m")
    checkEqual("hours and minutes", FocusMaths.hm(80), "1h 20m")
    checkEqual("a round hour drops the minutes", FocusMaths.hm(120), "2h")
    checkEqual("nothing", FocusMaths.hm(0), "0m")
}

// MARK: Settings as the dashboard writes them

do {
    // A settings object written before a field existed still has to answer for it.
    let partial = #"{"focus":50,"goal":180}"#.data(using: .utf8)!
    let decoded = try! JSONDecoder().decode(FocusSettings.self, from: partial)
    checkEqual("what was written is read", decoded.goal, 180)
    checkEqual("and so is the rest", decoded.focus, 50)
    checkEqual("a missing field falls back", decoded.longEvery, FocusSettings.defaults.longEvery)
    checkEqual("including the booleans", decoded.sound, true)

    // The field names are the web app's, and a session has to survive the round trip under them.
    let session = FocusSession(id: "abc123", label: "Reading", minutes: 25, endedAt: start)
    let json = String(data: try! JSONEncoder().encode(session), encoding: .utf8)!
    for field in ["\"id\"", "\"label\"", "\"minutes\"", "\"date\"", "\"endedAt\""] {
        check("a session carries \(field)", json.contains(field), json)
    }
    let back = try! JSONDecoder().decode(FocusSession.self, from: json.data(using: .utf8)!)
    checkEqual("a session survives the round trip", back, session)
}

print("\(passed) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
