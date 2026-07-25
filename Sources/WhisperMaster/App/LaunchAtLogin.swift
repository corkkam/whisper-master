import Foundation
import Observation
import ServiceManagement

/// Launch-at-login preference, backed by macOS `SMAppService.mainApp`.
///
/// The OS is the source of truth (System Settings → General → Login Items). We
/// expose a toggle that registers / unregisters the main app as a login item, and
/// re-read the OS status so a change made outside the app is reflected here.
@MainActor
@Observable
final class LaunchAtLogin {
    static let shared = LaunchAtLogin()

    /// Whether the app is currently registered to open at login.
    private(set) var isEnabled: Bool = false

    /// Human-readable reason the last toggle failed, if any. Cleared on success.
    private(set) var lastError: String?

    private init() {
        refresh()
    }

    /// Re-read the OS registration status. Safe to call often (e.g. when Settings opens).
    func refresh() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    /// Enable or disable launch at login. Updates `isEnabled` to the resulting OS state.
    func setEnabled(_ enabled: Bool) {
        lastError = nil
        do {
            if enabled {
                // Already registered — treat as success rather than throwing.
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                // Only unregister when actually registered; no-op otherwise.
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
            refresh()
        } catch {
            // Surface a short, user-facing reason; full error goes to the log.
            Log.app.error("Launch at login failed: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
            refresh()
        }
    }
}
