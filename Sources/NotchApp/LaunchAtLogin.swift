import Foundation
import ServiceManagement

/// Launch-at-login backed by `SMAppService`, so the app shows up under
/// System Settings › General › Login Items where it can also be turned off.
///
/// Registration only works from a real `.app` bundle; running the bare binary out of
/// `.build/` is a no-op rather than an error.
@MainActor
enum LaunchAtLogin {
    /// Set once the user turns the toggle off, so we stop re-enabling it on every launch.
    private static let optedOutKey = "LaunchAtLoginOptedOut"

    private static var isBundled: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    static var isEnabled: Bool {
        isBundled && SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) {
        guard isBundled else { return }
        UserDefaults.standard.set(!enabled, forKey: optedOutKey)
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Notch: launch at login \(enabled ? "register" : "unregister") failed: \(error.localizedDescription)")
        }
    }

    /// Enable on first launch, and re-register when a rebuild has invalidated the stored
    /// login item — unless the user has explicitly opted out.
    static func syncOnLaunch() {
        guard isBundled, !UserDefaults.standard.bool(forKey: optedOutKey) else { return }

        switch SMAppService.mainApp.status {
        case .enabled:
            break
        case .requiresApproval:
            NSLog("Notch: launch at login needs approval in System Settings › General › Login Items.")
        default:
            setEnabled(true)
        }
    }
}
