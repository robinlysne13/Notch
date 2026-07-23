import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Accessory app: no Dock icon, no menu bar takeover.
app.setActivationPolicy(.accessory)
app.run()
