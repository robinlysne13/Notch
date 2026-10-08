import AppKit
import SwiftUI

/// Owns the single settings window. Kept separate from the notch panel because that panel is
/// borderless, non-activating and collapses on pointer exit — none of which suits a text form.
@MainActor
final class SettingsWindow {
    private var window: NSWindow?

    func show(accounts: MailAccountStore, watcher: CodeWatcher) {
        if let window {
            present(window)
            return
        }
        let view = MailSettingsView(accounts: accounts, watcher: watcher)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 440),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Notch"
        window.contentView = NSHostingView(rootView: view)
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        present(window)
    }

    private func present(_ window: NSWindow) {
        // An accessory app isn't active by default, so the form couldn't take keystrokes without
        // explicitly activating first.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
