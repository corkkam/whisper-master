import AppKit
import SwiftUI

/// Owns the borderless panel that hosts the notch onboarding band, keeping it
/// anchored to the notch as displays change.
///
/// Mirrors `DictationPillWindow` — same level, same collection behavior, same
/// pinned-dark appearance — with two deliberate differences: it **takes clicks**
/// (the whole band is buttons) and it is sized exactly to its one fixed surface.
///
/// The panel is a `.nonactivatingPanel`, so tapping a button doesn't yank focus
/// out of whatever the user was doing; the model activates the app explicitly
/// around the microphone prompt, which needs the app frontmost.
@MainActor
final class NotchOnboardingWindow {
    private let panel: NSPanel
    private let host: NSHostingView<NotchOnboardingView>
    private let model: NotchOnboardingModel
    private let state: AppState
    private let layout = NotchOnboardingLayout()
    private let onOpenSettings: () -> Void

    private var screenObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var activeObserver: NSObjectProtocol?
    /// Neither grant posts a change notification, so the flow polls. The timer
    /// lives here rather than in the view because a `Timer.publish` inside a
    /// SwiftUI body is re-subscribed on every body pass — and the mic check
    /// re-evaluates that body ~20×/s, which would starve the tick.
    private var pollTimer: Timer?
    private var followTimer: Timer?
    private var appliedScreenNumber: NSNumber?

    init(
        state: AppState,
        permissions: PermissionsManager,
        onOpenSettings: @escaping () -> Void,
        onClose: @escaping () -> Void,
        onComplete: @escaping () -> Void
    ) {
        self.state = state
        self.onOpenSettings = onOpenSettings
        model = NotchOnboardingModel(
            permissions: permissions,
            onComplete: onComplete,
            onDismiss: onClose
        )

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
        // Drawn on the physical black bezel, so it stays ink whatever the
        // app-wide light/dark setting is — and `Theme.Notch` keeps resolving
        // on-dark.
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.hasShadow = false
        panel.isMovable = false

        host = NSHostingView(rootView: NotchOnboardingView(
            model: model, state: state, onOpenSettings: onOpenSettings))
        host.autoresizingMask = [.width, .height]
        panel.contentView = host

        observeEnvironment()
        reposition()
    }

    func show() {
        // The microphone prompt is attributed to the frontmost app, so come
        // forward before the first ask rather than prompting from behind.
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        model.refresh()
        startPolling()
        startFollowing()
    }

    /// Hide the band, stop polling and release the mic check. Safe to call twice.
    func close() {
        pollTimer?.invalidate()
        pollTimer = nil
        followTimer?.invalidate()
        followTimer = nil
        model.teardown()
        panel.orderOut(nil)
    }

    private func startPolling() {
        guard pollTimer == nil else { return }
        let timer = Timer(timeInterval: 0.75, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.model.refresh()
            }
        }
        // .common so the tick survives a tracking loop (a menu or a drag).
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    /// The display the pointer is on — same rule as the dictation pill.
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
        // The same model instance, so the flow keeps its place across a display
        // change — only the geometry it lays itself out against changes.
        host.rootView = NotchOnboardingView(
            model: model,
            state: state,
            geometry: geometry,
            layout: layout,
            onOpenSettings: onOpenSettings
        )
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

        // Coming back from System Settings is the moment a grant most often
        // changed, so don't wait for the next poll tick to notice.
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.model.refresh()
            }
        }
    }

    deinit {
        pollTimer?.invalidate()
        followTimer?.invalidate()
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        if let activeObserver {
            NotificationCenter.default.removeObserver(activeObserver)
        }
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }
}
