import CoreGraphics
import Foundation

// Pins down when the notch panel is allowed to stay open. The rule has to serve two opposite
// habits at once: sweeping across the top of the screen to reach Chrome's tab strip, which opens
// the panel by accident and wants it gone at once, and reaching into the panel for a button,
// which wants it to survive an overshoot.

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

// MARK: Clicking or scrolling commits outright

do {
    var hover = NotchHover()
    _ = hover.evaluate(pointer: onNotch, chrome: closedChrome, now: at(0))
    hover.acted()
    check("a click commits without waiting for the dwell", hover.phase == .committed)

    // And having committed, it survives leaving.
    let left = hover.evaluate(pointer: CGPoint(x: 900, y: 400), chrome: openChrome, now: at(0.1))
    checkEqual("a committed panel does not close on the way out", left, NotchHover.Action.none)
}

// MARK: Overshooting a button

do {
    var hover = NotchHover()
    _ = hover.evaluate(pointer: onNotch, chrome: closedChrome, now: at(0))
    hover.acted()

    // Reaching for a button at the bottom edge and overshooting by 20pt.
    let overshoot = CGPoint(x: openChrome.midX, y: openChrome.minY - 20)
    checkEqual(
        "a small overshoot holds",
        hover.evaluate(pointer: overshoot, chrome: openChrome, now: at(0.2)),
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
    var hover = NotchHover()
    _ = hover.evaluate(pointer: onNotch, chrome: closedChrome, now: at(0))
    hover.acted()

    let away = CGPoint(x: 1200, y: 300)
    checkEqual(
        "going well clear starts the grace rather than closing",
        hover.evaluate(pointer: away, chrome: openChrome, now: at(1.0)),
        .none
    )
    checkEqual(
        "still open part way through the grace",
        hover.evaluate(pointer: away, chrome: openChrome, now: at(1.3)),
        .none
    )
    checkEqual(
        "and it closes once the grace is up",
        hover.evaluate(pointer: away, chrome: openChrome, now: at(1.6)),
        .close
    )
    check("properly closed", !hover.isOpen)
}

do {
    // Coming back during the grace cancels it outright, rather than closing late.
    var hover = NotchHover()
    _ = hover.evaluate(pointer: onNotch, chrome: closedChrome, now: at(0))
    hover.acted()

    let away = CGPoint(x: 1200, y: 300)
    _ = hover.evaluate(pointer: away, chrome: openChrome, now: at(1.0))
    _ = hover.evaluate(pointer: mid(openChrome), chrome: openChrome, now: at(1.2))
    checkEqual(
        "returning cancels the grace instead of closing late",
        hover.evaluate(pointer: away, chrome: openChrome, now: at(1.6)),
        .none
    )
    check("still open", hover.isOpen)
    checkEqual(
        "and the grace restarts from the second departure",
        hover.evaluate(pointer: away, chrome: openChrome, now: at(2.2)),
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
