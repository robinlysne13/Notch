import SwiftUI

/// Song progress with elapsed / remaining times. Click or drag the track to scrub.
struct ProgressBar: View {
    @ObservedObject var media: MediaController

    @State private var isDragging = false
    @State private var isHovering = false
    /// While scrubbing, the bar follows the cursor rather than the (lagging) player position.
    @State private var scrubFraction: Double = 0

    private var fraction: Double {
        if isDragging { return scrubFraction }
        guard media.duration > 0 else { return 0 }
        return min(max(media.position / media.duration, 0), 1)
    }

    private var elapsed: Double { fraction * media.duration }
    private var trackHeight: CGFloat { isHovering || isDragging ? 6 : 3 }

    var body: some View {
        HStack(spacing: 8) {
            time(elapsed)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.16))
                    Capsule()
                        .fill(Color.white.opacity(0.85))
                        .frame(width: fraction * geo.size.width)
                }
                .frame(height: trackHeight)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            isDragging = true
                            scrubFraction = min(max(value.location.x / max(geo.size.width, 1), 0), 1)
                        }
                        .onEnded { _ in
                            media.seek(to: scrubFraction * media.duration)
                            isDragging = false
                        }
                )
            }
            .frame(height: 14)
            time(media.duration - elapsed, prefix: "-")
        }
        .opacity(media.duration > 0 ? 1 : 0.3)
        .disabled(media.duration <= 0)
        .animation(.easeOut(duration: 0.12), value: trackHeight)
        .onHover { isHovering = $0 }
    }

    private func time(_ seconds: Double, prefix: String = "") -> some View {
        Text(media.duration > 0 ? prefix + Self.format(seconds) : "--:--")
            .font(.system(size: 9, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.5))
            .frame(width: 32, alignment: prefix.isEmpty ? .leading : .trailing)
    }

    private static func format(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
