import Foundation

/// One finished stretch of focus, in the shape the dashboard keeps them in.
///
/// The field names are the web app's (`life-dashboard-app/lib/focus.ts`) and must stay that way:
/// both ends read and write the one list, so a stretch timed at the notch is counted by the
/// thirty-day history on the Focus page without anything having to translate it.
struct FocusSession: Codable, Identifiable, Equatable {
    /// Unique across devices — the web's merge addresses list items by `id`, so a session added
    /// here is recognised as an addition rather than a conflicting edit of somebody else's.
    let id: String
    var label: String
    var minutes: Int
    /// The day it ended, `yyyy-mm-dd`, in whatever zone the clock was in.
    var date: String
    /// When it ended, milliseconds since the epoch.
    var endedAt: Double

    init(id: String = FocusSession.freshID(), label: String, minutes: Int, endedAt: Date) {
        self.id = id
        self.label = label
        self.minutes = minutes
        self.date = FocusSession.day(of: endedAt)
        self.endedAt = endedAt.timeIntervalSince1970 * 1000
    }

    /// Short and random, like the web app's `uid()`. It only has to not collide.
    static func freshID() -> String {
        let alphabet = "abcdefghijklmnopqrstuvwxyz0123456789"
        let random = String((0..<8).map { _ in alphabet.randomElement()! })
        return random + String(Int(Date().timeIntervalSince1970), radix: 36).suffix(4)
    }

    /// `2026-10-11` for the day that moment falls on where you are.
    ///
    /// Local, deliberately: the web's `toISODay` reads the parts off a local `Date`, and a notch
    /// that wrote UTC would file an evening session under tomorrow for anyone west of London.
    static func day(of date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0
        )
    }
}

/// The lengths and the daily goal, as the dashboard holds them. The notch only reads these — the
/// Focus page is where they're set, so there is one answer to what a good day is.
struct FocusSettings: Codable, Equatable {
    var focus: Int = 25
    var short: Int = 5
    var long: Int = 15
    var longEvery: Int = 4
    /// Minutes of focus a day you're aiming for.
    var goal: Int = 120
    var autoStart: Bool = false
    var sound: Bool = true

    static let defaults = FocusSettings()

    /// A settings object written before a field existed still has to answer for it, so every key
    /// is optional on the way in and falls back to the same default the web app uses.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = FocusSettings.defaults
        focus = try container.decodeIfPresent(Int.self, forKey: .focus) ?? fallback.focus
        short = try container.decodeIfPresent(Int.self, forKey: .short) ?? fallback.short
        long = try container.decodeIfPresent(Int.self, forKey: .long) ?? fallback.long
        longEvery = try container.decodeIfPresent(Int.self, forKey: .longEvery) ?? fallback.longEvery
        goal = try container.decodeIfPresent(Int.self, forKey: .goal) ?? fallback.goal
        autoStart = try container.decodeIfPresent(Bool.self, forKey: .autoStart) ?? fallback.autoStart
        sound = try container.decodeIfPresent(Bool.self, forKey: .sound) ?? fallback.sound
    }

    init() {}
}

/// Where the clock is.
///
/// Kept on this Mac only, like the web page's own clock: a timer running at the notch has no
/// business ticking on the phone. Anchored to a moment rather than counted down in memory, so it
/// stays right across sleep, a quit, and the notch being shut — while it runs, `anchor` is the
/// moment it ends (counting down) or the moment it started (counting up); while it is paused,
/// `held` is what it had reached.
struct FocusClock: Codable, Equatable {
    enum Direction: String, Codable {
        case down
        case up
    }

    var dir: Direction = .down
    var running = false
    var anchor: Date?
    /// Seconds remaining (counting down) or elapsed (counting up), while paused.
    var held: TimeInterval = 25 * 60
    /// The countdown length you picked, in seconds.
    var length: TimeInterval = 25 * 60
    var label = ""

    /// The lengths offered up front — the same ones the Focus page puts a tap away.
    static let presets = [15, 25, 45, 60, 90]

    // MARK: Where it has got to

    /// What is left of a countdown. Negative once it has run out.
    func remaining(at now: Date) -> TimeInterval {
        guard running, let anchor else { return held }
        return anchor.timeIntervalSince(now)
    }

    /// How much focus this stretch has accumulated so far.
    func elapsed(at now: Date) -> TimeInterval {
        switch dir {
        case .down:
            return length - max(0, remaining(at: now))
        case .up:
            guard running, let anchor else { return held }
            return now.timeIntervalSince(anchor)
        }
    }

    /// What the face reads.
    func shown(at now: Date) -> TimeInterval {
        switch dir {
        case .down: return max(0, remaining(at: now))
        case .up: return max(0, elapsed(at: now))
        }
    }

    /// Has a countdown reached zero?
    func isDone(at now: Date) -> Bool {
        dir == .down && remaining(at: now) <= 0
    }

    /// How much of the ring to draw, 0...1.
    ///
    /// Counting down it is how much of the stretch is left, so the ring empties as the time goes.
    /// Counting up there is no end to be a fraction of, so it is the second hand sweeping the
    /// minute — plainly ticking, without pretending to measure progress towards a finish line
    /// that doesn't exist.
    func fraction(at now: Date) -> Double {
        let shown = shown(at: now)
        switch dir {
        case .down:
            guard length > 0 else { return 0 }
            return min(1, max(0, shown / length))
        case .up:
            return shown.truncatingRemainder(dividingBy: 60) / 60
        }
    }

    // MARK: Moving it

    func started(at now: Date) -> FocusClock {
        var next = self
        next.running = true
        // Counting up resumes by backdating the start, so the pause isn't counted as focus.
        next.anchor = dir == .down
            ? now.addingTimeInterval(max(0, held))
            : now.addingTimeInterval(-held)
        return next
    }

    func paused(at now: Date) -> FocusClock {
        var next = self
        next.held = max(0, dir == .down ? remaining(at: now) : elapsed(at: now))
        next.running = false
        next.anchor = nil
        return next
    }

    /// Back to the top, keeping nothing.
    func reset() -> FocusClock {
        var next = self
        next.running = false
        next.anchor = nil
        next.held = dir == .down ? length : 0
        return next
    }

    /// Which way it runs. Switching puts the clock back to the top either way — the minutes left
    /// of a countdown mean nothing as a stopwatch reading.
    func switched(to dir: Direction) -> FocusClock {
        guard dir != self.dir else { return self }
        var next = self
        next.dir = dir
        next.running = false
        next.anchor = nil
        next.held = dir == .down ? length : 0
        return next
    }

    /// A countdown length, in minutes. Reaches a clock that is not running.
    func withLength(minutes: Int) -> FocusClock {
        let length = TimeInterval(min(600, max(1, minutes)) * 60)
        var next = self
        next.dir = .down
        next.length = length
        next.running = false
        next.anchor = nil
        next.held = length
        return next
    }
}

// MARK: - Adding it up

/// A day in the thirty behind you, and the minutes focused on it.
struct FocusDay: Equatable {
    let key: String
    let minutes: Int
}

enum FocusMaths {
    /// The last `n` days, oldest first, with every day present — including the ones you did
    /// nothing on. A chart drawn from only the days that have sessions would space them evenly
    /// and quietly turn a fortnight off into a flat week.
    static func lastDays(
        _ sessions: [FocusSession],
        _ n: Int,
        ending today: Date = Date(),
        calendar: Calendar = .current
    ) -> [FocusDay] {
        var minutes: [String: Int] = [:]
        for session in sessions {
            minutes[session.date, default: 0] += session.minutes
        }
        return (0..<n).compactMap { i in
            guard let day = calendar.date(byAdding: .day, value: -(n - 1 - i), to: today) else {
                return nil
            }
            let key = FocusSession.day(of: day, calendar: calendar)
            return FocusDay(key: key, minutes: minutes[key] ?? 0)
        }
    }

    /// Minutes focused on a given day.
    static func minutes(_ sessions: [FocusSession], on day: String) -> Int {
        sessions.filter { $0.date == day }.reduce(0) { $0 + $1.minutes }
    }

    /// How many days up to and including today you have hit the goal on, counting back until you
    /// missed one. Today not being done yet doesn't break it: a streak you are still working on
    /// reads from yesterday back.
    static func goalStreak(_ days: [FocusDay], goal: Int) -> Int {
        guard goal > 0 else { return 0 }
        var streak = 0
        for (i, day) in days.enumerated().reversed() {
            if day.minutes >= goal {
                streak += 1
            } else if i != days.count - 1 {
                break
            }
        }
        return streak
    }

    /// `04:35` — a length on a clock face.
    static func mmss(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded(.up))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// `1h 20m` — a length in prose.
    static func hm(_ minutes: Int) -> String {
        let hours = minutes / 60
        let rest = minutes % 60
        guard hours > 0 else { return "\(rest)m" }
        return rest > 0 ? "\(hours)h \(rest)m" : "\(hours)h"
    }
}
