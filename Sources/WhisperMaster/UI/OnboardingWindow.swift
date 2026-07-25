import AppKit
import SwiftUI

@MainActor
final class OnboardingWindow {
    private let window: NSWindow

    init(
        state: AppState,
        permissions: PermissionsManager,
        microphoneCapture: MicrophoneCaptureService? = nil,
        steps: [OnboardingStep] = OnboardingStep.allCases,
        retryEngine: (() -> Void)? = nil,
        onClose: @escaping () -> Void,
        onComplete: @escaping () -> Void
    ) {
        let root = OnboardingView(
            state: state,
            permissions: permissions,
            microphoneCapture: microphoneCapture,
            steps: steps,
            retryEngine: retryEngine,
            onClose: onClose,
            onComplete: onComplete
        )
        let host = NSHostingController(rootView: root)
        window = NSWindow(contentViewController: host)
        window.title = "Welcome to Whisper Master"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.setContentSize(NSSize(width: 640, height: 520))
        window.center()
        window.isReleasedWhenClosed = false
        // Normal level (not .floating): a floating window sits above System
        // Settings and the macOS permission modal, hiding them when the user
        // goes to grant Accessibility. We rely on activate()/orderFront instead.
        window.level = .normal
        window.hidesOnDeactivate = false
        window.isMovableByWindowBackground = true
        // Inherits the app-wide appearance (`AppDelegate.applyAppearance`).
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
