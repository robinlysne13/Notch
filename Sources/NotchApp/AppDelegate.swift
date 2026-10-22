import AppKit
import CoreGraphics
import SwiftUI

/// Hosting view that only accepts mouse events within the notch's current hittable region,
/// leaving the rest of the (transparent) window click-through. Also owns file drops: the shelf
/// view doesn't exist until the notch opens mid-drag, and registering dragged types that late
/// isn't seen by the in-flight drag session — so the types must be registered here, at launch.
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    var state: NotchState?
    var shelf: ShelfModel?

    private static var fileURLOptions: [NSPasteboard.ReadingOptionKey: Any] {
        [.urlReadingFileURLsOnly: true]
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerForDraggedTypes([.fileURL])
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // `point` is in the superview's coordinate space; convert into ours.
        let local = convert(point, from: superview)
        guard let state, state.chromeRect(in: bounds, flipped: isFlipped).contains(local) else {
            return nil
        }
        return super.hitTest(point)
    }

    // MARK: NSDraggingDestination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropOperation(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropOperation(for: sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        shelf?.isDropTargeted = false
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        shelf?.isDropTargeted = false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        shelf?.isDropTargeted = false
        guard let shelf,
              let urls = sender.draggingPasteboard.readObjects(
                  forClasses: [NSURL.self], options: Self.fileURLOptions
              ) as? [URL],
              !urls.isEmpty
        else { return false }
        urls.forEach(shelf.add)
        return true
    }

    /// Accept file drags over the notch chrome; return `[]` elsewhere so the drag falls through
    /// to whatever is below the transparent window.
    private func dropOperation(for sender: NSDraggingInfo) -> NSDragOperation {
        let local = convert(sender.draggingLocation, from: nil)
        guard let state,
              state.chromeRect(in: bounds, flipped: isFlipped).contains(local),
              sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: Self.fileURLOptions)
        else {
            shelf?.isDropTargeted = false
            return []
        }
        shelf?.isDropTargeted = true
        return .copy
    }
}

/// The notch's panel.
///
/// A borderless window refuses to become key, which would leave the focus label impossible to
/// type into. `becomesKeyOnlyIfNeeded` is what keeps that from costing anything elsewhere: the
/// panel takes the keyboard only when a view that actually wants input is clicked, so pressing
/// Start or scrubbing the progress bar never pulls the caret out of whatever you were writing in.
final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NSPanel?
    private var state: NotchState?
    private var pointerMonitors: [Any] = []
    private var dragPoll: Timer?
    private var dragPasteboardCount = 0
    /// Whether the mouse-down being watched turned into a real drag. Every click starts a watch,
    /// and only a drag's ending is worth reporting to the hover rule.
    private var sawDrag = false
    /// Decides whether an open was meant, and how long it survives the pointer leaving.
    private var hover = NotchHover()
    /// Runs only while the panel is open: rest and the closing grace both have to pass without
    /// the pointer sending another event.
    private var hoverTick: Timer?
    private let media = MediaController()
    private let lyrics = LyricsProvider()
    private let spotifyAuth = SpotifyAuth()
    private lazy var spotifyLibrary = SpotifyLibrary(auth: spotifyAuth)
    private let shelf = ShelfModel()
    private let dashboard = DashboardAccount()
    private lazy var focus = FocusModel(account: dashboard)
    private let settingsWindow = SettingsWindow()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let screen = notchedScreen()
        let geometry = computeGeometry(for: screen)

        let state = NotchState(
            closedSize: geometry.closed,
            compactOpenSize: geometry.compactOpen,
            lyricsHeight: geometry.lyricsHeight,
            windowSize: geometry.window
        )
        self.state = state

        let rootView = NotchRootView(
            state: state,
            media: media,
            lyrics: lyrics,
            library: spotifyLibrary,
            shelf: shelf,
            focus: focus,
            openSettings: { [weak self] in self?.showSettings() }
        )
        let hostingView = PassthroughHostingView(rootView: rootView)
        hostingView.state = state
        hostingView.shelf = shelf

        let panel = NotchPanel(
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
        // Must sit above the menu bar (.mainMenu) but below the drag layer
        // (kCGDraggingWindowLevel, 500) — any higher and file drags render behind the
        // panel and their drops fall through to the desktop.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // The window is far larger than the visible chrome and sits above the menu bar, so it
        // must stay transparent to clicks until the pointer is actually over the notch.
        panel.ignoresMouseEvents = true

        layoutPanel(panel, on: screen, geometry: geometry)
        panel.orderFrontRegardless()

        self.panel = panel
        observeScreenChanges()
        startPointerTracking()
        media.start()
        // A countdown that rings while the notch is closed should be one hover away, not one
        // hover plus a tab switch — so aim the panel at it as soon as it goes off.
        focus.onRingOut = { [weak self] _ in
            self?.state?.selectedTab = .focus
        }
        focus.start()
        LaunchAtLogin.syncOnLaunch()
    }

    func applicationWillTerminate(_ notification: Notification) {
        pointerMonitors.forEach(NSEvent.removeMonitor)
        pointerMonitors.removeAll()
        dragPoll?.invalidate()
        dragPoll = nil
        stopHoverTick()
        focus.stop()
    }

    private func showSettings() {
        settingsWindow.show(account: dashboard, focus: focus, spotify: spotifyAuth)
    }

    // MARK: Pointer tracking

    /// `ignoresMouseEvents` is the only thing that genuinely lets clicks reach the windows below —
    /// a `hitTest` returning nil still consumes the click. But a window that ignores mouse events
    /// never sees hover either, so the notch can't open itself: the pointer has to be tracked
    /// globally and the panel switched on only while the cursor is over the chrome.
    private func startPointerTracking() {
        let mask: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .leftMouseDown,
            // Scrolling the lyrics or the shelf is as deliberate as a click, and is the one way
            // to use the panel that never moves the pointer.
            .scrollWheel,
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
        // Acting on the panel is reported, not interpreted: whether one skipped track is reason
        // to hold the panel open is the hover rule's business.
        if event.type == .leftMouseDown || event.type == .scrollWheel, isPointerOnChrome {
            hover.acted(.touch, pointer: NSEvent.mouseLocation, now: Date())
        }
        if event.type == .leftMouseDown {
            beginDragWatch()
        } else {
            syncPointer()
        }
    }

    private var isPointerOnChrome: Bool {
        guard let panel, let state else { return false }
        return state.chromeRect(in: panel.frame, flipped: false).contains(NSEvent.mouseLocation)
    }

    private func syncPointer() {
        guard let panel, let state else { return }
        // Never flip interactivity mid-click — that would abort a scrub or a shelf drag.
        guard NSEvent.pressedMouseButtons == 0 else { return }

        let mouse = NSEvent.mouseLocation
        let chrome = state.chromeRect(in: panel.frame, flipped: false)
        // Clicks belong to the chrome itself and never to the sticky margin around it, so the
        // panel goes back to being click-through the moment the pointer is off it — even while
        // it is still holding open.
        panel.ignoresMouseEvents = !chrome.contains(mouse)

        switch hover.evaluate(pointer: mouse, chrome: chrome, now: Date()) {
        case .none:
            break
        case .open:
            setOpen(true)
        case .close:
            setOpen(false)
        }
    }

    private func setOpen(_ open: Bool) {
        guard let state, state.isOpen != open else { return }
        withAnimation(NotchState.toggle) { state.isOpen = open }
        if open {
            startHoverTick()
        } else {
            stopHoverTick()
            relinquishKeyboard()
        }
    }

    /// Hand the keyboard back on the way down. A panel left key with the focus label still first
    /// responder would go on swallowing keystrokes meant for whatever is in front, and the notch
    /// collapses on the pointer leaving — usually without a click anywhere else to take key off
    /// it. Ordering out and straight back in is what drops key status; the panel is transparent
    /// either side of it, so nothing is seen to happen.
    private func relinquishKeyboard() {
        guard let panel, panel.isKeyWindow else { return }
        panel.makeFirstResponder(nil)
        panel.orderOut(nil)
        panel.orderFrontRegardless()
    }

    /// A pointer resting on the panel sends no further events, and a closing grace has to expire
    /// on its own, so the hover rule is nudged on a tick for as long as the panel is open.
    private func startHoverTick() {
        guard hoverTick == nil else { return }
        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncPointer() }
        }
        // .common, so a tracking loop inside the panel can't stall the countdown.
        RunLoop.main.add(timer, forMode: .common)
        hoverTick = timer
    }

    private func stopHoverTick() {
        hoverTick?.invalidate()
        hoverTick = nil
    }

    // MARK: Drag-to-open

    /// How far outside the collapsed notch a file drag still counts as aimed at the shelf.
    private static let dragCatchInset: CGFloat = 24

    /// A drag session consumes the mouse events `syncPointer` relies on, so hovering the notch
    /// with files can't be seen the usual way. Snapshot the drag pasteboard when the button goes
    /// down; if it changes while the button is held, a drag is in flight and worth polling for.
    private func beginDragWatch() {
        dragPoll?.invalidate()
        sawDrag = false
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
            // A drag that has been let go of is an errand finished — files onto the shelf, or
            // something taken off it — so the panel goes back to needing a reason to stay. Plain
            // clicks are already reported by `handle`; this fires only for a real drag.
            if sawDrag {
                hover.acted(.dragEnded, pointer: NSEvent.mouseLocation, now: Date())
            }
            syncPointer()
            return
        }
        guard isDraggingFiles else { return }
        sawDrag = true

        // Stay drop-eligible for the whole drag: a window that ignores mouse events can't be a
        // drag destination at all, and one that accepts nothing under the cursor simply lets the
        // drag continue to the window below.
        panel.ignoresMouseEvents = false

        let target = state.chromeRect(in: panel.frame, flipped: false)
            .insetBy(dx: -Self.dragCatchInset, dy: -Self.dragCatchInset)
        guard target.contains(NSEvent.mouseLocation), !state.isOpen else { return }
        // The shelf is the only tab with a drop target, so aim the drag at something useful.
        // Aiming a file at the notch is as deliberate as it gets.
        hover.openDeliberately()
        withAnimation(NotchState.toggle) {
            state.selectedTab = .shelf
            state.isOpen = true
        }
        startHoverTick()
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
        let compactOpen: CGSize
        let lyricsHeight: CGFloat
        let window: CGSize
    }

    private func observeScreenChanges() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.relayoutForCurrentScreens() }
        }
    }

    private func relayoutForCurrentScreens() {
        guard let panel, let state else { return }
        let screen = notchedScreen()
        let geometry = computeGeometry(for: screen)
        state.updateSizes(
            closed: geometry.closed,
            compactOpen: geometry.compactOpen,
            lyricsHeight: geometry.lyricsHeight,
            window: geometry.window
        )
        layoutPanel(panel, on: screen, geometry: geometry)
    }

    /// The built-in display that has the camera notch, when present.
    private func notchedScreen() -> NSScreen {
        if let builtIn = NSScreen.screens.first(where: { screen in
            screen.safeAreaInsets.top > 0 && isBuiltIn(screen)
        }) {
            return builtIn
        }
        return NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    private func isBuiltIn(_ screen: NSScreen) -> Bool {
        guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else { return false }
        return CGDisplayIsBuiltin(id) != 0
    }

    /// Hardware notch cutout in global screen coordinates (from the system's auxiliary areas).
    private func hardwareNotchRect(on screen: NSScreen) -> CGRect? {
        guard screen.safeAreaInsets.top > 0,
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea
        else { return nil }

        let width = right.minX - left.maxX
        guard width > 0 else { return nil }

        let height = screen.safeAreaInsets.top
        return CGRect(x: left.maxX, y: screen.frame.maxY - height, width: width, height: height)
    }

    private func layoutPanel(_ panel: NSPanel, on screen: NSScreen, geometry: Geometry) {
        let notch = hardwareNotchRect(on: screen)
        let anchorX = notch?.midX ?? screen.frame.midX
        let origin = NSPoint(
            x: anchorX - geometry.window.width / 2,
            y: screen.frame.maxY - geometry.window.height
        )
        panel.setFrame(
            NSRect(origin: origin, size: geometry.window),
            display: true
        )
        panel.contentView?.autoresizingMask = [.width, .height]
    }

    private func computeGeometry(for screen: NSScreen) -> Geometry {
        let notch = hardwareNotchRect(on: screen)
        let notchHeight = notch?.height ?? 32
        let notchWidth = max(120, notch?.width ?? 200)

        let closed = CGSize(width: notchWidth, height: notchHeight)
        let compactOpen = CGSize(width: 440, height: 168 + notchHeight)
        let lyricsHeight: CGFloat = 164
        // The window never resizes — it is sized for the panel at its tallest (lyrics out) so
        // that growing the panel is only a layout change inside a window that already fits it.
        let window = CGSize(
            width: max(compactOpen.width, notchWidth) + 80,
            height: compactOpen.height + lyricsHeight + 40
        )
        return Geometry(
            closed: closed,
            compactOpen: compactOpen,
            lyricsHeight: lyricsHeight,
            window: window
        )
    }
}
