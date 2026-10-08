import SwiftUI

struct NowPlayingView: View {
    @ObservedObject var media: MediaController
    @ObservedObject var lyrics: LyricsProvider
    @ObservedObject var library: SpotifyLibrary
    @Binding var showLyrics: Bool

    var body: some View {
        if media.hasTrack {
            VStack(spacing: 10) {
                track
                if let error = library.lastError {
                    Text(error)
                        .font(.system(size: 9))
                        .foregroundStyle(.orange.opacity(0.9))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ProgressBar(media: media)
                if showLyrics {
                    LyricsView(media: media, lyrics: lyrics)
                }
            }
            // Keeps the heart showing the playing track's real state.
            .onAppear { library.follow(trackID: media.trackID) }
            .onChange(of: media.trackID) { _, id in library.follow(trackID: id) }
        } else {
            empty
        }
    }

    /// Only Spotify can be liked from here. Music exposes `favorited` over AppleScript, but that
    /// is a rating rather than a library add, so the heart stays hidden there.
    private var showsLike: Bool {
        media.activeApp == "Spotify" && !media.trackID.isEmpty
    }

    /// Spotify's own green, so a liked track reads the same here as it does in their app.
    private static let likedGreen = Color(red: 0.11, green: 0.73, blue: 0.33)

    private static let likeToggleRise: CGFloat = -20

    private var likeToggle: some View {
        Button {
            Task { await library.toggle() }
        } label: {
            Image(systemName: library.state == .liked ? "heart.fill" : "heart")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(library.state == .liked ? Self.likedGreen : .white.opacity(0.45))
                .frame(width: 20, height: 20)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(library.isBusy)
        .help(library.state == .liked ? "Remove from Liked Songs" : "Add to Liked Songs")
        .animation(.easeOut(duration: 0.15), value: library.state)
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

    /// A beamed pair of eighth notes. SF Symbols has no beamed glyph — `music.note` is a single
    /// flagged note and `music.quarternote.3` is three unbeamed ones — so it is drawn.
    private var noteIcon: some View {
        BeamedNotes().frame(width: 13, height: 11)
    }

    /// How far the lyrics toggle sits below the play button. Just clears it, so the two read as
    /// one cluster rather than a stray button under the title.
    private static let lyricsToggleDrop: CGFloat = 20

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
                // Floated over the play button rather than stacked under it: a VStack would push
                // play/pause up and leave it out of line with the two skip buttons.
                .overlay(alignment: .top) {
                    if showsLike {
                        likeToggle.offset(y: Self.likeToggleRise)
                    }
                }
                .overlay(alignment: .bottom) {
                    lyricsToggle.offset(y: Self.lyricsToggleDrop)
                }
            controlButton("forward.fill") { media.next() }
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

/// Two eighth notes joined by a beam across their stems — the "♫" shape.
///
/// Drawn rather than taken from SF Symbols, which has no beamed pair. Proportions are relative
/// to the frame, so the one shape stays correct at any size.
private struct BeamedNotes: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width, h = rect.height
        let headW = w * 0.42
        let headH = h * 0.30
        // Never let the stems thin out to a hairline at small sizes.
        let stem = max(w * 0.095, 1)
        let beamH = h * 0.20

        let leftHead = CGRect(x: 0, y: h - headH, width: headW, height: headH)
        let rightHead = CGRect(x: w - headW, y: h - headH, width: headW, height: headH)
        path.addEllipse(in: leftHead)
        path.addEllipse(in: rightHead)

        // Stems rise from the right edge of each head, as they do in engraved notation.
        let leftStem = leftHead.maxX - stem
        let rightStem = rightHead.maxX - stem
        path.addRect(CGRect(x: leftStem, y: 0, width: stem, height: h - headH / 2))
        path.addRect(CGRect(x: rightStem, y: 0, width: stem, height: h - headH / 2))
        path.addRect(CGRect(x: leftStem, y: 0, width: rightStem + stem - leftStem, height: beamH))
        return path
    }
}
