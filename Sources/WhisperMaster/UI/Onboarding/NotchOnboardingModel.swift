import AppKit
import Observation

/// Drives the notch onboarding band: which beat is on screen, the live
/// permission state, and the mic check that makes the orb react to your voice.
///
/// Owned by `NotchOnboardingWindow` and read by `NotchOnboardingView`. It never
/// touches `AppState` — the dictation view model remains that state's only
/// writer; this is a self-contained flow model that goes away with the window.
@MainActor
@Observable
final class NotchOnboardingModel {
    /// RMS level that counts as "we actually heard a voice", not room noise.
    private static let voiceThreshold: Float = 0.015

    // MARK: Presented state

    private(set) var step: NotchOnboardingStep = .microphone
    private(set) var micGranted = false
    private(set) var micDenied = false
    /// True while the system's microphone prompt is up.
    private(set) var requestingMic = false
    private(set) var accessibilityGranted = false
    /// Smoothed mic level. Non-zero only while the mic check is running, so the
    /// orb's wave is driven by real audio and nothing else.
    private(set) var level: Float = 0
    /// Latched the first time real audio arrives during the mic check.
    private(set) var heardVoice = false

    // MARK: Collaborators

    private let permissions: PermissionsManager
    /// Its own capture session for the mic check — deliberately **not** the one
    /// inside `DictationViewModel`, since each `MicrophoneCaptureService` owns an
    /// `AVAudioEngine` and dictation must not share this one.
    private let capture = MicrophoneCaptureService()
    private var envelope = LevelEnvelope()
    private var isCheckingMic = false
    /// Guards the auto-advance beat so the 0.75 s poll can't queue several.
    private var pendingAdvance = false
    /// Whether the mic was already allowed when the flow opened, latched on the
    /// first refresh. A returning user (relaunch, or "Reopen Onboarding…") has
    /// nothing to prove on the first beat, so they don't have to speak to leave it.
    private var micGrantedOnEntry: Bool?
    /// Prevents a double hand-off when a grant lands and the user also taps.
    private var didFinish = false

    private let onComplete: () -> Void
    private let onDismiss: () -> Void

    init(
        permissions: PermissionsManager,
        onComplete: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.permissions = permissions
        self.onComplete = onComplete
        self.onDismiss = onDismiss
    }

    // MARK: Lifecycle

    /// Re-read the permission state. Called on appear, on a slow poll, and when
    /// the app comes back from System Settings — the same three triggers the
    /// window-based flow used, since neither grant has a change notification.
    func refresh() {
        let status = permissions.microphoneStatus()
        micGranted = status == .granted
        micDenied = status == .denied
        accessibilityGranted = permissions.accessibilityGranted()
        if micGrantedOnEntry == nil { micGrantedOnEntry = micGranted }
        syncMicCheck()
        scheduleAdvanceIfSatisfied()
    }

    /// Release the mic. Must be called when the band goes away, or the check
    /// keeps the input device hot after onboarding.
    func teardown() {
        stopMicCheck()
    }

    // MARK: Actions

    func grantMicrophone() async {
        refresh()
        // Already refused once: the prompt won't come back, so send them to the
        // one place that can still turn it on.
        if micDenied {
            permissions.openMicrophoneSettings()
            return
        }
        requestingMic = true
        _ = await permissions.requestMicrophone()
        requestingMic = false
        // The system prompt takes focus; come back so the band is live again.
        NSApp.activate(ignoringOtherApps: true)
        refresh()
        if micDenied {
            permissions.openMicrophoneSettings()
        }
    }

    /// `promptAccessibility()` registers the app in the Accessibility list and
    /// shows the system prompt; opening the pane puts the toggle one click away.
    /// The poll + didBecomeActive refresh keep the band live across the trip.
    func grantAccessibility() {
        permissions.promptAccessibility()
        permissions.openAccessibilitySettings()
    }

    func advance() {
        guard let next = step.next else {
            finish()
            return
        }
        step = next
        syncMicCheck()
    }

    /// The user finished the flow (or tapped through the last beat).
    func finish() {
        guard !didFinish else { return }
        didFinish = true
        teardown()
        onComplete()
    }

    /// The user closed the band early.
    func dismiss() {
        guard !didFinish else { return }
        didFinish = true
        teardown()
        onDismiss()
    }

    // MARK: Auto-advance

    /// Whether the current ask is done and the flow can move on by itself.
    private var satisfied: Bool {
        switch step {
        case .microphone:
            // Granted *and* proven: moving on the instant the grant lands would
            // skip the one beat that shows dictation actually hears you. Someone
            // who arrived already granted has nothing to prove, so they pass on
            // the grant alone.
            return micGranted && (heardVoice || micGrantedOnEntry == true)
        case .accessibility:
            return accessibilityGranted
        case .ready:
            return false
        }
    }

    /// Move on once the ask is satisfied, after a short beat so the
    /// confirmation is seen rather than flashing past.
    private func scheduleAdvanceIfSatisfied() {
        guard !pendingAdvance, !didFinish, satisfied else { return }
        pendingAdvance = true
        let beat = step == .microphone ? 1_100 : 700
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(beat))
            pendingAdvance = false
            // The state can change during the beat (a permission revoked in
            // System Settings), so re-check rather than trusting the schedule.
            guard !didFinish, satisfied else { return }
            advance()
        }
    }

    // MARK: Mic check

    /// The mic runs during the microphone beat only, and only once it's allowed
    /// — that beat is the one place the copy says we're listening.
    private func syncMicCheck() {
        if step == .microphone && micGranted {
            startMicCheck()
        } else {
            stopMicCheck()
        }
    }

    private func startMicCheck() {
        guard !isCheckingMic else { return }
        isCheckingMic = true
        envelope.reset()
        do {
            try capture.start(
                bufferHandler: { _ in },
                levelHandler: { [weak self] level in
                    Task { @MainActor in
                        self?.consume(level: level)
                    }
                }
            )
        } catch {
            // No meter — the orb keeps its calm figure and the user can still
            // continue. A mid-route-switch input is the usual cause.
            isCheckingMic = false
            Log.app.error("Onboarding mic check failed to start: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func consume(level raw: Float) {
        level = envelope.step(target: raw)
        guard level > Self.voiceThreshold, !heardVoice else { return }
        heardVoice = true
        // This is what the microphone beat was waiting on, so move on from here
        // rather than idling until the next poll tick.
        scheduleAdvanceIfSatisfied()
    }

    private func stopMicCheck() {
        guard isCheckingMic else { return }
        isCheckingMic = false
        capture.stop()
        envelope.reset()
        level = 0
    }

    #if DEBUG
    /// A model pinned to one beat, for the headless snapshot renderer. Not used
    /// by the app — the flow always starts at `.microphone` and polls its way
    /// forward. Compiled out of Release.
    static func snapshot(
        step: NotchOnboardingStep,
        micGranted: Bool = false,
        micDenied: Bool = false,
        accessibilityGranted: Bool = false,
        heardVoice: Bool = false,
        level: Float = 0
    ) -> NotchOnboardingModel {
        let model = NotchOnboardingModel(permissions: PermissionsManager(), onComplete: {}, onDismiss: {})
        model.step = step
        model.micGranted = micGranted
        model.micDenied = micDenied
        model.accessibilityGranted = accessibilityGranted
        model.heardVoice = heardVoice
        model.level = level
        return model
    }
    #endif
}
