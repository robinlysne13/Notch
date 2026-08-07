import SwiftUI

struct NotchRootView: View {
    @ObservedObject var state: NotchState
    @ObservedObject var media: MediaController
    @ObservedObject var shelf: ShelfModel

    /// Read live from `SMAppService` each time the context menu opens, so the toggle stays
    /// truthful if the login item is changed in System Settings.
    private var launchAtLogin: Binding<Bool> {
        Binding(
            get: { LaunchAtLogin.isEnabled },
            set: { LaunchAtLogin.setEnabled($0) }
        )
    }

    var body: some View {
        let size = state.isOpen ? state.openSize : state.closedSize
        ZStack(alignment: .top) {
            NotchShape(
                bottomRadius: state.isOpen ? 22 : 10,
                topRadius: state.isOpen ? 12 : 7
            )
            .fill(Color(nsColor: NSColor(calibratedWhite: 0, alpha: 1)))
            .overlay(alignment: .top) {
                if state.isOpen {
                    openContent
                        .transition(.opacity)
                } else {
                    closedContent
                }
            }
            .frame(width: size.width, height: size.height)
            .contextMenu {
                Toggle("Launch at Login", isOn: launchAtLogin)
            }
        }
        .frame(width: state.windowSize.width, height: state.windowSize.height, alignment: .top)
    }

    // Collapsed: a subtle live indicator when music is playing.
    private var closedContent: some View {
        HStack {
            Spacer()
            if media.isPlaying {
                Image(systemName: "waveform")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.trailing, 10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
    }

    private var openContent: some View {
        VStack(spacing: 10) {
            tabBar
            Group {
                switch state.selectedTab {
                case .nowPlaying:
                    NowPlayingView(media: media)
                case .shelf:
                    ShelfView(shelf: shelf)
                }
            }
        }
        .padding(.top, state.closedSize.height + 6)
        .padding(.horizontal, 18)
        .padding(.bottom, 16)
        .foregroundStyle(.white)
        .frame(width: state.openSize.width, height: state.openSize.height, alignment: .top)
    }

    private var tabBar: some View {
        HStack(spacing: 6) {
            tab("Now Playing", .nowPlaying)
            tab("Shelf", .shelf)
        }
        .frame(maxWidth: .infinity)
    }

    private func tab(_ label: String, _ value: NotchTab) -> some View {
        let selected = state.selectedTab == value
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) { state.selectedTab = value }
        } label: {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(selected ? .white : .white.opacity(0.5))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(Color.white.opacity(selected ? 0.18 : 0.0))
                )
        }
        .buttonStyle(.plain)
    }
}
