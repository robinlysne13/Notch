import CoreGraphics
import Foundation

/// The rule behind when the notch panel opens and, more to the point, when it is allowed to stay
/// open after the pointer has left.
///
/// Hovering the notch is both how the panel is summoned and how it is dismissed, so the two have
/// to be told apart. A pointer sweeping across the top of the screen on its way to Chrome's tab
/// strip opens the panel by accident and wants it gone immediately. A pointer that came for the
/// panel wants it to survive overshooting a button by a few points.
///
/// What separates them is rest. Only a pointer that actually stops on the chrome commits the
/// panel; one still travelling never does, however long it happens to be over the chrome. That
/// distinction matters because opening the panel grows the chrome from the notch to the whole
/// panel, so "time spent inside" on its own says very little.
///
/// Acting on the panel is weaker evidence than it looks. Skipping a track or dropping a file on
/// the shelf is an errand: it is finished the moment it happens, and holding the panel open
/// afterwards only puts it in the way. What says someone means to go on is a *second* act, or a
/// pointer that stays resting on the chrome once the first is done. So the first act re-arms the
/// question rather than settling it.
///
/// Leaving is read by distance as much as by time. A committed panel owes the pointer a moment to
/// come back, because stepping just off an edge is usually a near miss — but a pointer halfway
/// across the screen has plainly gone, and making it wait out the same half second leaves the
/// panel sitting over whatever it was heading for. So the wait is largest at the edge and runs out
/// entirely by `bail`.
///
/// Kept apart from `AppDelegate` so the rule can be exercised without a window or a mouse.
struct NotchHover {
    enum Phase: Equatable {
        case closed
        /// Open, but the pointer may only be passing through.
        case passing
        /// Open and meant — survives the pointer straying off the chrome.
        case committed
    }

    /// What someone just did to the panel. Not which control was hit — the panel can't usefully
    /// tell a tab from a skip button — but whether the doing looks finished.
    enum Act: Equatable {
        /// A click or a scroll on the chrome.
        case touch
        /// A drag just let go of: files dropped on the shelf, or something taken off it. One
        /// errand however it started, so it never counts as the second act — the click that
        /// picked the file up is part of the same movement.
        case dragEnded
    }

    /// What the caller should do to the panel. `evaluate` returns `.none` far more often than
    /// not; only a real change comes back as `.open` or `.close`.
    enum Action: Equatable {
        case none
        case open
        case close
    }

    /// How long the pointer has to rest on the chrome before the open counts as meant. Short
    /// enough that nobody waits for it on purpose.
    var commitDwell: TimeInterval = 0.3
    /// How far the pointer may drift and still count as resting.
    var settleRadius: CGFloat = 26
    /// How far past the chrome the pointer may stray with the panel still holding. Sized for an
    /// overshoot past a button, not for wandering off across the screen.
    var slop: CGFloat = 40
    /// How long a committed panel holds once the pointer has only just stepped off the slop. The
    /// wait is for someone hesitating at the edge, so it is spent down as the pointer travels.
    var grace: TimeInterval = 0.5
    /// How far clear of the chrome the pointer has to get for the panel to stop waiting at all.
    /// Distance is the plainest statement there is that someone has gone elsewhere: between the
    /// slop and here the grace shrinks in proportion, so a pointer heading for the dock takes the
    /// panel with it while one lingering nearby still gets the full half second.
    var bail: CGFloat = 220

    private(set) var phase: Phase = .closed
    /// Where the pointer settled and when — the pair that decides resting from travelling.
    private var restAnchor: CGPoint = .zero
    private var restSince: Date = .distantFuture
    /// When a committed panel was last seen to be properly clear of the chrome. The closing
    /// deadline is measured from here and re-reckoned on every event, so moving further off
    /// brings it forward rather than restarting it.
    private var leftAt: Date?
    /// Acts since this panel opened. One is an errand, two is someone working the panel.
    private var acts = 0

    var isOpen: Bool { phase != .closed }

    /// The single decision point, driven both by pointer movement and by a tick while open — a
    /// pointer that stops dead sends no more events, and a grace period has to expire on its own.
    mutating func evaluate(pointer: CGPoint, chrome: CGRect, now: Date) -> Action {
        guard !chrome.contains(pointer) else { return entered(pointer: pointer, now: now) }

        switch phase {
        case .closed:
            return .none
        case .passing:
            // Nothing has been invested in this one, so it leaves with the pointer.
            return close()
        case .committed:
            // Just off the edge: almost always an overshoot on the way to a button, so hold
            // without even starting the clock.
            let clearance = clearance(from: chrome, to: pointer)
            if clearance <= slop {
                leftAt = nil
                return .none
            }
            let left = leftAt ?? now
            leftAt = left
            return now.timeIntervalSince(left) >= wait(clearance: clearance) ? close() : .none
        }
    }

    /// A click, a scroll or a finished drag on the chrome.
    ///
    /// The first one deliberately does *not* commit the panel. An errand run and done with —
    /// one song skipped, one file dropped on the shelf — leaves with the pointer, so the panel
    /// goes back to being uncommitted and closes the moment the pointer is clear. Carrying on
    /// is what holds it: a second act commits it outright, and so does the pointer simply
    /// resting on the chrome from here, by the usual dwell.
    mutating func acted(_ act: Act, pointer: CGPoint, now: Date) {
        guard phase != .closed else { return }
        leftAt = nil
        acts = act == .dragEnded ? 1 : acts + 1
        guard acts < 2 else { return phase = .committed }
        phase = .passing
        // Rest is measured from the act, not from whenever the pointer first arrived: the dwell
        // that commits a panel now has to happen after the errand was finished.
        restAnchor = pointer
        restSince = now
    }

    /// Opening by other means — a file drag aimed at the notch — is deliberate by definition.
    /// Only until the drag is let go of, mind: the drop is an errand like any other, and
    /// `acted(.dragEnded …)` is what hands the panel back to the pointer.
    mutating func openDeliberately() {
        phase = .committed
        leftAt = nil
        acts = 0
    }

    /// Dismiss regardless of what the pointer is doing.
    mutating func reset() {
        phase = .closed
        leftAt = nil
        restSince = .distantFuture
        acts = 0
    }

    private mutating func entered(pointer: CGPoint, now: Date) -> Action {
        leftAt = nil
        switch phase {
        case .closed:
            phase = .passing
            restAnchor = pointer
            restSince = now
            return .open
        case .passing:
            // Drifting past `settleRadius` restarts the clock, so only a pointer that stops
            // commits — however long a travelling one stays over the chrome.
            if hypot(pointer.x - restAnchor.x, pointer.y - restAnchor.y) > settleRadius {
                restAnchor = pointer
                restSince = now
            } else if now.timeIntervalSince(restSince) >= commitDwell {
                phase = .committed
            }
            return .none
        case .committed:
            return .none
        }
    }

    /// How far the pointer is from the chrome itself — nought anywhere inside it.
    private func clearance(from chrome: CGRect, to pointer: CGPoint) -> CGFloat {
        let dx = max(chrome.minX - pointer.x, 0, pointer.x - chrome.maxX)
        let dy = max(chrome.minY - pointer.y, 0, pointer.y - chrome.maxY)
        return hypot(dx, dy)
    }

    /// The wait owed to a pointer this far out: the full grace at the slop's edge, none at all by
    /// `bail`, and proportionally less in between. Since it is measured from when the pointer
    /// first went clear, carrying on away from the panel spends the wait down rather than
    /// starting it afresh — the further it gets, the sooner the deadline it is already past.
    private func wait(clearance: CGFloat) -> TimeInterval {
        let reach = max(bail - slop, 1)
        let gone = min((clearance - slop) / reach, 1)
        return grace * TimeInterval(1 - gone)
    }

    private mutating func close() -> Action {
        reset()
        return .close
    }
}
