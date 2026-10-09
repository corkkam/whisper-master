import AppKit
import SwiftUI

/// Hosts `AuthGateView` at launch when nobody's signed in. Mirrors
/// `OnboardingWindow`'s chrome (cream ground, hidden traffic lights, normal
/// level so system dialogs aren't hidden).
@MainActor
final class AuthGateWindow {
    private let window: NSWindow

    init(account: AccountStore, onContinue: @escaping () -> Void) {
        let root = AuthGateView(account: account, onContinue: onContinue)
        let host = NSHostingController(rootView: root)
        window = NSWindow(contentViewController: host)
        window.title = "Whisper Master"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.setContentSize(NSSize(width: 560, height: 560))
        window.center()
        window.isReleasedWhenClosed = false
        window.level = .normal
        window.hidesOnDeactivate = false
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = Theme.canvasNSColor
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func close() {
        window.orderOut(nil)
    }
}
