import SwiftUI

struct NowPlayingView: View {
    @ObservedObject var media: MediaController
    @ObservedObject var lyrics: LyricsProvider
    @ObservedObject var sonos: SonosController
    @Binding var showLyrics: Bool

    var body: some View {
        if media.hasTrack {
            VStack(spacing: 10) {
                track
                ProgressBar(media: media)
                if showLyrics {
                    LyricsView(media: media, lyrics: lyrics)
                }
            }
        } else {
            empty
        }
    }

    private var track: some View {
        HStack(spacing: 12) {
            artwork
            VStack(alignment: .leading, spacing: 2) {
                Text(media.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(media.artist)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                Text(media.activeApp)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
            }
            Spacer(minLength: 0)
            controls
        }
    }

    /// A pair of separate notes. SF Symbols has no two-note glyph — `music.quarternote.3` is a
    /// trio — so the pair is composed from the single-note symbol, the second nudged up so the
    /// two don't read as one smudge at 9pt.
    private var noteIcon: some View {
        HStack(spacing: 1) {
            Image(systemName: "music.note")
            Image(systemName: "music.note")
                .offset(y: -1.5)
        }
        .font(.system(size: 9, weight: .medium))
    }

    /// How far the lyrics toggle rides above the play button. Just clears it, so the two read as
    /// one cluster rather than a stray button near the title.
    private static let lyricsToggleRise: CGFloat = -20

    /// Stowing the lyrics panel shrinks the notch back, so it animates with the same spring the
    /// panel uses to open and close.
    private var lyricsToggle: some View {
        Button {
            withAnimation(NotchState.toggle) { showLyrics.toggle() }
        } label: {
            noteIcon
                .foregroundStyle(.white.opacity(showLyrics ? 1 : 0.45))
                .frame(width: 22, height: 20)
                .background(
                    Circle().fill(Color.white.opacity(showLyrics ? 0.18 : 0))
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(showLyrics ? "Hide lyrics" : "Show lyrics")
    }

    /// Which rooms play along, as a checklist. Only while a Sonos group is what's showing: the
    /// Spotify and local sources have no say over Sonos grouping. Rides above the skip-forward
    /// button the way the lyrics toggle rides above play.
    @ViewBuilder
    private var speakersMenu: some View {
        if media.activeSource == .sonos, sonos.rooms.count > 1 {
            let grouped = sonos.activeMembers.count > 1
            Menu {
                ForEach(sonos.rooms) { room in
                    Toggle(room.name, isOn: Binding(
                        get: { sonos.activeMembers.contains { $0.uuid == room.uuid } },
                        set: { sonos.setGrouped(room, $0) }
                    ))
                    .disabled(room.uuid == sonos.activeGroup?.coordinatorUUID)
                }
            } label: {
                Image(systemName: "hifispeaker.2.fill")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(grouped ? 1 : 0.45))
                    .frame(width: 22, height: 20)
                    .background(
                        Circle().fill(Color.white.opacity(grouped ? 0.18 : 0))
                    )
                    .contentShape(Circle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Speakers")
        }
    }

    private var empty: some View {
        HStack(spacing: 8) {
            Image(systemName: "music.note")
                .foregroundStyle(.white.opacity(0.5))
            Text("Nothing playing")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity, minHeight: 68)
    }

    private var artwork: some View {
        Group {
            if let image = media.artwork {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.white.opacity(0.12)
                    Image(systemName: "music.note")
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .frame(width: 68, height: 68)
        .clipShape(Rectangle())
    }

    private var controls: some View {
        HStack(spacing: 14) {
            controlButton("backward.fill") { media.previous() }
            controlButton(media.isPlaying ? "pause.fill" : "play.fill", size: 18) { media.playPause() }
                // Floated over the play button rather than stacked above it: a VStack would push
                // play/pause down and leave it out of line with the two skip buttons.
                .overlay(alignment: .top) {
                    lyricsToggle.offset(y: Self.lyricsToggleRise)
                }
            controlButton("forward.fill") { media.next() }
                .overlay(alignment: .top) {
                    speakersMenu.offset(y: Self.lyricsToggleRise)
                }
        }
    }

    private func controlButton(_ symbol: String, size: CGFloat = 14, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
