import AppKit

let app = NSApplication.shared
// Top-level code isn't main-actor isolated, but this all runs on the main thread before `run()`.
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
// Accessory app: no Dock icon, no menu bar takeover.
app.setActivationPolicy(.accessory)
app.run()
