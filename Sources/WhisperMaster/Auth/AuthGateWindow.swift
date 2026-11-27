import AppKit
import ClerkKit
import SwiftUI

/// The sign-in window. Modeled on `OnboardingWindow`. It opens when the person
/// asks to sign in (the tray, Settings, the notch prompt), and they can close it
/// and keep dictating: since owner decision D2 (2026-11-27) the app is not gated
/// behind it. The `AppDelegate` closes it once a user is authenticated.
@MainActor
final class AuthGateWindow {
    private let window: NSWindow

    /// - Parameter onRetry: invoked by the gate's Retry button (offline / not-yet-
    ///   loaded states) to re-run Clerk configuration + reconcile from the
    ///   AppDelegate, since the SwiftUI view can't reach those itself.
    init(onRetry: @escaping () -> Void = {}) {
        // Inject the shared Clerk instance so AuthView and the observable state
        // are available to the SwiftUI hierarchy.
        let root = AuthGateView(onRetry: onRetry)
            .environment(Clerk.shared)
        let host = NSHostingController(rootView: root)
        window = NSWindow(contentViewController: host)
        window.title = "Sign in to Whisper Master"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // Close stays (the person may decide against it); minimize and zoom do not
        // mean anything for a one-purpose sign-in card.
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.setContentSize(NSSize(width: 520, height: 680))
        window.center()
        window.isReleasedWhenClosed = false
        // Normal level (not .floating): a floating window would sit above any
        // OAuth/system sheet Clerk presents. We rely on activate()/orderFront.
        window.level = .normal
        window.hidesOnDeactivate = false
        window.isMovableByWindowBackground = true
        // Inherits the app-wide light appearance pinned in
        // `AppDelegate.applicationDidFinishLaunching`.
        window.backgroundColor = Theme.canvasNSColor
    }

    var isVisible: Bool { window.isVisible }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func close() {
        window.orderOut(nil)
    }
}
