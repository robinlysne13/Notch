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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NSPanel?
    private var state: NotchState?
    private var pointerMonitors: [Any] = []
    private var dragPoll: Timer?
    private var dragPasteboardCount = 0
    private let media = MediaController()
    private let lyrics = LyricsProvider()
    private let shelf = ShelfModel()
    private let accounts = MailAccountStore()
    private lazy var codes = CodeWatcher(store: accounts)
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
            shelf: shelf,
            codes: codes,
            accounts: accounts,
            openSettings: { [weak self] in self?.showSettings() }
        )
        let hostingView = PassthroughHostingView(rootView: rootView)
        hostingView.state = state
        hostingView.shelf = shelf

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
        // A code that lands while the notch is closed should be one hover away, not one hover plus
        // a tab switch — so aim the panel at it as soon as it arrives.
        codes.onNewCode = { [weak self] _ in
            self?.state?.selectedTab = .codes
        }
        codes.start()
        LaunchAtLogin.syncOnLaunch()
    }

    func applicationWillTerminate(_ notification: Notification) {
        pointerMonitors.forEach(NSEvent.removeMonitor)
        pointerMonitors.removeAll()
        dragPoll?.invalidate()
        dragPoll = nil
        codes.stop()
    }

    private func showSettings() {
        settingsWindow.show(accounts: accounts, watcher: codes)
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
