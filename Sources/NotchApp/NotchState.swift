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

    /// Region (in window/content coordinates, origin bottom-left) that should receive mouse events.
    /// Everything outside this rect is click-through so the desktop stays usable.
    var hittableRect: CGRect {
        let size = isOpen ? openSize : closedSize
        let x = (windowSize.width - size.width) / 2
        let y = windowSize.height - size.height
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }
}
