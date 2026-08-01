import AppKit
import Foundation
import Observation
import ServiceManagement

/// Launch-at-login preference, backed by macOS `SMAppService.mainApp`.
///
/// The OS is the source of truth (System Settings → General → Login Items). We
/// expose a toggle that registers / unregisters the main app as a login item, and
/// re-read the OS status so a change made outside the app is reflected here.
///
/// **`.requiresApproval` is a distinct, load-bearing state, not a failure.**
/// `register()` succeeds while macOS still holds the item disabled until the user
/// approves it in Login Items — the app is registered, `status != .enabled`, and it
/// does **not** launch at login. Collapsing that into "off" is what made the
/// toggle look on-and-broken (register, no error, still dead after a restart), so
/// it's surfaced as `needsApproval` with a one-tap trip to the right pane.
@MainActor
@Observable
final class LaunchAtLogin {
    static let shared = LaunchAtLogin()

    /// Whether the app is currently registered *and* approved to open at login.
    private(set) var isEnabled: Bool = false

    /// Registered, but macOS is holding it until the user approves it in
    /// System Settings → General → Login Items. It will **not** launch until then.
    private(set) var needsApproval: Bool = false

    /// Human-readable reason the last toggle failed, if any. Cleared on success.
    private(set) var lastError: String?

    /// The user's own last answer, so a registration the OS lost can be restored
    /// without ever adding a login item they never asked for.
    private static let intentKey = "WhisperMaster.launchAtLogin.intent.v1"

    private var userWantsIt: Bool {
        get { UserDefaults.standard.bool(forKey: Self.intentKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.intentKey) }
    }

    private init() {
        refresh()
    }

    /// Launch-time reconcile: **re-register if the OS lost a registration the user
    /// asked for.** A Login Items record is tied to the app bundle's signature and
    /// location, so replacing the bundle — a Sparkle update, a re-signed local
    /// install, a drag to a new folder — can drop it back to `.notRegistered` with
    /// no error and no UI anywhere: the app simply stops opening at login. This
    /// heals that silently, and only ever in the direction the user already chose
    /// (`userWantsIt`), so it can't add a login item on its own.
    func reconcileOnLaunch() {
        refresh()
        if isRegistered {
            userWantsIt = true
            return
        }
        guard userWantsIt else { return }
        do {
            try SMAppService.mainApp.register()
            Log.app.notice("Re-registered login item after the OS lost it")
        } catch {
            Log.app.error("Login item re-register failed: \(error.localizedDescription, privacy: .public)")
        }
        refresh()
    }

    /// Re-read the OS registration status. Safe to call often (e.g. when Settings opens).
    func refresh() {
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled
        needsApproval = status == .requiresApproval
    }

    /// Whether the user has already made a choice we should not override — i.e.
    /// the app is registered in some form. Used by onboarding to decide whether
    /// the login-item beat still has anything to ask.
    var isRegistered: Bool { isEnabled || needsApproval }

    /// Enable or disable launch at login. Updates `isEnabled` / `needsApproval` to
    /// the resulting OS state.
    func setEnabled(_ enabled: Bool) {
        lastError = nil
        // Record the intent first, so a later bundle replacement can restore it
        // even if this attempt is the one macOS holds for approval.
        userWantsIt = enabled
        do {
            if enabled {
                // Already registered (enabled *or* awaiting approval) — registering
                // again throws `kSMErrorAlreadyRegistered`, so treat it as success
                // and let `refresh()` report which of the two states we're in.
                if !isRegistered {
                    try SMAppService.mainApp.register()
                }
            } else {
                // Only unregister when actually registered; no-op otherwise.
                if isRegistered {
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

    /// Open System Settings → General → Login Items, the only place a
    /// `.requiresApproval` registration can be turned on.
    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
        // The pane opens behind us on a non-activating panel (the notch band), so
        // hand focus over explicitly rather than leaving it hidden.
        NSApp.deactivate()
    }
}
