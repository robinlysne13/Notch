import SwiftUI

/// Time-synced lyrics that follow the playhead: the current line is bright, the rest recede, and
/// the list keeps that line centered. Clicking any line jumps playback to it.
struct LyricsView: View {
    @ObservedObject var media: MediaController
    @ObservedObject var lyrics: LyricsProvider

    /// `media.position` already ticks four times a second for the progress bar, so the highlight
    /// rides that rather than running a timer of its own.
    private var currentIndex: Int? {
        guard lyrics.status == .synced else { return nil }
        return LyricsProvider.index(at: media.position, in: lyrics.lines)
    }

    var body: some View {
        Group {
            switch lyrics.status {
            case .synced, .plain:
                lines
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

    private var lines: some View {
        let current = currentIndex
        return ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(lyrics.lines.enumerated()), id: \.offset) { index, line in
                        row(line, index: index, current: current)
                    }
                }
                // Leaves room for the first and last lines to reach the middle of the panel.
                .padding(.vertical, 44)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .mask(fade)
            .onChange(of: current) { _, new in
                guard let new else { return }
                withAnimation(.easeOut(duration: 0.3)) {
                    proxy.scrollTo(new, anchor: .center)
                }
            }
            .onAppear {
                guard let current else { return }
                proxy.scrollTo(current, anchor: .center)
            }
        }
    }

    private func row(_ line: LyricLine, index: Int, current: Int?) -> some View {
        let isCurrent = index == current
        // Before the first line starts there is no current line, so nothing is dimmed yet.
        let isSung = current.map { index < $0 } ?? false
        return Group {
            if line.isGap {
                Image(systemName: "music.note")
                    .font(.system(size: 9))
            } else {
                Text(line.text)
                    .font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(.white.opacity(isCurrent ? 1 : (isSung ? 0.3 : 0.45)))
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            guard lyrics.status == .synced else { return }
            media.seek(to: line.time)
        }
        .id(index)
        .animation(.easeOut(duration: 0.2), value: isCurrent)
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

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.4))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
