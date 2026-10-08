import SwiftUI

enum NotchTab: Hashable {
    case nowPlaying
    case codes
    case shelf
}

/// Shared geometry + open/closed state, read by both SwiftUI and the AppKit hosting view.
@MainActor
final class NotchState: ObservableObject {
    /// Expand/collapse animation. Owned here because the pointer tracking that drives `isOpen`
    /// lives in `AppDelegate`, not in the view.
    static let toggle = Animation.spring(response: 0.35, dampingFraction: 0.78)

    @Published var isOpen = false
    @Published var selectedTab: NotchTab = .nowPlaying

    /// Size of the notch chrome when collapsed (matches the hardware notch when present).
    private(set) var closedSize: CGSize
    /// Size of the expanded panel.
    private(set) var openSize: CGSize
    /// Size of the host window (must contain the open panel with margin).
    private(set) var windowSize: CGSize

    init(closedSize: CGSize, openSize: CGSize, windowSize: CGSize) {
        self.closedSize = closedSize
        self.openSize = openSize
        self.windowSize = windowSize
    }

    func updateSizes(closed: CGSize, open: CGSize, window: CGSize) {
        closedSize = closed
        openSize = open
        windowSize = window
    }

    /// The notch chrome's rect within `bounds`, which may be the hosting view's bounds or the
    /// panel's screen frame. The chrome is pinned to the top edge and horizontally centered, so
    /// `flipped` decides which end is "top" — `NSHostingView` is flipped, screen space is not.
    func chromeRect(in bounds: CGRect, flipped: Bool) -> CGRect {
        let size = isOpen ? openSize : closedSize
        return CGRect(
            x: bounds.midX - size.width / 2,
            y: flipped ? bounds.minY : bounds.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }
}
