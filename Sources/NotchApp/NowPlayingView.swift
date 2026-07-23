import SwiftUI

struct NowPlayingView: View {
    @ObservedObject var media: MediaController

    var body: some View {
        if media.hasTrack {
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
        } else {
            HStack(spacing: 8) {
                Image(systemName: "music.note")
                    .foregroundStyle(.white.opacity(0.5))
                Text("Nothing playing")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .frame(maxWidth: .infinity, minHeight: 48)
        }
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
