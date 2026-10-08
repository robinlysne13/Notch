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
/// What separates them is rest. Only a pointer that actually stops on the chrome — or clicks or
/// scrolls on it — commits the panel; one still travelling never does, however long it happens to
/// be over the chrome. That distinction matters because opening the panel grows the chrome from
/// the notch to the whole panel, so "time spent inside" on its own says very little.
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
    /// How long a committed panel holds once the pointer is properly clear of it.
    var grace: TimeInterval = 0.5

    private(set) var phase: Phase = .closed
    /// Where the pointer settled and when — the pair that decides resting from travelling.
    private var restAnchor: CGPoint = .zero
    private var restSince: Date = .distantFuture
    /// When a committed panel, left behind, is due to close.
    private var closeDue: Date?

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
            if chrome.insetBy(dx: -slop, dy: -slop).contains(pointer) {
                closeDue = nil
                return .none
            }
            guard let due = closeDue else {
                closeDue = now.addingTimeInterval(grace)
                return .none
            }
            return now >= due ? close() : .none
        }
    }

    /// A click or a scroll on the chrome settles the question outright.
    mutating func acted() {
        closeDue = nil
        if phase == .passing { phase = .committed }
    }

    /// Opening by other means — a file drag aimed at the notch — is deliberate by definition.
    mutating func openDeliberately() {
        phase = .committed
        closeDue = nil
    }

    /// Dismiss regardless of what the pointer is doing.
    mutating func reset() {
        phase = .closed
        closeDue = nil
        restSince = .distantFuture
    }

    private mutating func entered(pointer: CGPoint, now: Date) -> Action {
        closeDue = nil
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

    private mutating func close() -> Action {
        reset()
        return .close
    }
}
