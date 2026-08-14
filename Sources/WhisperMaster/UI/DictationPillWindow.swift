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
    private var followTimer: Timer?
    /// Last screen the panel was placed on, so a 0.25s tick that finds the
    /// pointer still there is a no-op (a frame write every tick is a permanent
    /// background cost).
    private var appliedScreenNumber: NSNumber?

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
        startFollowing()
        reposition()
    }

    func show() {
        panel.orderFrontRegardless()
        startFollowing()
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

    /// The display the pointer is on, so a multi-monitor setup shows the band
    /// on the screen being used. A notchless external still gets the band at
    /// top-center (`NotchGeometry.measure` already handles a missing notch).
    private var targetScreen: NSScreen? {
        PointerScreen.current()
    }

    private func startFollowing() {
        guard followTimer == nil else { return }
        let timer = Timer(timeInterval: PointerScreen.followInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.followPointerScreen() }
        }
        RunLoop.main.add(timer, forMode: .common)
        followTimer = timer
    }

    private func followPointerScreen() {
        guard let screen = targetScreen else { return }
        guard PointerScreen.number(of: screen) != appliedScreenNumber else { return }
        reposition()
    }

    private func reposition() {
        guard let screen = targetScreen else { return }
        appliedScreenNumber = PointerScreen.number(of: screen)

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
        followTimer?.invalidate()
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }
}
