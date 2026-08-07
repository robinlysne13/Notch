import AppKit
import SwiftUI

/// Hosting view that only accepts mouse events within the notch's current hittable region,
/// leaving the rest of the (transparent) window click-through.
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    var state: NotchState?

    override func hitTest(_ point: NSPoint) -> NSView? {
        // `point` is in the superview's coordinate space; convert into ours.
        let local = convert(point, from: superview)
        guard let state, state.chromeRect(in: bounds, flipped: isFlipped).contains(local) else {
            return nil
        }
        return super.hitTest(point)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NSPanel?
    private var state: NotchState?
    private var pointerMonitors: [Any] = []
    private var dragPoll: Timer?
    private var dragPasteboardCount = 0
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
        // The window is far larger than the visible chrome and sits above the menu bar, so it
        // must stay transparent to clicks until the pointer is actually over the notch.
        panel.ignoresMouseEvents = true

        // Pin to the top-center of the target screen.
        let originX = screen.frame.midX - geometry.window.width / 2
        let originY = screen.frame.maxY - geometry.window.height
        panel.setFrameOrigin(NSPoint(x: originX, y: originY))
        panel.orderFrontRegardless()

        self.panel = panel
        startPointerTracking()
        media.start()
        LaunchAtLogin.syncOnLaunch()
    }

    func applicationWillTerminate(_ notification: Notification) {
        pointerMonitors.forEach(NSEvent.removeMonitor)
        pointerMonitors.removeAll()
        dragPoll?.invalidate()
        dragPoll = nil
    }

    // MARK: Pointer tracking

    /// `ignoresMouseEvents` is the only thing that genuinely lets clicks reach the windows below —
    /// a `hitTest` returning nil still consumes the click. But a window that ignores mouse events
    /// never sees hover either, so the notch can't open itself: the pointer has to be tracked
    /// globally and the panel switched on only while the cursor is over the chrome.
    private func startPointerTracking() {
        let mask: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .leftMouseDown,
        ]
        // Global fires while other apps are active; local while ours is (context menus, drags).
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }) {
            pointerMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }) {
            pointerMonitors.append(local)
        }
        syncPointer()
    }

    private func handle(_ event: NSEvent) {
        if event.type == .leftMouseDown {
            beginDragWatch()
        } else {
            syncPointer()
        }
    }

    private func syncPointer() {
        guard let panel, let state else { return }
        // Never flip interactivity mid-click — that would abort a scrub or a shelf drag.
        guard NSEvent.pressedMouseButtons == 0 else { return }

        let chrome = state.chromeRect(in: panel.frame, flipped: false)
        let inside = chrome.contains(NSEvent.mouseLocation)
        panel.ignoresMouseEvents = !inside
        guard state.isOpen != inside else { return }
        withAnimation(NotchState.toggle) { state.isOpen = inside }
    }

    // MARK: Drag-to-open

    /// How far outside the collapsed notch a file drag still counts as aimed at the shelf.
    private static let dragCatchInset: CGFloat = 24

    /// A drag session consumes the mouse events `syncPointer` relies on, so hovering the notch
    /// with files can't be seen the usual way. Snapshot the drag pasteboard when the button goes
    /// down; if it changes while the button is held, a drag is in flight and worth polling for.
    private func beginDragWatch() {
        dragPoll?.invalidate()
        dragPasteboardCount = NSPasteboard(name: .drag).changeCount
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated { self?.pollDrag(timer) }
        }
        // .common so it keeps firing inside the drag's tracking run loop.
        RunLoop.main.add(timer, forMode: .common)
        dragPoll = timer
    }

    private func pollDrag(_ timer: Timer) {
        guard let panel, let state else { return timer.invalidate() }
        guard NSEvent.pressedMouseButtons & 1 != 0 else {
            timer.invalidate()
            dragPoll = nil
            syncPointer()
            return
        }
        guard isDraggingFiles else { return }

        // Stay drop-eligible for the whole drag: a window that ignores mouse events can't be a
        // drag destination at all, and one that accepts nothing under the cursor simply lets the
        // drag continue to the window below.
        panel.ignoresMouseEvents = false

        let target = state.chromeRect(in: panel.frame, flipped: false)
            .insetBy(dx: -Self.dragCatchInset, dy: -Self.dragCatchInset)
        guard target.contains(NSEvent.mouseLocation), !state.isOpen else { return }
        // The shelf is the only tab with a drop target, so aim the drag at something useful.
        withAnimation(NotchState.toggle) {
            state.selectedTab = .shelf
            state.isOpen = true
        }
    }

    private var isDraggingFiles: Bool {
        let pasteboard = NSPasteboard(name: .drag)
        guard pasteboard.changeCount != dragPasteboardCount else { return false }
        return pasteboard.canReadObject(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        )
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
