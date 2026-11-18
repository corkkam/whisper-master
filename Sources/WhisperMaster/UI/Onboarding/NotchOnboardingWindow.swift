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
///
/// The band takes the keyboard only while our app is already active, or after
/// a click on it; it never activates the app to get it. When setup ends it
/// gives focus back to the app the user came from.
///
/// On the launch path it also owns the opening's `OnboardingStagePanel`, and
/// turns the model's stage cues into panel changes.
@MainActor
final class NotchOnboardingWindow {
    private let panel = OnboardingKeyPanel()
    private let host: NSHostingView<NotchOnboardingView>
    private let model: NotchOnboardingModel
    private let state: AppState
    private let layout = NotchOnboardingLayout()
    /// The first-launch stage, until the band takes over from it.
    private var stage: OnboardingStagePanel?
    /// The app in front when setup showed, which gets focus back when it ends.
    private var previousApp: NSRunningApplication?
    /// Whether the Settings window is on screen (an About replay keeps it).
    private let settingsVisible: () -> Bool

    private var screenObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var activeObserver: NSObjectProtocol?
    private var resignObserver: NSObjectProtocol?
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
        onComplete: @escaping (OnboardingFinish) -> Void,
        onRetryEngine: (() -> Void)? = nil,
        settingsVisible: @escaping () -> Bool = { false }
    ) {
        self.state = state
        self.settingsVisible = settingsVisible
        model = NotchOnboardingModel(
            permissions: permissions,
            engineStatus: { EngineStatus(state) },
            showsAssistantLine: {
                FeatureFlags.connectorsAndNotesAvailable && !state.connectorStore.instances.isEmpty
            },
            onComplete: onComplete,
            onDismiss: onClose,
            onRetryEngine: onRetryEngine
        )

        host = NSHostingView(rootView: NotchOnboardingView(
            model: model, state: state))
        host.autoresizingMask = [.width, .height]
        panel.contentView = host

        model.onStageCue = { [weak self] cue in self?.apply(cue) }
        model.onOpenSettings = onOpenSettings
        model.willEnd = { [weak self] kind in
            // Close and open Settings keeps focus: Settings is where it goes.
            let handsBack = kind.map { OnboardingFinishPlan.plan(for: $0, signOutInFlight: false).handsFocusBack } ?? true
            if handsBack { self?.handFocusBack() }
        }
        wire(panel)
        panel.inputOpensAt = { [weak model] in model?.inputOpensAt ?? .infinity }
        panel.onClick = { [weak model] in model?.noteClick() }
        panel.onKeyChange = { [weak model] isKey in model?.panelKeyDidChange(isKey) }
        observeEnvironment()
        reposition()
    }

    /// The model hears the panel's keys and asks the same "is our app active".
    private func wire(_ panel: OnboardingKeyPanel) {
        panel.isActive = model.environment.isActive
        panel.onKey = { [weak model] key, isRepeat, time in model?.handleKey(key, isRepeat: isRepeat, at: time) }
    }

    /// `opening` applies only when the band is not already up: the launch path
    /// opens on the stage, a replay at the band. It never activates the app: the
    /// band takes the keyboard only if our app is active already.
    func show(opening: OnboardingOpening = .reveal) {
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front == NSRunningApplication.current ? nil : front
        if model.isLive {
            // Already up: bring it front, unless the stage still has the screen.
            if stage == nil {
                panel.orderFrontRegardless()
                panel.makeKeyIfActive()
            }
            model.refresh()
        } else {
            begin(opening)
        }
        startPolling()
        startFollowing()
    }

    /// The first show. The launch path opens on the stage; a replay, and
    /// VoiceOver, start at the band.
    private func begin(_ opening: OnboardingOpening) {
        let policy = Self.currentPolicy()
        model.updatePolicy(policy, switchControl: NSWorkspace.shared.isSwitchControlEnabled)
        if opening == .stage, !policy.skipsStage, let screen = targetScreen {
            let stage = OnboardingStagePanel(model: model, screen: screen, layout: layout)
            wire(stage.panel)
            self.stage = stage
            stage.show()
            model.begin(.stage, policy: policy)
        } else {
            // A window closed mid-opening may still be primed at alpha 0.
            panel.alphaValue = 1
            panel.ignoresMouseEvents = false
            panel.orderFrontRegardless()
            panel.makeKeyIfActive()
            model.begin(.reveal, policy: policy)
        }
    }

    private static func currentPolicy() -> OnboardingMotionPolicy {
        OnboardingMotionPolicy.resolve(
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermal: ProcessInfo.processInfo.thermalState,
            voiceOver: NSWorkspace.shared.isVoiceOverEnabled)
    }

    /// The opening's panel changes. The band is primed at alpha 0 with clicks
    /// off, shows at the swap, and the stage leaves once the band has drawn.
    private func apply(_ cue: OnboardingStageCue) {
        switch cue {
        case .primeBand:
            panel.alphaValue = 0
            panel.ignoresMouseEvents = true
            panel.orderFrontRegardless()
        case .swap:
            panel.alphaValue = 1
            panel.ignoresMouseEvents = false
            panel.orderFrontRegardless()
            panel.makeKeyIfActive()
        case .end:
            stage?.close()
            stage = nil
        }
    }

    // MARK: Dictation keys during setup (read by `AppDelegate`)

    var step: NotchOnboardingStep { model.step }
    var micGranted: Bool { model.micGranted }
    /// The mic check's waiting copy already says to hold the key, so no nudge then.
    var micCheckListening: Bool { model.micCheckRunning }
    /// The hand-off happens only once the engine is ready.
    var engineReady: Bool { model.engineStatus() == .ready }

    /// A capture key press that setup ignored: the top-bar line nudges.
    func noteSwallowedPress() {
        model.noteSwallowedPress()
    }

    /// The capture key went down on Ready with the microphone on: cut the band
    /// with no outro. The caller starts the recording in the same call.
    func handOff() {
        model.handOff()
    }

    /// Done, the hand-off and close: if our app is not active, nothing.
    /// Otherwise the app the user came from comes back; with none, Settings
    /// stays if it is up (an About replay), and else the app steps back.
    private func handFocusBack() {
        guard NSApp.isActive else { return }
        if let previousApp, !previousApp.isTerminated {
            previousApp.activate()
        } else if !settingsVisible() {
            NSApp.deactivate()
        }
    }

    /// Hide the band, stop polling and release the mic check. Safe to call twice.
    func close() {
        pollTimer?.invalidate()
        pollTimer = nil
        followTimer?.invalidate()
        followTimer = nil
        stage?.close()
        stage = nil
        model.teardown()
        panel.orderOut(nil)
    }

    private func startPolling() {
        guard pollTimer == nil else { return }
        let timer = Timer(timeInterval: 0.75, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // The model writes the policy only when it changed.
                self.model.updatePolicy(
                    Self.currentPolicy(), switchControl: NSWorkspace.shared.isSwitchControlEnabled)
                self.model.refresh()
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
        // The stage stays where it opened; the band follows once it has the screen.
        guard stage == nil else { return }
        // Polled, not tracked, as the hover band is: a move over the band stops
        // a moving-on step, and where the pointer is sets the floor.
        let pointer = NSEvent.mouseLocation
        model.notePointer(pointer, overBand: panel.alphaValue > 0 && panel.frame.contains(pointer))
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
            layout: layout
        )
    }

    private func observeEnvironment() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                // A display change skips the opening; the band re-anchors.
                self?.model.skipOpening()
                self?.reposition()
            }
        }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.model.skipOpening()
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
                guard let self else { return }
                // Our app is active again: setup takes the keyboard, unless
                // another of our windows (Settings) already holds it.
                let ours = [self.panel, self.stage?.panel].compactMap { $0 }
                if OnboardingKeyPanel.takesKeyboardOnActivation(keyWindow: NSApp.keyWindow, ours: ours) {
                    if self.stage == nil { self.panel.makeKeyIfActive() } else { self.stage?.panel.makeKeyIfActive() }
                }
                self.model.appDidBecomeActive()
            }
        }

        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.model.appDidResignActive()
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
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
        }
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }
}
