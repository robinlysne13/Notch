import AppKit
import SwiftUI

/// Owns the single settings window. Kept separate from the notch panel because that panel is
/// borderless, non-activating and collapses on pointer exit — none of which suits a text form.
@MainActor
final class SettingsWindow {
    private var window: NSWindow?

    func show(account: DashboardAccount, focus: FocusModel, spotify: SpotifyAuth) {
        if let window {
            present(window)
            return
        }
        // Two unrelated setups — a dashboard sign-in and a Spotify one — so they get a tab each
        // rather than one long form.
        let view = TabView {
            DashboardSettingsView(account: account, focus: focus)
                .tabItem { Label("Dashboard", systemImage: "timer") }
            SpotifySettingsView(auth: spotify)
                .tabItem { Label("Spotify", systemImage: "music.note") }
        }
        .padding(.top, 6)
        .frame(width: 452, height: 470)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 452, height: 470),
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
