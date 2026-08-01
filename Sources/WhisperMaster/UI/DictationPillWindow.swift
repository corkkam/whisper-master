import AppKit
import SwiftUI

/// Owns the borderless, click-through panel that hosts the notch dictation
/// surface, keeping it anchored to the notch as displays change.
@MainActor
final class DictationPillWindow {
    private let panel: NSPanel
    private let host: NSHostingView<DictationPillContent>
    private let state: AppState
    private let layout = NotchSurfaceLayout()
    /// Opens Settings → Notes & Reminders when the command-confirmation banner is
    /// tapped. Injected by `AppDelegate`, which owns the settings window.
    private let onOpenNotes: () -> Void
    /// Copies the undelivered transcript when its banner's Copy button is tapped.
    /// Injected by `AppDelegate`, which owns the view model that does the copying.
    private let onCopyUndelivered: () -> Void
    /// Ticks the due-reminder banner's checkbox on or off. Injected by
    /// `AppDelegate`, which holds the pre-tick snapshot an un-tick restores.
    private let onToggleDueReminder: () -> Void

    private var screenObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    init(
        state: AppState,
        onOpenNotes: @escaping () -> Void = {},
        onCopyUndelivered: @escaping () -> Void = {},
        onToggleDueReminder: @escaping () -> Void = {}
    ) {
        self.state = state
        self.onOpenNotes = onOpenNotes
        self.onCopyUndelivered = onCopyUndelivered
        self.onToggleDueReminder = onToggleDueReminder

        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The pill draws on the physical black bezel, so it stays ink whatever
        // the app-wide light/dark setting is — a light band on a notch reads as
        // broken. Pinning the panel also keeps `Theme.Notch` resolving on-dark.
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.hasShadow = false
        panel.isMovable = false
        panel.ignoresMouseEvents = true

        host = NSHostingView(rootView: DictationPillContent(
            state: state,
            onOpenNotes: onOpenNotes,
            onCopyUndelivered: onCopyUndelivered,
            onToggleDueReminder: onToggleDueReminder))
        host.autoresizingMask = [.width, .height]
        panel.contentView = host

        observeEnvironment()
        reposition()
    }

    func show() {
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    /// Let the panel receive clicks only while it shows an interactive element
    /// (the Bluetooth-mic banner, the tappable command confirmation, a due
    /// reminder's checkbox, the undelivered hint's Copy button). Otherwise it
    /// stays click-through so the
    /// passive dictation indicator never intercepts the menu bar.
    func setInteractive(_ interactive: Bool) {
        // Driven from the 0.5s refresh loop, so only write on a real change — a
        // window property assignment is a round-trip to the window server, and the
        // answer is the same on nearly every tick.
        guard panel.ignoresMouseEvents == interactive else { return }
        panel.ignoresMouseEvents = !interactive
    }

    /// Prefer the display that actually has a notch; fall back to the main one.
    private var targetScreen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }

    private func reposition() {
        guard let screen = targetScreen else { return }

        let geometry = NotchGeometry.measure(screen)
        let size = layout.panelSize(for: geometry)
        let origin = layout.panelOrigin(for: geometry, on: screen)

        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        host.rootView = DictationPillContent(
            state: state,
            geometry: geometry,
            layout: layout,
            onOpenNotes: onOpenNotes,
            onCopyUndelivered: onCopyUndelivered,
            onToggleDueReminder: onToggleDueReminder)
    }

    private func observeEnvironment() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reposition()
            }
        }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reposition()
            }
        }
    }

    deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }
}
