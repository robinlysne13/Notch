import Foundation

/// Where playback actually is, reconstructed between the player's readings.
///
/// The players only report the playhead when asked, and asking is slow: a round trip through
/// AppleScript to Spotify measures a little over 200ms, so the number that comes back describes a
/// moment already in the past. Filing it as true "now" is what left the lyrics running behind the
/// song. Here a reading is filed at the instant it was *sampled*, the estimate runs on the wall
/// clock from there, and each later reading is folded in rather than overwriting it.
struct Playhead {
    /// How far a reading may disagree with the running estimate before it counts as a jump — a
    /// seek, a track change, a resume — rather than drift to be eased out.
    static let snapThreshold: Double = 0.75
    /// The share of a disagreement one reading corrects. Readings arrive with the uncertainty of
    /// the round trip they came back over, so closing half the gap lets several of them average
    /// out what a single one would turn into jitter around a lyric boundary.
    static let correctionRate: Double = 0.5

    /// Seconds into the track, as shown. Moves on every tick; never runs backwards mid-playback.
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var isPlaying: Bool = false

    /// The reading the estimate runs from: a position, and the instant it was true.
    private var anchor: (position: Double, at: Date)?

    var isAnchored: Bool { anchor != nil }

    // MARK: Reading the estimate

    /// Where the playhead should be at `now`, given the last reading and the time since.
    func estimate(at now: Date) -> Double {
        guard let anchor else { return position }
        guard isPlaying else { return clamped(anchor.position) }
        return clamped(anchor.position + now.timeIntervalSince(anchor.at))
    }

    /// Move `position` up to the estimate for `now`.
    ///
    /// While playing the shown position only ever moves forward. A reading that lands behind the
    /// estimate pulls the *anchor* back instead, and the position waits where it is for the clock
    /// to catch up — stepping it backwards would bounce the highlighted lyric up to the previous
    /// line, which reads as a glitch even when the correction is a tenth of a second.
    mutating func advance(to now: Date) {
        let estimate = estimate(at: now)
        position = isPlaying ? max(position, estimate) : estimate
    }

    // MARK: Taking readings

    /// Fold in a position read from the player, as it was at `sampledAt`.
    mutating func observe(position reading: Double, sampledAt: Date) {
        let reading = clamped(reading)
        // Paused, or with nothing to compare against, the reading is simply the truth.
        guard isPlaying, let anchor else { return snap(to: reading, at: sampledAt) }

        // Compared at the instant the reading describes, not at "now" — that difference is the
        // whole point of carrying `sampledAt` around.
        let expected = clamped(anchor.position + sampledAt.timeIntervalSince(anchor.at))
        let error = reading - expected
        if abs(error) > Self.snapThreshold {
            snap(to: reading, at: sampledAt)
        } else {
            self.anchor = (expected + error * Self.correctionRate, sampledAt)
        }
    }

    /// Take a position as gospel: a seek, a track change, or a player event that reported one.
    mutating func snap(to reading: Double, at instant: Date) {
        let reading = clamped(reading)
        anchor = (reading, instant)
        position = reading
    }

    mutating func setPlaying(_ playing: Bool, at instant: Date) {
        guard playing != isPlaying else { return }
        // Freeze at — or resume from — wherever the estimate had reached.
        let current = estimate(at: instant)
        isPlaying = playing
        anchor = (current, instant)
        position = current
    }

    /// A new track's length. Shortening it pulls the playhead inside the new track.
    mutating func setDuration(_ seconds: Double) {
        duration = max(seconds, 0)
        position = clamped(position)
        if let anchor { self.anchor = (clamped(anchor.position), anchor.at) }
    }

    /// Nothing is playing; forget everything.
    mutating func reset() {
        position = 0
        duration = 0
        isPlaying = false
        anchor = nil
    }

    /// Duration of 0 means "unknown" — the players report it that way for streams — so it only
    /// caps the playhead once it is known.
    private func clamped(_ seconds: Double) -> Double {
        guard duration > 0 else { return max(seconds, 0) }
        return min(max(seconds, 0), duration)
    }
}
