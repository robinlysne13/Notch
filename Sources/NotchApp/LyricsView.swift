import AppKit
import SwiftUI

/// Time-synced lyrics that follow the playhead: the current line is bright, the rest recede, and
/// the list keeps that line centered. Clicking any line jumps playback to it.
struct LyricsView: View {
    @ObservedObject var media: MediaController
    @ObservedObject var lyrics: LyricsProvider

    /// `media.position` already ticks ten times a second for the progress bar, so the highlight
    /// rides that rather than running a timer of its own.
    private var currentIndex: Int? {
        guard lyrics.status == .synced else { return nil }
        return LyricsProvider.index(at: media.position, in: lyrics.lines)
    }

    var body: some View {
        Group {
            switch lyrics.status {
            case .synced, .plain:
                // Only the line index crosses into the list, and it is compared before anything
                // is redrawn — so the nine playhead updates a second that land mid-line cost a
                // comparison rather than a layout pass through every line of the sheet.
                LyricsList(
                    lines: lyrics.lines,
                    current: currentIndex,
                    canSeek: lyrics.status == .synced,
                    seek: { media.seek(to: $0) }
                )
                .equatable()
            case .loading:
                message("Looking for lyrics…")
            case .instrumental:
                message("Instrumental")
            case .unavailable:
                message("No lyrics found")
            case .idle:
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Requested here rather than on every track change, so nothing is asked of the lyrics
        // service unless the panel is actually open.
        .onAppear { loadCurrentTrack() }
        .onChange(of: media.title) { _, _ in loadCurrentTrack() }
        .onChange(of: media.artist) { _, _ in loadCurrentTrack() }
        .onChange(of: media.hasTrack) { _, hasTrack in
            if hasTrack { loadCurrentTrack() } else { lyrics.clear() }
        }
    }

    private func loadCurrentTrack() {
        guard media.hasTrack else {
            lyrics.clear()
            return
        }
        lyrics.load(title: media.title, artist: media.artist, duration: media.duration)
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.4))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The sheet itself, with the highlight on `current`.
///
/// The sheet does not scroll — it is laid out once and slid. A `ScrollViewReader` was what made
/// the follow look restless: `scrollTo` is a programmatic scroll, so a line arriving while the
/// last move was still running restarted it from a standstill instead of carrying the motion
/// through, and masking a tall scroll view recomposites all of it every frame. Moving an offset
/// instead is a single transform the compositor can interpolate, and retargeting a spring
/// mid-flight keeps the velocity it already had, so closely sung lines read as one continuous
/// drift rather than a series of lurches.
///
/// Takes plain values rather than the controller so that `==` can decide whether a redraw is
/// needed: the playhead moves ten times a second, but the line it points at changes once every
/// few seconds, and only the latter means anything here.
private struct LyricsList: View, Equatable {
    let lines: [LyricLine]
    let current: Int?
    let canSeek: Bool
    let seek: (Double) -> Void

    /// Measured line heights. Lines wrap, so the only way to centre one is to know them.
    @State private var heights: [Int: CGFloat] = [:]
    @State private var viewport: CGFloat = 0
    /// How far the sheet is slid to follow the song. Each move chooses its own curve.
    @State private var offsetY: CGFloat = 0
    /// Where the reader has dragged the sheet to, overriding the follow until they stop. Nil
    /// means the sheet is following the song.
    @State private var browsed: CGFloat?
    @State private var resumeFollowing: DispatchWorkItem?
    @State private var wheelMonitor: Any?
    /// The panel in window coordinates, so a scroll elsewhere in the notch is left alone.
    @State private var panel: CGRect = .zero

    private static let spacing: CGFloat = 9
    /// `estimatedRow` is one unwrapped line of 16pt text, standing in until a line is measured.
    private static let layout = LyricsLayout(spacing: spacing, estimatedRow: 20)

    /// The handover from one line to the next.  Eased rather than springy: text that wobbles as
    /// it arrives reads as unsettled.
    private static let handover: Animation = .easeInOut(duration: 0.3)
    /// The slide that keeps the current line centred. An interpolating spring with no bounce, so
    /// it carries its velocity into the next line instead of stopping dead between the two, and
    /// comes to rest without overshooting.
    private static let glide: Animation = .interpolatingSpring(duration: 0.75, bounce: 0)
    /// How long the sheet stays where it was left before it returns to the song. Long enough to
    /// read the verse you scrolled back to, short enough that it comes back on its own.
    private static let resumeDelay: Double = 5
    /// How far the highlight can move and still be glided to. A tap or a scrub can move it
    /// dozens of lines at once, and racing the sheet through everything in between is a blur —
    /// past this it cuts straight there, which reads as arriving rather than as a scramble.
    private static let glideLimit = 4

    static func == (a: LyricsList, b: LyricsList) -> Bool {
        a.current == b.current && a.canSeek == b.canSeek && a.lines == b.lines
    }

    var body: some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: Self.spacing) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    row(line, index: index)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .offset(y: browsed ?? offsetY)
            // A re-measure or a resize is not a move: it settles where the sheet already was,
            // so it is placed rather than glided.
            .onPreferenceChange(RowHeights.self) { measured in
                heights = measured
                offsetY = centring(on: current, heights: measured, viewport: viewport)
            }
            .onChange(of: geo.size.height, initial: true) { _, height in
                viewport = height
                offsetY = centring(on: current, heights: heights, viewport: height)
            }
            .onChange(of: geo.frame(in: .global), initial: true) { _, frame in
                panel = frame
            }
            .onChange(of: current) { old, new in
                let step = old.map { abs((new ?? 0) - $0) } ?? Int.max
                let target = centring(on: new, heights: heights, viewport: viewport)
                // Kept up to date even while the reader is browsing, so that when the sheet does
                // return to the song it returns to the line being sung by then.
                guard browsed == nil, step <= Self.glideLimit else {
                    offsetY = target
                    return
                }
                withAnimation(Self.glide) { offsetY = target }
            }
            // A new sheet has nothing in common with the measurements of the old one.
            .onChange(of: lines) { _, _ in
                heights = [:]
                offsetY = centring(on: current, heights: [:], viewport: viewport)
            }
        }
        .clipped()
        // The sheet is taller than the panel and slides within it, and `clipped` only stops the
        // overflow being drawn — it stays hit-testable. Without a content shape of the panel's
        // own, the lyrics above and below reach over the controls: clicking the note button hit
        // whichever line was covering it and seeked to its timestamp, restarting the song.
        .contentShape(Rectangle())
        .mask(fade)
        .onAppear { watchForScrolling() }
        .onDisappear {
            if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
            wheelMonitor = nil
            resumeFollowing?.cancel()
        }
    }

    // MARK: Browsing by hand

    /// SwiftUI has no scroll-wheel event of its own, and an `NSView` overlay that caught them
    /// would have to be hit-testable, which would take the clicks on the lines with it. A local
    /// monitor sees the wheel without standing in front of anything.
    private func watchForScrolling() {
        guard wheelMonitor == nil else { return }
        wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard covers(event) else { return event }
            slide(by: event.scrollingDeltaY)
            return nil
        }
    }

    private func covers(_ event: NSEvent) -> Bool {
        // Permissive if the window cannot be resolved: the monitor only runs while the panel is
        // on screen, and swallowing a scroll is friendlier than ignoring one.
        guard let content = event.window?.contentView else { return true }
        // AppKit measures from the bottom left, SwiftUI's global space from the top left.
        let point = CGPoint(
            x: event.locationInWindow.x,
            y: content.bounds.height - event.locationInWindow.y
        )
        return panel.contains(point)
    }

    /// Move the sheet by hand, and hold it there briefly before it goes back to the song.
    private func slide(by delta: CGFloat) {
        resumeFollowing?.cancel()
        let from = browsed ?? offsetY
        browsed = Self.layout.clamped(
            from + delta,
            count: lines.count,
            in: viewport,
            heights: heights
        )
        let work = DispatchWorkItem {
            withAnimation(Self.glide) { browsed = nil }
        }
        resumeFollowing = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.resumeDelay, execute: work)
    }

    /// Back to following the song, now — a tap has just moved the playhead to a line.
    private func follow() {
        resumeFollowing?.cancel()
        resumeFollowing = nil
        browsed = nil
    }

    private func centring(on index: Int?, heights: [Int: CGFloat], viewport: CGFloat) -> CGFloat {
        Self.layout.offset(centring: index, of: lines.count, in: viewport, heights: heights)
    }

    private func row(_ line: LyricLine, index: Int) -> some View {
        let isCurrent = index == current
        // Before the first line starts there is no current line, so nothing is dimmed yet.
        let isSung = current.map { index < $0 } ?? false
        return Group {
            if line.isGap {
                Image(systemName: "music.note")
                    .font(.system(size: 11))
            } else {
                text(line.text, isCurrent: isCurrent)
            }
        }
        .foregroundStyle(.white.opacity(isCurrent ? 1 : (isSung ? 0.3 : 0.45)))
        // A fraction of a size, which is enough to read as the line stepping forward to be sung
        // and the one before it settling back.
        .scaleEffect(isCurrent ? 1 : 0.98, anchor: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HeightReporter(index: index))
        .contentShape(Rectangle())
        .onTapGesture {
            guard canSeek else { return }
            // The seek moves the playhead onto this line, which the follow then glides to.
            follow()
            seek(line.time)
        }
        // Keyed on the whole index rather than on this row's own state, so the line taking over
        // and the line handing off animate together — the dimming of the line just sung used to
        // snap, because only `isCurrent` was being watched.
        .animation(Self.handover, value: current)
    }

    /// The line in both weights, stacked and crossfaded.
    ///
    /// SwiftUI cannot interpolate a font weight: it cuts from regular to semibold the instant the
    /// line becomes current, which is the jolt in the middle of an otherwise smooth handover. And
    /// on a line long enough to wrap, the bolder text can need an extra row, which would change
    /// the measurements the sheet is positioned by as it arrives. Drawing both weights and fading
    /// between them settles both — the weight comes up gradually, and the row keeps the height of
    /// the taller of the two no matter which is showing.
    ///
    /// Both copies are laid out whichever is visible, so one of them is hidden from
    /// accessibility; otherwise VoiceOver reads every line of the sheet twice.
    private func text(_ string: String, isCurrent: Bool) -> some View {
        ZStack(alignment: .leading) {
            styled(string, weight: .regular).opacity(isCurrent ? 0 : 1)
            styled(string, weight: .semibold).opacity(isCurrent ? 1 : 0)
                .accessibilityHidden(true)
        }
    }

    private func styled(_ string: String, weight: Font.Weight) -> some View {
        Text(string)
            .font(.system(size: 16, weight: weight))
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Softens both edges so lines enter and leave instead of being cut off.
    private var fade: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.22),
                .init(color: .black, location: 0.78),
                .init(color: .clear, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

/// Reports one line's measured height up to the list.
private struct HeightReporter: View {
    let index: Int

    var body: some View {
        GeometryReader { geo in
            Color.clear.preference(key: RowHeights.self, value: [index: geo.size.height])
        }
    }
}

private struct RowHeights: PreferenceKey {
    static let defaultValue: [Int: CGFloat] = [:]

    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}
