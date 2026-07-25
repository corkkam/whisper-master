import AppKit
import ClerkKit
import SwiftUI

/// The blocking sign-in window. Modeled on `OnboardingWindow`, but with **no
/// close button** — the app is gated, so the only way past it is to sign in
/// (Cmd-Q from the app menu still quits). The `AppDelegate` shows it at launch
/// and whenever the session goes signed-out, and closes it once a user is
/// authenticated.
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
        window.styleMask = [.titled, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // No close/minimize/zoom: the gate can't be dismissed, only completed.
        window.standardWindowButton(.closeButton)?.isHidden = true
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
        // Inherits the app-wide appearance (`AppDelegate.applyAppearance`).
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
