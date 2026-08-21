import AppKit
import SwiftUI

/// Owns the panel that drops out of the notch when you rest the pointer on it.
///
/// Mirrors `DictationPillWindow` — same level, same collection behavior, same
/// pinned-dark appearance — with two deliberate differences: it **takes clicks** (the
/// band is buttons), and it is **only on screen while open**. That second one is the
/// important one: nothing of ours sits over the notch while the panel is shut, so a
/// click up there still reaches the menu bar exactly as it did before this existed.
///
/// **Hover is polled, not tracked.** With no panel on screen there is no view to
/// receive `mouseEntered`, and a tracking area installed on a panel that resizes
/// under the cursor doesn't reliably fire again until the mouse moves. So the window
/// samples `NSEvent.mouseLocation` against the notch strip (closed) or the panel's own
/// frame (open) on a slow timer and lets `NotchQuickActionsModel` do the dwell/grace
/// arithmetic. Polling a point costs nothing and needs no accessibility grant — unlike
/// a global mouse-moved monitor.
@MainActor
final class NotchQuickActionsWindow {
    /// How often the pointer is sampled.
    ///
    /// The tick is pure latency on top of the dwell — the pointer arrives between two
    /// samples, so the panel opens up to two intervals after the dwell has really
    /// elapsed. At 0.15 s that was a third of a second of slop on a 0.28 s dwell,
    /// which read as the notch ignoring you. Comparing a point against two rects
    /// costs nothing, so sample often enough that the dwell is what you feel.
    private static let tickInterval: TimeInterval = 0.06

    private let panel: NSPanel
    private let host: NSHostingView<NotchQuickActionsView>
    private let model: NotchQuickActionsModel
    private let layout = NotchQuickActionsLayout()
    private let onOpenNotes: (NotesComposerRequest?) -> Void
    private let onOpenSettings: () -> Void

    private var pollTimer: Timer?
    private var screenObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    /// Mirrors the model's `isOpen` on the AppKit side, so the panel is ordered in
    /// and out exactly on the transitions (there's no `@Observable` bridge to
    /// AppKit — the poll tick is the bridge, same as the AppDelegate's refresh loop).
    private var isPanelVisible = false
    /// Row count the visible panel was sized for, so ticking a reminder off while the
    /// band is open shrinks it instead of leaving the emptied row as dead black.
    private var sizedForRows = -1
    /// True while another notch surface owns the strip (onboarding). Keeps the poll
    /// off entirely rather than relying on suppression inside the model.
    private var isSuspended = false
    /// Last screen the hover zone / panel was placed on, so a pointer that
    /// stays put does not rewrite the frame every 0.06 s.
    private var appliedScreenNumber: NSNumber?

    init(
        state: AppState,
        onOpenNotes: @escaping (NotesComposerRequest?) -> Void,
        onOpenSettings: @escaping () -> Void
    ) {
        self.onOpenNotes = onOpenNotes
        self.onOpenSettings = onOpenSettings
        model = NotchQuickActionsModel(state: state)

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
        // Drawn on the physical black bezel, so it stays ink whatever the app-wide
        // light/dark setting is — and `Theme.Notch` keeps resolving on-dark.
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.hasShadow = false
        panel.isMovable = false

        host = NSHostingView(rootView: NotchQuickActionsView(model: model))
        host.autoresizingMask = [.width, .height]
        panel.contentView = host

        observeEnvironment()
        reposition()
    }

    /// Begin watching the notch. Idempotent.
    func start() {
        guard pollTimer == nil else { return }
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // .common so the tick survives a tracking loop (a menu or a drag).
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    /// Stop watching and close. Used while another notch surface owns the strip, and
    /// on sign-out.
    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        model.close()
        applyOpenState()
    }

    /// Hand the notch over to another surface (onboarding) without forgetting we
    /// were running, so `resume()` can take it back.
    func suspend() {
        isSuspended = true
        model.close()
        applyOpenState()
    }

    func resume() {
        isSuspended = false
    }

    /// Close the panel now — used right after an action that opens the Settings
    /// window, so the band doesn't hang around over the app it just handed off to.
    func dismiss() {
        model.close()
        applyOpenState()
    }

    // MARK: - Poll

    private func tick() {
        guard !isSuspended else { return }
        guard let screen = targetScreen else { return }
        let number = PointerScreen.number(of: screen)
        if number != appliedScreenNumber {
            reposition()
        }
        let geometry = NotchGeometry.measure(screen)
        let pointer = NSEvent.mouseLocation

        // Closed: only the notch zone counts, so the panel can't be summoned by a
        // pointer that happens to be anywhere along the menu bar. Open: the panel's
        // own frame (plus slack) counts, *and* the notch still does — the notch is
        // inside the frame anyway, and this keeps the two consistent if the frame
        // ever stops covering it.
        let zone = layout.hoverZone(for: geometry, on: screen)
        let inside = model.isOpen
            ? layout.isPointerEngaged(pointer, panelFrame: panel.frame, zone: zone)
            : zone.contains(pointer)

        model.pointer(isInside: inside, now: ProcessInfo.processInfo.systemUptime)
        applyOpenState()

        // The band's depth is content-driven, and its content can change while it's
        // open (ticking a reminder off is the one inline action it offers).
        if isPanelVisible, model.visibleRowCount != sizedForRows {
            reposition()
        }
    }

    /// Order the panel in / out on the model's transitions only.
    private func applyOpenState() {
        guard model.isOpen != isPanelVisible else { return }
        isPanelVisible = model.isOpen
        if model.isOpen {
            reposition()
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }

    // MARK: - Geometry

    /// The display the pointer is on — hover opens the band on that screen's
    /// notch (or its top-center, if the display has no notch).
    private var targetScreen: NSScreen? {
        PointerScreen.current()
    }

    private func reposition() {
        guard let screen = targetScreen else { return }
        appliedScreenNumber = PointerScreen.number(of: screen)

        let geometry = NotchGeometry.measure(screen)
        // Sized to what the band is actually holding — resolved here, at the open, so
        // the panel and the view agree on one row count.
        let rows = model.visibleRowCount
        sizedForRows = rows
        let size = layout.panelSize(for: geometry, rows: rows)
        let origin = layout.panelOrigin(for: geometry, on: screen, rows: rows)

        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        host.rootView = NotchQuickActionsView(
            model: model,
            geometry: geometry,
            layout: layout,
            onOpenNotes: { [weak self] request in
                guard let self else { return }
                self.onOpenNotes(request)
                // The Settings window is coming forward; the band has done its job.
                self.dismiss()
            },
            onOpenSettings: { [weak self] in
                guard let self else { return }
                self.onOpenSettings()
                self.dismiss()
            }
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
    }

    deinit {
        pollTimer?.invalidate()
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }
}
