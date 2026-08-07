import SwiftUI

enum NotchTab: Hashable {
    case nowPlaying
    case shelf
}

/// Shared geometry + open/closed state, read by both SwiftUI and the AppKit hosting view.
@MainActor
final class NotchState: ObservableObject {
    @Published var isOpen = false
    @Published var selectedTab: NotchTab = .nowPlaying

    /// Size of the notch chrome when collapsed (matches the hardware notch when present).
    let closedSize: CGSize
    /// Size of the expanded panel.
    let openSize: CGSize
    /// Size of the host window (must contain the open panel with margin).
    let windowSize: CGSize

    init(closedSize: CGSize, openSize: CGSize, windowSize: CGSize) {
        self.closedSize = closedSize
        self.openSize = openSize
        self.windowSize = windowSize
    }

    /// Region (in the hosting view's own coordinate space) that should receive mouse events.
    /// Everything outside this rect is click-through so the desktop stays usable.
    /// The chrome is pinned to the top of the window, so `flipped` decides which end that is —
    /// `NSHostingView` is flipped, an unflipped host would need the far edge instead.
    func hittableRect(in bounds: CGRect, flipped: Bool) -> CGRect {
        let size = isOpen ? openSize : closedSize
        return CGRect(
            x: bounds.midX - size.width / 2,
            y: flipped ? bounds.minY : bounds.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }
}
