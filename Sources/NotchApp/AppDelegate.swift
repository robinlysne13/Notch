import AppKit
import SwiftUI

/// Hosting view that only accepts mouse events within the notch's current hittable region,
/// leaving the rest of the (transparent) window click-through.
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    var state: NotchState?

    override func hitTest(_ point: NSPoint) -> NSView? {
        // `point` is in the superview's coordinate space; convert into ours.
        let local = convert(point, from: superview)
        if let state, state.hittableRect.contains(local) {
            return super.hitTest(point)
        }
        return nil
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NSPanel?
    private var state: NotchState?
    private let media = MediaController()
    private let shelf = ShelfModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let screen = notchedScreen()
        let geometry = computeGeometry(for: screen)

        let state = NotchState(
            closedSize: geometry.closed,
            openSize: geometry.open,
            windowSize: geometry.window
        )
        self.state = state

        let rootView = NotchRootView(state: state, media: media, shelf: shelf)
        let hostingView = PassthroughHostingView(rootView: rootView)
        hostingView.state = state

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: geometry.window),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hostingView
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.ignoresMouseEvents = false

        // Pin to the top-center of the target screen.
        let originX = screen.frame.midX - geometry.window.width / 2
        let originY = screen.frame.maxY - geometry.window.height
        panel.setFrameOrigin(NSPoint(x: originX, y: originY))
        panel.orderFrontRegardless()

        self.panel = panel
        media.start()
        LaunchAtLogin.syncOnLaunch()
    }

    // MARK: Geometry

    private struct Geometry {
        let closed: CGSize
        let open: CGSize
        let window: CGSize
    }

    private func notchedScreen() -> NSScreen {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    private func computeGeometry(for screen: NSScreen) -> Geometry {
        let hasNotch = screen.safeAreaInsets.top > 0
        let notchHeight: CGFloat = hasNotch ? screen.safeAreaInsets.top : 32

        var notchWidth: CGFloat = 200
        if hasNotch,
           let left = screen.auxiliaryTopLeftArea?.width,
           let right = screen.auxiliaryTopRightArea?.width {
            notchWidth = max(120, screen.frame.width - left - right)
        }

        let closed = CGSize(width: notchWidth, height: notchHeight)
        let open = CGSize(width: 440, height: 152 + notchHeight)
        let window = CGSize(
            width: max(open.width, notchWidth) + 80,
            height: open.height + 40
        )
        return Geometry(closed: closed, open: open, window: window)
    }
}
