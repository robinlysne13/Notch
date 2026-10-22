import CoreGraphics
import Foundation

// Pins down when the notch panel is allowed to stay open. The rule has to serve three habits at
// once: sweeping across the top of the screen to reach Chrome's tab strip, which opens the panel
// by accident and wants it gone at once; reaching into the panel for a button, which wants it to
// survive an overshoot; and reaching in for one thing only — a skipped track, a file dropped on
// the shelf — which wants it out of the way the moment that errand is done.

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

// The closed notch, and the panel it grows into. Roughly the real proportions: opening the panel
// widens the chrome by a factor of four, which is the whole reason presence alone proves nothing.
let closedChrome = CGRect(x: 500, y: 900, width: 200, height: 32)
let openChrome = CGRect(x: 380, y: 700, width: 440, height: 232)

let start = Date(timeIntervalSinceReferenceDate: 0)
func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

func mid(_ rect: CGRect) -> CGPoint { CGPoint(x: rect.midX, y: rect.midY) }

/// A point on the closed notch that is still on the panel once it has grown — which is where the
/// pointer necessarily is at the moment the panel opens under it.
let onNotch = CGPoint(x: 600, y: 916)

/// Somewhere else entirely — far enough that a pointer there has plainly gone, so a committed
/// panel owes it no wait at all.
let away = CGPoint(x: 1200, y: 300)

/// Clear of the sticky margin, but only just: a pointer that has stepped off the panel rather
/// than left it, and so is owed very nearly the whole grace.
let justClear = CGPoint(x: 600, y: openChrome.minY - 60)

/// A panel committed the way a visitor commits one: opened, then rested on for the dwell. Used by
/// the tests that are about what a committed panel does rather than how it got that way. Committed
/// as of `at(0.35)`.
func visited() -> NotchHover {
    var hover = NotchHover()
    _ = hover.evaluate(pointer: onNotch, chrome: closedChrome, now: at(0))
    _ = hover.evaluate(pointer: onNotch, chrome: openChrome, now: at(0.35))
    return hover
}

// MARK: Opening

do {
    var hover = NotchHover()
    let action = hover.evaluate(pointer: mid(closedChrome), chrome: closedChrome, now: at(0))
    checkEqual("touching the notch opens it", action, .open)
    check("and it starts out uncommitted", hover.phase == .passing)
    check("evaluate reports it open", hover.isOpen)
}

// MARK: Sweeping past on the way somewhere else
//
// The pointer crosses the notch at speed, heading for a browser tab. The panel pops open under
// it, so from here on the chrome is the full panel — but the pointer never stops.

do {
    var hover = NotchHover()
    checkEqual(
        "the sweep opens the panel on its way past",
        hover.evaluate(pointer: CGPoint(x: 505, y: 916), chrome: closedChrome, now: at(0)),
        .open
    )

    // Travelling right across the now much wider panel. Each step clears the settle radius, and
    // by the last one more than `commitDwell` has elapsed since the panel opened.
    var action = NotchHover.Action.none
    var elapsed = 0.0
    for step in 1...6 {
        elapsed = Double(step) * 0.06
        let x = 505 + CGFloat(step) * 45
        check("step \(step) is still on the panel", openChrome.contains(CGPoint(x: x, y: 916)))
        action = hover.evaluate(pointer: CGPoint(x: x, y: 916), chrome: openChrome, now: at(elapsed))
    }
    check("the sweep outlasts the dwell", elapsed > 0.3)
    check("yet a pointer still travelling never commits", hover.phase == .passing)
    checkEqual("and nothing closes while it is still over the panel", action, NotchHover.Action.none)

    let left = hover.evaluate(pointer: CGPoint(x: 900, y: 916), chrome: openChrome, now: at(0.42))
    checkEqual("an accidental open closes the moment the pointer leaves", left, .close)
    check("and it is properly closed", !hover.isOpen)
}

// MARK: Resting on the panel commits it

do {
    var hover = NotchHover()
    _ = hover.evaluate(pointer: onNotch, chrome: closedChrome, now: at(0))

    _ = hover.evaluate(pointer: onNotch, chrome: openChrome, now: at(0.1))
    check("not yet committed a tenth of a second in", hover.phase == .passing)

    _ = hover.evaluate(pointer: onNotch, chrome: openChrome, now: at(0.35))
    check("resting on the panel commits it", hover.phase == .committed)
}

do {
    // A small drift still counts as resting; a large one restarts the clock.
    var hover = NotchHover()
    _ = hover.evaluate(pointer: onNotch, chrome: closedChrome, now: at(0))
    _ = hover.evaluate(
        pointer: CGPoint(x: onNotch.x + 8, y: onNotch.y + 8),
        chrome: openChrome,
        now: at(0.35)
    )
    check("a few points of drift still counts as resting", hover.phase == .committed)

    var moving = NotchHover()
    _ = moving.evaluate(pointer: onNotch, chrome: closedChrome, now: at(0))
    // A jump just before the dwell would have elapsed restarts it...
    _ = moving.evaluate(
        pointer: CGPoint(x: onNotch.x + 60, y: onNotch.y),
        chrome: openChrome,
        now: at(0.29)
    )
    _ = moving.evaluate(
        pointer: CGPoint(x: onNotch.x + 60, y: onNotch.y),
        chrome: openChrome,
        now: at(0.35)
    )
    check("a jump past the settle radius restarts the clock", moving.phase == .passing)
    // ...and the dwell is then measured from the jump, not from the open.
    _ = moving.evaluate(
        pointer: CGPoint(x: onNotch.x + 60, y: onNotch.y),
        chrome: openChrome,
        now: at(0.60)
    )
    check("settling after the jump commits from there", moving.phase == .committed)
}

// MARK: One errand, and then away
//
// Reaching in to skip a single track. The click is the whole visit, so the panel has to leave
// with the pointer rather than hold the screen for the grace period afterwards.

do {
    var hover = NotchHover()
    _ = hover.evaluate(pointer: onNotch, chrome: closedChrome, now: at(0))
    hover.acted(.touch, pointer: onNotch, now: at(0.1))
    check("one click does not commit the panel", hover.phase == .passing)
    checkEqual(
        "so leaving after a single errand closes at once",
        hover.evaluate(pointer: away, chrome: openChrome, now: at(0.2)),
        .close
    )
}

do {
    // Even a panel already committed by a long hover: the errand is the last word on it.
    var hover = visited()
    check("resting committed it", hover.phase == .committed)
    hover.acted(.touch, pointer: onNotch, now: at(0.5))
    check("an errand hands a committed panel back to the pointer", hover.phase == .passing)
    checkEqual(
        "and it closes on the way out",
        hover.evaluate(pointer: away, chrome: openChrome, now: at(0.6)),
        .close
    )
}

// MARK: Clicking around

do {
    // A second act is someone working the panel, not running an errand.
    var hover = NotchHover()
    _ = hover.evaluate(pointer: onNotch, chrome: closedChrome, now: at(0))
    hover.acted(.touch, pointer: onNotch, now: at(0.1))
    hover.acted(.touch, pointer: onNotch, now: at(0.4))
    check("a second act commits without waiting for a dwell", hover.phase == .committed)
    checkEqual(
        "and a committed panel does not close as the pointer steps off it",
        hover.evaluate(pointer: justClear, chrome: openChrome, now: at(0.5)),
        NotchHover.Action.none
    )

    // Further acts leave it committed rather than demoting it again.
    hover.acted(.touch, pointer: onNotch, now: at(0.6))
    check("still committed after a third", hover.phase == .committed)
}

do {
    // Scrolling the lyrics is the same evidence by a different route, and arrives in bursts.
    var hover = NotchHover()
    _ = hover.evaluate(pointer: onNotch, chrome: closedChrome, now: at(0))
    hover.acted(.touch, pointer: onNotch, now: at(0.1))
    hover.acted(.touch, pointer: onNotch, now: at(0.12))
    check("a scroll flick commits it", hover.phase == .committed)
}

do {
    // Staying put after the errand commits it too — the dwell measured from the act rather than
    // from whenever the pointer first arrived.
    var hover = NotchHover()
    _ = hover.evaluate(pointer: onNotch, chrome: closedChrome, now: at(0))
    hover.acted(.touch, pointer: onNotch, now: at(0.1))
    _ = hover.evaluate(pointer: onNotch, chrome: openChrome, now: at(0.35))
    check("the pre-act dwell does not carry over", hover.phase == .passing)
    _ = hover.evaluate(pointer: onNotch, chrome: openChrome, now: at(0.45))
    check("resting on after the errand commits it", hover.phase == .committed)
}

// MARK: Dragging, which is one errand however it started

do {
    // Something dragged off the shelf: the mouse-down lands on the panel, the release doesn't.
    var hover = NotchHover()
    _ = hover.evaluate(pointer: onNotch, chrome: closedChrome, now: at(0))
    hover.acted(.touch, pointer: onNotch, now: at(0.1))
    hover.acted(.dragEnded, pointer: away, now: at(0.9))
    check("picking up and letting go is one act, not two", hover.phase == .passing)
    checkEqual(
        "so the shelf closes behind a file dragged out of it",
        hover.evaluate(pointer: away, chrome: openChrome, now: at(0.95)),
        .close
    )
}

do {
    // Files dragged in: the panel opened committed, because aiming a drag at the notch is as
    // deliberate as it gets. The drop ends that.
    var hover = NotchHover()
    hover.openDeliberately()
    hover.acted(.dragEnded, pointer: onNotch, now: at(1.0))
    check("the drop hands the panel back to the pointer", hover.phase == .passing)
    checkEqual(
        "leaving after the drop closes at once",
        hover.evaluate(pointer: away, chrome: openChrome, now: at(1.1)),
        .close
    )
}

do {
    // ...but staying to look at what landed holds it, like any other rest.
    var hover = NotchHover()
    hover.openDeliberately()
    hover.acted(.dragEnded, pointer: onNotch, now: at(1.0))
    _ = hover.evaluate(pointer: onNotch, chrome: openChrome, now: at(1.4))
    check("resting after the drop commits it again", hover.phase == .committed)
}

do {
    // Acts are counted per visit: two errands either side of a close are not clicking around.
    var hover = NotchHover()
    _ = hover.evaluate(pointer: onNotch, chrome: closedChrome, now: at(0))
    hover.acted(.touch, pointer: onNotch, now: at(0.1))
    checkEqual(
        "the first visit closes on its errand",
        hover.evaluate(pointer: away, chrome: openChrome, now: at(0.2)),
        .close
    )
    _ = hover.evaluate(pointer: onNotch, chrome: closedChrome, now: at(5))
    hover.acted(.touch, pointer: onNotch, now: at(5.1))
    check("and the next one starts counting from nothing", hover.phase == .passing)
}

do {
    // A click on the collapsed notch is not an act on a panel that isn't open.
    var hover = NotchHover()
    hover.acted(.touch, pointer: onNotch, now: at(0))
    check("acting on a closed notch is ignored", !hover.isOpen)
}

// MARK: Overshooting a button

do {
    var hover = visited()

    // Reaching for a button at the bottom edge and overshooting by 20pt.
    let overshoot = CGPoint(x: openChrome.midX, y: openChrome.minY - 20)
    checkEqual(
        "a small overshoot holds",
        hover.evaluate(pointer: overshoot, chrome: openChrome, now: at(0.4)),
        .none
    )
    // Still held a long time later: inside the slop, the clock never even starts.
    checkEqual(
        "and keeps holding while the pointer lingers just off the edge",
        hover.evaluate(pointer: overshoot, chrome: openChrome, now: at(5)),
        .none
    )
    check("still open", hover.isOpen)

    // Back onto a button.
    checkEqual(
        "coming back onto the panel is uneventful",
        hover.evaluate(pointer: mid(openChrome), chrome: openChrome, now: at(5.1)),
        .none
    )
    check("and it stayed committed throughout", hover.phase == .committed)
}

// MARK: Leaving properly

do {
    var hover = visited()
    checkEqual(
        "stepping just clear starts the grace rather than closing",
        hover.evaluate(pointer: justClear, chrome: openChrome, now: at(1.0)),
        .none
    )
    checkEqual(
        "still open part way through the grace",
        hover.evaluate(pointer: justClear, chrome: openChrome, now: at(1.3)),
        .none
    )
    checkEqual(
        "and it closes once the grace is up",
        hover.evaluate(pointer: justClear, chrome: openChrome, now: at(1.6)),
        .close
    )
    check("properly closed", !hover.isOpen)
}

do {
    // Coming back during the grace cancels it outright, rather than closing late.
    var hover = visited()
    _ = hover.evaluate(pointer: justClear, chrome: openChrome, now: at(1.0))
    _ = hover.evaluate(pointer: mid(openChrome), chrome: openChrome, now: at(1.2))
    checkEqual(
        "returning cancels the grace instead of closing late",
        hover.evaluate(pointer: justClear, chrome: openChrome, now: at(1.6)),
        .none
    )
    check("still open", hover.isOpen)
    checkEqual(
        "and the grace restarts from the second departure",
        hover.evaluate(pointer: justClear, chrome: openChrome, now: at(2.2)),
        .close
    )
}

// MARK: Going properly away
//
// The grace is for a pointer hesitating at the edge. Distance says the opposite, so the further
// out the pointer is, the less of the wait is left — and a pointer right across the screen is
// owed none of it.

do {
    var hover = visited()
    checkEqual(
        "a pointer well clear of the panel takes it along at once",
        hover.evaluate(pointer: away, chrome: openChrome, now: at(1.0)),
        .close
    )
    check("properly closed", !hover.isOpen)
}

do {
    // Partway out: more than an overshoot, less than gone. Half the distance to `bail` leaves
    // half the grace, so it holds for a quarter of a second rather than half of one.
    var hover = visited()
    let halfway = CGPoint(x: 600, y: openChrome.minY - 130)
    checkEqual(
        "a middling departure holds at first",
        hover.evaluate(pointer: halfway, chrome: openChrome, now: at(1.0)),
        .none
    )
    checkEqual(
        "still open at a fifth of a second",
        hover.evaluate(pointer: halfway, chrome: openChrome, now: at(1.2)),
        .none
    )
    checkEqual(
        "and gone by a quarter, where a near miss would have had half a second",
        hover.evaluate(pointer: halfway, chrome: openChrome, now: at(1.26)),
        .close
    )
}

do {
    // Carrying on away spends the wait down instead of restarting it: the deadline is reckoned
    // from the first step clear, and walking further out brings it forward.
    var hover = visited()
    _ = hover.evaluate(pointer: justClear, chrome: openChrome, now: at(1.0))
    checkEqual(
        "walking on out closes without waiting for the near-miss grace",
        hover.evaluate(pointer: away, chrome: openChrome, now: at(1.1)),
        .close
    )
}

// MARK: Drag-to-open and explicit dismissal

do {
    var hover = NotchHover()
    hover.openDeliberately()
    check("a file drag opens it committed", hover.phase == .committed)

    hover.reset()
    check("reset dismisses it whatever the pointer is doing", !hover.isOpen)
    checkEqual(
        "and a closed panel stays quiet while the pointer is away",
        hover.evaluate(pointer: CGPoint(x: 1200, y: 300), chrome: closedChrome, now: at(9)),
        .none
    )
}

print("\n\(passed) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
