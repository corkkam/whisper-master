import AppKit
import Observation

/// How the band arrives.
enum OnboardingOpening: Equatable {
    /// First launch: the stage opens, folds into the band, and the band reveals.
    case stage
    /// A replay, or VoiceOver on a first launch: the band reveals at once.
    case reveal
}

/// The moments the window turns into panel changes during the opening.
enum OnboardingStageCue: Equatable {
    /// Order the band front at alpha 0, with clicks off.
    case primeBand
    /// The band shows and takes clicks.
    case swap
    /// The stage leaves.
    case end
}

/// Drives the notch onboarding band: which beat is on screen, the live
/// permission state, and the mic check that makes the orb react to your voice.
///
/// Owned by `NotchOnboardingWindow` and read by `NotchOnboardingView`. It never
/// touches `AppState` — the dictation view model remains that state's only
/// writer; this is a self-contained flow model that goes away with the window.
///
/// Motion lives here as timestamps on `clock`, never in view state, because the
/// window swaps the view on a wake or a display change. A delayed task, guarded
/// by `flowGeneration`, clears each timestamp after its duration; with a nil
/// timestamp the band draws its rest frame from state.
@MainActor
@Observable
final class NotchOnboardingModel {
    /// RMS level that counts as "we actually heard a voice", not room noise.
    private static let voiceThreshold: Float = 0.015

    // MARK: Presented state

    private(set) var step: NotchOnboardingStep = .microphone
    /// The microphone authorization, re-read on every refresh.
    private(set) var micStatus: PermissionsManager.MicStatus = .notDetermined
    var micGranted: Bool { micStatus == .granted }
    var micDenied: Bool { micStatus == .denied }
    /// True while the system's microphone prompt is up.
    private(set) var requestingMic = false
    private(set) var accessibilityGranted = false
    /// Registered *and* approved as a login item — the app will be there after a
    /// restart. Mirrors `LaunchAtLogin.isEnabled`, re-read on every poll tick so a
    /// change made in System Settings lands here too.
    private(set) var launchAtLoginEnabled = false
    /// Registered, but macOS is holding it for approval in Login Items. The one
    /// state that looks enabled and isn't, so the beat says so out loud.
    private(set) var launchAtLoginNeedsApproval = false
    /// Why the registration failed, if it did. Logged, never shown.
    private(set) var launchAtLoginError: String?
    /// Smoothed mic level. Non-zero only while the mic check is running, so the
    /// orb's wave is driven by real audio and nothing else.
    private(set) var level: Float = 0
    /// Latched the first time real audio arrives during the mic check.
    private(set) var heardVoice = false
    /// When `heardVoice` latched, for the orb's gain to rise from.
    private(set) var heardAt: TimeInterval?
    /// Whether the mic check is listening now.
    private(set) var micCheckRunning = false

    /// The microphone as the Ready beat words it.
    var readyMicStatus: ReadyMicStatus { ReadyMicStatus(micStatus) }

    var readyVariant: ReadyVariant {
        ReadyVariant.resolve(
            engine: engineStatus(), mic: readyMicStatus, typingOn: accessibilityGranted,
            showsAssistantLine: showsAssistantLine())
    }

    /// The state the band shows, which `OnboardingCopy` turns into words.
    var bandState: OnboardingState {
        switch step {
        case .microphone:
            if requestingMic { return .micPromptUp }
            if heardVoice { return .micHeard(.movingOn) }
            if micGranted { return micGrantedOnEntry == true ? .micOn(.movingOn) : .micWaiting }
            return micDenied ? .micDenied : .micAsk
        case .accessibility:
            return accessibilityGranted ? .typingGranted(.movingOn) : .typingAsk
        case .openAtLogin:
            if launchAtLoginEnabled { return .loginOn(.movingOn) }
            if launchAtLoginNeedsApproval { return .loginNeedsApproval }
            return launchAtLoginError == nil ? .loginAsk : .loginFailed
        case .ready:
            return .ready(readyVariant)
        }
    }

    /// What the orb is depicting: thinking while an ask is outstanding, working
    /// while the system prompt is up, listening once it can hear.
    var orbFigure: OrbFigure {
        let granted: Bool
        switch step {
        case .microphone: granted = micGranted
        case .accessibility: granted = accessibilityGranted
        case .openAtLogin: granted = launchAtLoginEnabled
        case .ready: granted = true
        }
        return OrbFigure.resolve(step: step, requestingMic: requestingMic, granted: granted, micCheckFailed: false)
    }

    // MARK: Motion

    struct BeatChange: Equatable {
        var at: TimeInterval
        var previous: OnboardingState
        /// A bloom held on the old beat fades out with its copy.
        var heldBloom: OnboardingBloom.Hue?
    }

    struct RowChange: Equatable {
        var at: TimeInterval
        var previous: OnboardingState
        /// The new row is a badge: draw its ring and glyph.
        var grant: Bool
    }

    struct Dip: Equatable {
        var at: TimeInterval
        /// The figure drawn until the dip's low point.
        var from: OrbFigure
        var start: OrbDip.Frame
    }

    struct OpeningSkip: Equatable {
        var at: TimeInterval
        /// How far into the opening the skip came.
        var elapsed: TimeInterval
    }

    let clock: OnboardingClock
    /// Read when the band shows. The window's poll keeps it current from the key work on.
    private(set) var policy = OnboardingMotionPolicy(layers: .full, skipsStage: false, orbIsStatic: false)
    /// First launch only: T0, when the stage was ordered front.
    private(set) var openingStartedAt: TimeInterval?
    private(set) var openingSkip: OpeningSkip?
    /// When the band's content starts to fade up.
    private(set) var revealStartedAt: TimeInterval?
    /// A replay gathers the orb as it reveals; after the stage it is already there.
    private(set) var revealGathers = false
    private(set) var beatChange: BeatChange?
    private(set) var rowChange: RowChange?
    /// The glow a live grant raised. It holds still until the beat changes.
    private(set) var heldBloom: OnboardingBloom.Hue?
    private(set) var dip: Dip?
    private(set) var outroStartedAt: TimeInterval?
    /// From show until input opens. Holds back the mic check and auto-advance.
    private(set) var introPlaying = false
    /// Set by `begin`, cleared by `teardown`. A closed window does nothing.
    private(set) var isLive = false

    /// The panel changes the opening asks for. Set by the window.
    var onStageCue: ((OnboardingStageCue) -> Void)?

    /// The end of the latest running timestamp. The band's timeline is paused
    /// from here on.
    var activeUntil: TimeInterval {
        var ends: [TimeInterval] = []
        if let revealStartedAt { ends.append(revealStartedAt + BandReveal.duration(policy: policy)) }
        if let beatChange { ends.append(beatChange.at + BeatTransition.duration(policy: policy)) }
        if let rowChange { ends.append(rowChange.at + Flourish.duration) }
        if let dip { ends.append(dip.at + OrbDip.duration) }
        if let outroStartedAt { ends.append(outroStartedAt + Outro.end) }
        if let heardAt { ends.append(heardAt + OnboardingOrbGain.floorRise) }
        return ends.max() ?? -.infinity
    }

    // MARK: Collaborators

    private let permissions: PermissionsProviding
    /// Its own capture session for the mic check — deliberately **not** the one
    /// inside `DictationViewModel`, since each `MicrophoneCaptureService` owns an
    /// `AVAudioEngine` and dictation must not share this one.
    private let capture: MicCheckCapturing
    /// The voice engine's state for the Ready beat. The model never reads
    /// `AppState`, so the window passes this in.
    let engineStatus: @MainActor () -> EngineStatus
    /// Whether Ready may name the assistant chord: it is available and at least
    /// one connector exists.
    private let showsAssistantLine: @MainActor () -> Bool
    /// Try Again on a failed Ready beat. Optional until `AppDelegate` wires it.
    let onRetryEngine: (() -> Void)?
    private var envelope = LevelEnvelope()
    /// Guards the auto-advance beat so the 0.75 s poll can't queue several.
    private var pendingAdvance = false
    /// Whether the mic was already allowed when the flow opened, latched on the
    /// first refresh. A returning user (relaunch, or "Reopen Onboarding…") has
    /// nothing to prove on the first beat, so they don't have to speak to leave it.
    private var micGrantedOnEntry: Bool?
    /// Prevents a double hand-off when a grant lands and the user also taps.
    private var didFinish = false
    /// Goes up in `teardown()`. Every delayed task stops if it changed.
    private var flowGeneration = 0
    /// Goes up on a skip, so the opening's own cues stand down.
    private var openingRun = 0
    private var stageUp = false
    /// The band has taken over from the stage.
    private var bandShown = false
    /// What the band last showed, to tell what changed. Nil until the band shows.
    private var shownState: OnboardingState?
    private var shownFigure: OrbFigure = .stage

    private let onComplete: (OnboardingFinish) -> Void
    private let onDismiss: () -> Void

    init(
        permissions: PermissionsProviding,
        capture: MicCheckCapturing = MicrophoneCaptureService(),
        clock: OnboardingClock = .live,
        engineStatus: @escaping @MainActor () -> EngineStatus,
        showsAssistantLine: @escaping @MainActor () -> Bool = { false },
        onComplete: @escaping (OnboardingFinish) -> Void,
        onDismiss: @escaping () -> Void,
        onRetryEngine: (() -> Void)? = nil
    ) {
        self.permissions = permissions
        self.capture = capture
        self.clock = clock
        self.engineStatus = engineStatus
        self.showsAssistantLine = showsAssistantLine
        self.onComplete = onComplete
        self.onDismiss = onDismiss
        self.onRetryEngine = onRetryEngine
    }

    // MARK: Lifecycle

    /// The band is on screen. Runs once per show; a window shown again after a
    /// close starts its opening afresh, so every trace of the last one goes.
    func begin(_ opening: OnboardingOpening, policy: OnboardingMotionPolicy) {
        guard !isLive else { return }
        isLive = true
        self.policy = policy
        introPlaying = true
        bandShown = false
        openingStartedAt = nil
        openingSkip = nil
        revealStartedAt = nil
        beatChange = nil
        rowChange = nil
        heldBloom = nil
        dip = nil
        outroStartedAt = nil
        shownState = nil
        refresh()
        let now = clock.now()
        guard opening == .stage, !policy.skipsStage else {
            startReveal(at: now, gathers: policy.layers == .full, afterStage: false)
            scheduleIntroEnd(revealAt: now)
            return
        }
        openingStartedAt = now
        stageUp = true
        let run = openingRun
        let full = policy.layers == .full
        let swapAt = full ? OpeningTimeline.swapAt : OpeningTimeline.stillSwapAt
        if full {
            after(OpeningTimeline.primeAt) { model in
                if model.openingRun == run { model.primeBand(revealAt: now + swapAt) }
            }
        }
        after(swapAt) { model in
            if model.openingRun == run { model.swapToBand() }
        }
        // The backstop: whatever happened to the cues, the stage is gone by 5 s.
        after(OpeningTimeline.watchdog) { model in
            guard model.stageUp else { return }
            model.swapToBand()
            model.endStage()
        }
    }

    /// A click on the stage. It blends to the swap frame over 250 ms; the still
    /// version swaps at once.
    func skipOpening() {
        guard let start = openingStartedAt, stageUp, openingSkip == nil, !bandShown else { return }
        let now = clock.now()
        openingSkip = OpeningSkip(at: now, elapsed: now - start)
        openingRun += 1
        let blend = policy.layers == .full ? OpeningTimeline.skipBlend : 0
        primeBand(revealAt: now + blend)
        after(blend) { model in model.swapToBand() }
    }

    /// The band goes front at alpha 0, already drawing the swap frame: its
    /// content waits for the reveal at `time`, and its orb holds the stage's
    /// figure until the dip. So the frame the band shows at the swap is never
    /// the band at rest.
    private func primeBand(revealAt time: TimeInterval) {
        startReveal(at: time, gathers: false, afterStage: true)
        onStageCue?(.primeBand)
    }

    /// The band takes over from the stage: it shows and takes clicks, and the
    /// stage leaves once the band has drawn.
    private func swapToBand() {
        guard stageUp, !bandShown else { return }
        bandShown = true
        if revealStartedAt == nil { primeBand(revealAt: clock.now()) }
        onStageCue?(.swap)
        scheduleIntroEnd(revealAt: revealStartedAt ?? clock.now())
        // The still version cross-fades, so its stage stays for the fade.
        after(policy.layers == .full ? OpeningTimeline.stageOutDelay : OpeningTimeline.stillFade) { model in
            model.endStage()
        }
    }

    private func endStage() {
        guard stageUp else { return }
        stageUp = false
        onStageCue?(.end)
    }

    /// The reveal's frames. After the stage, the band orb starts on the stage's
    /// figure and dips to the beat-1 figure, if that differs.
    private func startReveal(at time: TimeInterval, gathers: Bool, afterStage: Bool) {
        revealStartedAt = time
        revealGathers = gathers
        if afterStage, policy.layers == .full, orbFigure != OrbFigure.stage {
            dip = Dip(at: time + BandReveal.dipAt, from: OrbFigure.stage, start: OrbDip.rest)
            clearDipWhenDone()
        }
        let end = BandReveal.duration(policy: policy)
        after(time + end - clock.now()) { model in
            if model.revealStartedAt == time { model.revealStartedAt = nil }
        }
    }

    private func scheduleIntroEnd(revealAt time: TimeInterval) {
        after(time + BandReveal.inputOpens(policy: policy) - clock.now()) { model in model.introDidEnd() }
    }

    /// Input is open: the mic check and auto-advance may run.
    func introDidEnd() {
        guard introPlaying else { return }
        introPlaying = false
        refresh()
    }

    /// Re-read the permission state. Called on appear, on a slow poll, and when
    /// the app comes back from System Settings — the same three triggers the
    /// window-based flow used, since neither grant has a change notification.
    func refresh() {
        guard isLive else { return }
        micStatus = permissions.microphoneStatus()
        accessibilityGranted = permissions.accessibilityGranted()
        refreshLaunchAtLogin()
        if micGrantedOnEntry == nil { micGrantedOnEntry = micGranted }
        syncMicCheck()
        scheduleAdvanceIfSatisfied()
        syncPresentation()
    }

    /// Re-read the OS Login Items state. Neither registering nor approving posts a
    /// notification, so this rides the same 0.75 s poll as the two permissions —
    /// which is also what notices the approval the user just gave in System Settings.
    private func refreshLaunchAtLogin() {
        let launch = LaunchAtLogin.shared
        launch.refresh()
        launchAtLoginEnabled = launch.isEnabled
        launchAtLoginNeedsApproval = launch.needsApproval
        launchAtLoginError = launch.lastError
    }

    /// Release the mic and stop every delayed task. Must be called when the band
    /// goes away, or the check keeps the input device hot after onboarding.
    func teardown() {
        isLive = false
        flowGeneration += 1
        stageUp = false
        stopMicCheck()
    }

    // MARK: Actions

    /// A button in the action row.
    func perform(_ button: OnboardingButton) {
        switch button {
        case .allowMicrophone:
            Task { await grantMicrophone() }
        case .allowTyping:
            grantAccessibility()
        case .startWithMac:
            enableLaunchAtLogin()
        case .openLoginItems:
            openLoginItemsSettings()
        case .openSystemSettings:
            switch bandState {
            case .ready(.typingOff), .ready(.loadingTypingOff), .typingStillOff:
                permissions.openAccessibilitySettings()
            default:
                permissions.openMicrophoneSettings()
            }
        case .tryAgain:
            switch step {
            case .microphone: retryMicCheck()
            case .openAtLogin: enableLaunchAtLogin()
            case .ready: onRetryEngine?()
            case .accessibility: break
            }
        case .notNow, .continue:
            advance()
        case .done:
            finish(.handBack)
        case .closeAndOpenSettings:
            finish(.openSettings)
        }
    }

    func grantMicrophone() async {
        refresh()
        // Already refused once: the prompt won't come back, so send them to the
        // one place that can still turn it on.
        if micDenied {
            permissions.openMicrophoneSettings()
            return
        }
        requestingMic = true
        syncPresentation()
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

    /// Register the app as a login item. When macOS holds it for approval the beat
    /// switches to the "approve it" ask instead of claiming success.
    func enableLaunchAtLogin() {
        LaunchAtLogin.shared.setEnabled(true)
        // A failure is logged by `LaunchAtLogin`; the band shows the failed copy only.
        refreshLaunchAtLogin()
        scheduleAdvanceIfSatisfied()
        syncPresentation()
    }

    /// Send the user to the one pane that can approve a held registration.
    func openLoginItemsSettings() {
        LaunchAtLogin.shared.openLoginItemsSettings()
    }

    func advance() {
        guard let next = step.next else {
            finish(.handBack)
            return
        }
        step = next
        syncMicCheck()
        syncPresentation()
    }

    /// The user finished the flow: Done (`.handBack`) or Close and open
    /// Settings (`.openSettings`). The band folds into the notch first, then
    /// `onComplete` runs. Runs once; a second tap is ignored.
    func finish(_ kind: OnboardingFinish) {
        finish(kind, outro: true)
    }

    /// The capture key went down on Ready with the microphone on: finish at once,
    /// with no outro, so `AppDelegate` can start the recording in the same call
    /// and keep the first word.
    func handOff() {
        finish(.handBack, outro: false)
    }

    private func finish(_ kind: OnboardingFinish, outro: Bool) {
        guard !didFinish else { return }
        didFinish = true
        stopMicCheck()
        // A band that is not on screen has nothing to fold.
        guard outro, isLive, Outro.duration(policy: policy) > 0 else {
            onComplete(kind)
            return
        }
        outroStartedAt = clock.now()
        after(Outro.end) { model in model.onComplete(kind) }
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
        case .openAtLogin:
            // Approved-and-on only. `.requiresApproval` deliberately does not
            // satisfy the beat — that state doesn't launch at login, so moving on
            // from it would teach the user setup was done when it wasn't.
            return launchAtLoginEnabled
        case .ready:
            return false
        }
    }

    /// Move on once the ask is satisfied, after a short beat so the
    /// confirmation is seen rather than flashing past.
    private func scheduleAdvanceIfSatisfied() {
        guard isLive, !introPlaying, !pendingAdvance, !didFinish, satisfied else { return }
        pendingAdvance = true
        after(step == .microphone ? 1.1 : 0.7) { model in
            model.pendingAdvance = false
            // The state can change during the beat (a permission revoked in
            // System Settings), so re-check rather than trusting the schedule.
            guard !model.didFinish, model.satisfied else { return }
            model.advance()
        }
    }

    // MARK: Presentation

    /// Notes what the band now shows, and starts the frames for what changed: a
    /// dip when the orb's figure changes, a beat transition when the step
    /// changes, and a flourish when the row changes inside a beat. Ready's
    /// variant follows the download, so it changes in place.
    private func syncPresentation() {
        let state = bandState
        let figure = orbFigure
        guard isLive, let shown = shownState else {
            shownState = state
            shownFigure = figure
            return
        }
        let now = clock.now()
        if figure != shownFigure {
            startDip(from: shownFigure, at: now)
            shownFigure = figure
        }
        guard state != shown else { return }
        shownState = state
        if state.step != shown.step {
            beatChange = BeatChange(at: now, previous: shown, heldBloom: heldBloom)
            rowChange = nil
            heldBloom = nil
            after(BeatTransition.duration(policy: policy)) { model in
                if model.beatChange?.at == now { model.beatChange = nil }
            }
            return
        }
        if case .ready = state { return }
        let grant: Bool
        if case .badge = OnboardingCopy().screen(state).row { grant = true } else { grant = false }
        rowChange = RowChange(at: now, previous: shown, grant: grant)
        // A live grant raises the bloom; the still version raises none.
        if grant, policy.layers == .full {
            heldBloom = OnboardingBloom.hue(for: state.step, heardVoice: heardVoice)
        }
        after(Flourish.duration) { model in
            if model.rowChange?.at == now { model.rowChange = nil }
        }
    }

    /// The orb changes figure by a dip. A second change before the low point only
    /// changes the target; from the low point on, a new dip starts from where the
    /// orb is.
    private func startDip(from old: OrbFigure, at now: TimeInterval) {
        if let running = dip, running.at <= now {
            let elapsed = now - running.at
            guard OrbDip.restarts(changeAt: elapsed) else { return }
            dip = Dip(at: now, from: old, start: OrbDip.frame(at: elapsed, from: running.start, policy: policy))
        } else {
            dip = Dip(at: now, from: old, start: OrbDip.rest)
        }
        clearDipWhenDone()
    }

    /// Clears the dip once it has played, counted from its own start, which can
    /// lie ahead (the opening's dip is armed at the prime).
    private func clearDipWhenDone() {
        guard let at = dip?.at else { return }
        after(at + OrbDip.duration - clock.now()) { model in
            if model.dip?.at == at { model.dip = nil }
        }
    }

    /// Runs `body` after `delay` seconds, unless the window closed meanwhile.
    private func after(_ delay: TimeInterval, _ body: @escaping @MainActor (NotchOnboardingModel) -> Void) {
        let generation = flowGeneration
        Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard let self, self.flowGeneration == generation else { return }
            body(self)
        }
    }

    // MARK: Mic check

    /// The mic runs during the microphone beat only, and only once it's allowed
    /// — that beat is the one place the copy says we're listening. Never during
    /// the intro: the user has not been asked anything yet.
    private func syncMicCheck() {
        if isLive, !introPlaying, step == .microphone, micGranted {
            startMicCheck()
        } else {
            stopMicCheck()
        }
    }

    /// Try Again on the microphone beat: start the mic check over.
    private func retryMicCheck() {
        stopMicCheck()
        syncMicCheck()
    }

    private func startMicCheck() {
        guard !micCheckRunning else { return }
        micCheckRunning = true
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
            micCheckRunning = false
            Log.app.error("Onboarding mic check failed to start: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func consume(level raw: Float) {
        guard isLive, micCheckRunning else { return }
        level = envelope.step(target: raw)
        guard level > Self.voiceThreshold, !heardVoice else { return }
        heardVoice = true
        heardAt = clock.now()
        syncPresentation()
        // This is what the microphone beat was waiting on, so move on from here
        // rather than idling until the next poll tick.
        scheduleAdvanceIfSatisfied()
    }

    private func stopMicCheck() {
        guard micCheckRunning else { return }
        micCheckRunning = false
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
        micGrantedOnEntry: Bool = false,
        requestingMic: Bool = false,
        accessibilityGranted: Bool = false,
        launchAtLoginEnabled: Bool = false,
        launchAtLoginNeedsApproval: Bool = false,
        heardVoice: Bool = false,
        level: Float = 0,
        showsAssistantLine: Bool = false,
        clock: OnboardingClock = .fixed(0),
        engineStatus: @escaping @MainActor () -> EngineStatus = { .ready }
    ) -> NotchOnboardingModel {
        let model = NotchOnboardingModel(
            permissions: PermissionsManager(), clock: clock, engineStatus: engineStatus,
            showsAssistantLine: { showsAssistantLine }, onComplete: { _ in }, onDismiss: {})
        model.step = step
        model.micStatus = micGranted ? .granted : (micDenied ? .denied : .notDetermined)
        model.micGrantedOnEntry = micGrantedOnEntry
        model.requestingMic = requestingMic
        model.accessibilityGranted = accessibilityGranted
        model.launchAtLoginEnabled = launchAtLoginEnabled
        model.launchAtLoginNeedsApproval = launchAtLoginNeedsApproval
        model.heardVoice = heardVoice
        model.level = level
        return model
    }

    /// Pins the opening `t` seconds after T0, optionally skipped `skipAt` seconds
    /// in, on the fixed clock.
    func pinOpening(at t: TimeInterval, skipAt: TimeInterval? = nil) {
        let now = clock.now()
        let start = now - t
        openingStartedAt = start
        var swap = policy.layers == .full ? OpeningTimeline.swapAt : OpeningTimeline.stillSwapAt
        if let skipAt, skipAt <= t {
            openingSkip = OpeningSkip(at: start + skipAt, elapsed: skipAt)
            swap = skipAt + (policy.layers == .full ? OpeningTimeline.skipBlend : 0)
        }
        if t >= swap { startReveal(at: start + swap, gathers: false, afterStage: true) }
    }

    /// Pins a replay's reveal `t` seconds in.
    func pinReveal(at t: TimeInterval) {
        startReveal(at: clock.now() - t, gathers: true, afterStage: false)
    }

    /// Pins a change into this state from `previous`, `t` seconds in: a beat
    /// transition when the step differs, a flourish inside one beat. A badge on
    /// `previous` holds its bloom, as a live grant would have left it.
    func pinChange(from previous: OnboardingState, previousFigure: OrbFigure, at t: TimeInterval) {
        shownState = previous
        shownFigure = previousFigure
        if case .badge = OnboardingCopy().screen(previous).row {
            heldBloom = OnboardingBloom.hue(for: previous.step, heardVoice: heardVoice)
        }
        isLive = true
        syncPresentation()
        isLive = false
        beatChange?.at -= t
        rowChange?.at -= t
        dip?.at -= t
    }

    /// Pins the outro `t` seconds in.
    func pinOutro(at t: TimeInterval) {
        outroStartedAt = clock.now() - t
    }

    func pinPolicy(_ policy: OnboardingMotionPolicy) {
        self.policy = policy
    }
    #endif
}
