import Foundation

// Pins down the playhead the lyrics ride on: that a reading is credited to the moment it was
// taken rather than the moment it arrived, that drift is eased out while real jumps are followed,
// and that the shown position never rewinds mid-playback.

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

let start = Date(timeIntervalSinceReferenceDate: 1_000_000)

/// A playing playhead anchored at `position` as of `start`.
func playing(at position: Double, duration: Double = 200) -> Playhead {
    var playhead = Playhead()
    playhead.setDuration(duration)
    playhead.setPlaying(true, at: start)
    playhead.snap(to: position, at: start)
    return playhead
}

// MARK: A reading describes the past

// The reason the lyrics used to lag: a position read over a ~220ms round trip was filed as true
// "now", so the playhead sat a fifth of a second behind the song for as long as it played.
var latency = Playhead()
latency.setDuration(200)
latency.setPlaying(true, at: start)
latency.observe(position: 10, sampledAt: start.addingTimeInterval(-0.22))
checkClose("a reading is credited to when it was sampled", latency.estimate(at: start), 10.22)

// MARK: Drift is eased, jumps are followed

var drift = playing(at: 10)
// Two seconds on, the player says 12.3 where 12.0 was expected: within tolerance, so half the
// 0.3s gap is closed rather than all of it.
drift.observe(position: 12.3, sampledAt: start.addingTimeInterval(2))
checkClose("small drift is half corrected", drift.estimate(at: start.addingTimeInterval(2)), 12.15)

var jump = playing(at: 10)
jump.observe(position: 60, sampledAt: start.addingTimeInterval(2))
checkClose("a jump beyond tolerance is followed exactly", jump.estimate(at: start.addingTimeInterval(2)), 60)

var threshold = playing(at: 10)
threshold.observe(position: 12 + Playhead.snapThreshold + 0.01, sampledAt: start.addingTimeInterval(2))
checkClose(
    "just past the threshold snaps",
    threshold.estimate(at: start.addingTimeInterval(2)),
    12 + Playhead.snapThreshold + 0.01
)

// MARK: The shown position never rewinds while playing

var rewind = playing(at: 10)
rewind.advance(to: start.addingTimeInterval(2))
checkClose("the clock runs between readings", rewind.position, 12)
// The player comes back 0.3s behind. The anchor moves back, but the shown position must not —
// stepping it back would bounce the highlighted lyric up to the previous line.
rewind.observe(position: 11.7, sampledAt: start.addingTimeInterval(2))
rewind.advance(to: start.addingTimeInterval(2))
checkClose("a backwards correction holds the position instead", rewind.position, 12)
check("the correction is still pending underneath", rewind.estimate(at: start.addingTimeInterval(2)) < 12)
// It heals: the wall clock catches up with the held position and then carries on.
rewind.advance(to: start.addingTimeInterval(3))
checkClose("and the clock catches up", rewind.position, 12.85)

// A seek is a deliberate jump, so that one does move the position back.
var seek = playing(at: 100)
seek.advance(to: start.addingTimeInterval(1))
seek.snap(to: 20, at: start.addingTimeInterval(1))
checkClose("a seek backwards moves the position back", seek.position, 20)

// MARK: Pause and resume

var paused = playing(at: 30)
paused.advance(to: start.addingTimeInterval(2))
paused.setPlaying(false, at: start.addingTimeInterval(2))
checkClose("pausing freezes the playhead", paused.estimate(at: start.addingTimeInterval(60)), 32)
paused.advance(to: start.addingTimeInterval(60))
checkClose("and ticking while paused does not move it", paused.position, 32)
// While paused a reading is simply the truth — there is no drift for it to be arguing with.
paused.observe(position: 31, sampledAt: start.addingTimeInterval(61))
checkClose("a paused reading is taken as given", paused.position, 31)
paused.setPlaying(true, at: start.addingTimeInterval(61))
paused.advance(to: start.addingTimeInterval(63))
checkClose("resuming carries on from where it stopped", paused.position, 33)

// MARK: Bounds

var bounds = playing(at: 199)
bounds.advance(to: start.addingTimeInterval(30))
checkClose("the playhead stops at the end of the track", bounds.position, 200)
bounds.setDuration(50)
checkClose("a shorter track pulls the playhead inside it", bounds.position, 50)

var unknown = Playhead()
unknown.setPlaying(true, at: start)
unknown.observe(position: 90, sampledAt: start)
unknown.advance(to: start.addingTimeInterval(10))
checkClose("an unknown duration does not cap the playhead", unknown.position, 100)

var cleared = playing(at: 42)
cleared.reset()
checkClose("reset forgets the track", cleared.position, 0)
check("reset stops the clock", !cleared.isPlaying && !cleared.isAnchored)

// MARK: How close it actually tracks a playing song

// Plays a minute of a song, polling every two seconds the way the app does. Each poll reports the
// true position as of the middle of its round trip, give or take the few milliseconds of error
// that the midpoint estimate leaves, and the shown position is checked ten times a second
// throughout. A lyric lands on the right line only if this error stays well under the gap
// between lines, so it is worth asserting rather than assuming.
var tracking = Playhead()
tracking.setDuration(300)
tracking.setPlaying(true, at: start)
tracking.snap(to: 0, at: start)

var worstError: Double = 0
var tick = 0.0
var nextPoll = 2.0
var jitter = 0.012
while tick < 60 {
    if tick >= nextPoll {
        // The reading describes the midpoint of the round trip, filed with a small error.
        let sampled = nextPoll - 0.11
        tracking.observe(position: sampled + jitter, sampledAt: start.addingTimeInterval(sampled))
        jitter = -jitter
        nextPoll += 2
    }
    tracking.advance(to: start.addingTimeInterval(tick))
    worstError = max(worstError, abs(tracking.position - tick))
    tick += 0.1
}
check("tracks a playing song to within 50ms", worstError < 0.05, "worst error \(worstError)s")

// MARK: Report

print("\n\(passed) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
