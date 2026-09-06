import AppKit
import SwiftUI

/// The window the release note lives in.
///
/// A **window**, not a notch band: the band deliberately holds one ask at a time
/// and is a slim menu-bar row — there is nowhere on it to put a demo video. This
/// is closer to `AuthGateWindow`, minus the gating: it keeps its close button, it
/// doesn't yank focus, and dismissing it is the whole of its contract.
@MainActor
final class WhatsNewWindow {
    private let window: NSWindow
    /// `NSWindow.delegate` is weak, so the observer has to be held here.
    private let closeObserver: CloseObserver

    /// - Parameter onClose: fired once, whichever way the window goes away, so
    ///   the controller can drop its reference.
    init(release: WhatsNewRelease, onClose: @escaping () -> Void) {
        closeObserver = CloseObserver(onClose: onClose)

        let host = NSHostingController(rootView: WhatsNewView(release: release))
        let created = NSWindow(contentViewController: host)
        created.title = "What's New"
        created.styleMask = [.titled, .closable, .fullSizeContentView]
        created.titlebarAppearsTransparent = true
        created.titleVisibility = .hidden
        created.standardWindowButton(.miniaturizeButton)?.isHidden = true
        created.standardWindowButton(.zoomButton)?.isHidden = true
        created.setContentSize(NSSize(width: 720, height: 700))
        created.center()
        created.isReleasedWhenClosed = false
        created.isMovableByWindowBackground = true
        // Inherits the app-wide appearance (`AppDelegate.applyAppearance`).
        created.backgroundColor = Theme.canvasNSColor
        created.delegate = closeObserver
        window = created

        // The view's own dismiss button needs the window, which doesn't exist
        // until its host does — so the root view is set once more with it.
        host.rootView = WhatsNewView(release: release, onDismiss: { [weak created] in
            created?.performClose(nil)
        })
    }

    var isVisible: Bool { window.isVisible }

    /// Shown without `NSApp.activate`: this surface appears on its own after an
    /// update, and pulling keyboard focus out of whatever the user is typing into
    /// would make it an interruption instead of a delighter.
    func show() {
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func close() {
        window.performClose(nil)
    }

    private final class CloseObserver: NSObject, NSWindowDelegate {
        private let onClose: () -> Void

        init(onClose: @escaping () -> Void) {
            self.onClose = onClose
        }

        func windowWillClose(_ notification: Notification) {
            onClose()
        }
    }
}
