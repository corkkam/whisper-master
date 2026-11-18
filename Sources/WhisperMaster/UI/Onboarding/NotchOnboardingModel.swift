import AppKit
import Observation

/// How the band arrives.
enum OnboardingOpening: Equatable {
    /// Every show, a replay included: the stage opens, folds into the band, and
    /// the band reveals.
    case stage
    /// VoiceOver, or no screen for the stage: the band reveals at once.
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
    /// No voice this long after the waiting copy shows, and the body says to
    /// check the microphone.
    static let silence: TimeInterval = 8
    /// How long the top-bar nudge after an ignored capture key press stays.
    static let nudgeDuration: TimeInterval = 4
    private static let systemSettingsID = "com.apple.systempreferences"

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
    /// The mic check could not start. Try Again starts it over.
    private(set) var micCheckFailed = false
    /// About 8 s with no voice on the waiting copy.
    private(set) var micStillSilent = false
    /// Allow Typing was pressed in this flow. Not persisted.
    private(set) var typingAsked = false
    /// The user came back after asking: left System Settings, made the app
    /// active, or clicked the band. Written only from false to true.
    private(set) var typingReturned = false

    /// The microphone as the Ready beat words it.
    var readyMicStatus: ReadyMicStatus { ReadyMicStatus(micStatus) }

    var readyVariant: ReadyVariant {
        ReadyVariant.resolve(
            engine: engineStatus(), mic: readyMicStatus, typingOn: accessibilityGranted,
            showsAssistantLine: showsAssistantLine())
    }

    /// The state the band shows, which `OnboardingCopy` turns into words.
    var bandState: OnboardingState {
        let base = baseState
        return base.withDoneRow(doneRow(for: base)) ?? base
    }

    /// The state with every done row read as moving on: what the beat is,
    /// before the row says whether it moves on or waits.
    private var baseState: OnboardingState {
        switch step {
        case .microphone:
            if requestingMic { return .micPromptUp }
            if heardVoice { return .micHeard(.movingOn) }
            if micGranted {
                // The mic can hear VoiceOver, so no mic check runs under it.
                if voiceOverOn { return .micOnVoiceOver }
                if micCheckFailed { return .micFailed }
                if micGrantedOnEntry == true || backStep == .microphone { return .micOn(.movingOn) }
                return micStillSilent ? .micStillSilent : .micWaiting
            }
            return micDenied ? .micDenied : .micAsk
        case .accessibility:
            switch TypingStatus.resolve(trusted: accessibilityGranted, asked: typingAsked, returned: typingReturned) {
            case .granted: return .typingGranted(.movingOn)
            case .stillOff: return .typingStillOff
            case .ask: return .typingAsk
            }
        case .openAtLogin:
            if launchAtLoginEnabled { return .loginOn(.movingOn) }
            if launchAtLoginNeedsApproval { return .loginNeedsApproval }
            return launchAtLoginError == nil ? .loginAsk : .loginFailed
        case .ready:
            return .ready(readyVariant)
        }
    }

    /// A done step moves on by itself or waits, never both. It waits for
    /// Continue under VoiceOver or Switch Control, after Back, and once its
    /// auto-advance was cancelled; the paused row is the app not being active.
    private func doneRow(for base: OnboardingState) -> OnboardingDoneRow {
        if waitsForTap(base) { return .waits }
        switch doneWait?.cancel {
        case .appInactive?: return .paused
        case .interaction?: return .waits
        case nil: return .movingOn
        }
    }

    private func waitsForTap(_ base: OnboardingState) -> Bool {
        voiceOverOn || switchControlOn || (backState != nil && base == backState)
    }

    /// The badge and Continue show from the start: under VoiceOver or Switch
    /// Control, and on a beat the user came back to.
    var waitsForTap: Bool { waitsForTap(baseState) }

    /// The action row as it stands now.
    var currentRow: OnboardingRow {
        OnboardingCopy(canRetryEngine: onRetryEngine != nil).screen(bandState).row
    }

    /// Back shows on beats 2 to 4, and is disabled while a system prompt is up.
    var backEnabled: Bool { step.previous != nil && !requestingMic }

    /// What the top-bar line reads from.
    var topBarContext: OnboardingTopBarContext {
        OnboardingTopBarContext(
            step: step, readyVariant: step == .ready ? readyVariant : nil, readyMic: readyMicStatus,
            nudging: nudgeAt != nil, micCheckListening: micCheckRunning,
            pausedWhileInactive: doneWait?.cancel == .appInactive && !appIsActive, panelIsKey: panelIsKey)
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
        return OrbFigure.resolve(
            step: step, requestingMic: requestingMic, granted: granted, micCheckFailed: micCheckFailed)
    }

    // MARK: Keys and focus

    /// A focus move the model makes, which the view applies. `serial` tells two
    /// moves to the same control apart.
    struct FocusRequest: Equatable {
        var action: OnboardingAction?
        var serial = 0
    }

    /// System uptime from which keys, clicks and accessibility presses count.
    /// The clock of `NSEvent.timestamp`, so the panel can compare them.
    private(set) var inputOpensAt: TimeInterval = .infinity
    /// The band's panel has the keyboard. Lines name Escape or Command W only then.
    private(set) var panelIsKey = false
    /// Whether our app is active. A done step moves on by itself only then.
    private(set) var appIsActive = false
    /// The focused control, as the view reports it. A mouse click does not set it.
    private(set) var focusedAction: OnboardingAction?
    private(set) var focusRequest = FocusRequest()
    /// Goes up each time the headline changes and at the prompt-up swap. The
    /// view then moves VoiceOver focus to the headline, so it is read once.
    private(set) var headlineFocusToken = 0
    private(set) var switchControlOn = false
    /// When an ignored capture key press last nudged the top-bar line.
    private(set) var nudgeAt: TimeInterval?
    /// The current beat's auto-advance. Nil until a done step's copy shows.
    private(set) var doneWait: OnboardingAutoAdvance?
    /// Read when a done step's copy shows: the floor is longer when the
    /// pointer is elsewhere.
    private(set) var pointerOverBand = false
    /// The gear and its key: opens Settings. Set by the window.
    var onOpenSettings: (() -> Void)?
    /// Runs just before `onComplete` (with the kind) or `onDismiss` (with nil),
    /// for the window to give focus back. Set by the window.
    var willEnd: ((OnboardingFinish?) -> Void)?

    /// VoiceOver selects the still layers and skips the stage; the model reads it from there.
    var voiceOverOn: Bool { policy.skipsStage }

    // MARK: Motion

    struct BeatChange: Equatable {
        var at: TimeInterval
        var previous: OnboardingState
        /// A bloom held on the old beat fades out with its copy.
        var heldBloom: OnboardingBloom.Hue?
        /// Back: the copy slides the other way.
        var backward = false
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
    /// With the stage only: T0, when the stage was ordered front.
    private(set) var openingStartedAt: TimeInterval?
    private(set) var openingSkip: OpeningSkip?
    /// When the band's content starts to fade up.
    private(set) var revealStartedAt: TimeInterval?
    /// With no stage the orb gathers as the band reveals; after the stage it is already there.
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
    let environment: OnboardingEnvironment
    private var envelope = LevelEnvelope()
    /// Goes up whenever the auto-advance is armed again or cancelled, so a
    /// scheduled advance from an older wait stands down.
    private var waitRun = 0
    /// The same for the silence timer on the mic check's waiting copy.
    private var silenceRun = 0
    private var silenceArmed = false
    /// When the copy now on screen is fully visible. A done step's floor counts from here.
    private var copyVisibleAt: TimeInterval = 0
    /// Back to this step: its done state waits for Continue, and a microphone
    /// beat whose voice was heard does not listen again.
    private var backStep: NotchOnboardingStep?
    /// The beat's state when Back landed on it. "After Back" holds until it changes.
    private var backState: OnboardingState?
    /// True only while `back()` presents its beat change.
    private var goingBack = false
    /// A focus move the model made, until the view reports it.
    private var pendingFocusReport: OnboardingAction?
    /// The press on Allow Microphone, while the system prompt is up. Cancelled
    /// in `teardown()`, so a closed band does not bring the app forward.
    @ObservationIgnored private var micRequest: Task<Void, Never>?
    /// The last pointer location the window reported, to tell a move from a re-report.
    @ObservationIgnored private var lastPointer: CGPoint?
    private var sawSettingsInFront = false
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
        onRetryEngine: (() -> Void)? = nil,
        // Optional so the main-actor `.live` is read inside the init, not in the caller.
        environment: OnboardingEnvironment? = nil
    ) {
        self.permissions = permissions
        self.capture = capture
        self.clock = clock
        self.engineStatus = engineStatus
        self.showsAssistantLine = showsAssistantLine
        self.onComplete = onComplete
        self.onDismiss = onDismiss
        self.onRetryEngine = onRetryEngine
        self.environment = environment ?? .live
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
        focusedAction = nil
        pendingFocusReport = nil
        doneWait = nil
        nudgeAt = nil
        backStep = nil
        backState = nil
        micCheckFailed = false
        micStillSilent = false
        silenceArmed = false
        typingAsked = false
        typingReturned = false
        sawSettingsInFront = false
        appIsActive = environment.isActive()
        refresh()
        let now = clock.now()
        guard opening == .stage, !policy.skipsStage else {
            inputOpensAt = OnboardingInputGate.opensAt(.reveal, at: now, policy: policy)
            startReveal(at: now, gathers: policy.layers == .full, afterStage: false)
            scheduleIntroEnd(revealAt: now)
            // Under VoiceOver the band is the first thing shown: one
            // announcement, then focus moves to the headline.
            if voiceOverOn {
                environment.announce(
                    appIsActive ? OnboardingCopy.firstAnnouncement : OnboardingCopy.inactiveAnnouncement)
                headlineFocusToken += 1
            }
            return
        }
        inputOpensAt = OnboardingInputGate.opensAt(.opening, at: now, policy: policy)
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
        inputOpensAt = OnboardingInputGate.opensAt(.skip, at: now, policy: policy)
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
        copyVisibleAt = clock.now()
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
        noteFrontmostApp()
        syncMicCheck()
        syncPresentation()
    }

    /// macOS posts no "denied" for Accessibility, so the poll watches for the
    /// user leaving System Settings after Allow Typing.
    private func noteFrontmostApp() {
        guard typingAsked, !typingReturned else { return }
        if environment.frontmostBundleID() == Self.systemSettingsID {
            sawSettingsInFront = true
        } else if sawSettingsInFront {
            typingReturned = true
        }
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
        micRequest?.cancel()
        micRequest = nil
        stopMicCheck()
    }

    // MARK: Actions

    /// Whether a press counts now. VoiceOver, Voice Control and Switch Control
    /// press a button through its accessibility action, which never passes the
    /// panel's `sendEvent(_:)`, so every action checks the gate itself.
    private var inputIsOpen: Bool { isLive && !didFinish && clock.now() >= inputOpensAt }

    /// A button in the action row, pressed by a click, by Space under Full
    /// Keyboard Access, or through accessibility. Dropped before input opens.
    func perform(_ button: OnboardingButton) {
        guard inputIsOpen else { return }
        run(button)
    }

    /// A control pressed through its action. Close is exempt from the gate, as
    /// Command W is.
    func press(_ action: OnboardingAction) {
        if action == .close {
            dismiss()
            return
        }
        guard inputIsOpen else { return }
        run(action)
    }

    /// A key from the band's panel (or the stage's). The panel already dropped
    /// what its filter drops; the model applies the gate again so tests can
    /// drive it, and decides what the key does.
    func handleKey(_ key: OnboardingKey, isRepeat: Bool, at time: TimeInterval) {
        guard isLive, !didFinish else { return }
        if key == .closeWindow {
            dismiss()
            return
        }
        // The stage holds no ask: its first Return, Escape or Space skips it.
        if stageUp, !bandShown, openingSkip == nil {
            if !isRepeat, key == .returnKey || key == .escape || key == .space { skipOpening() }
            return
        }
        // Any key stops a moving-on wait, a repeat too, with no gate, and
        // presses nothing else.
        if case .badge(_, .movingOn) = currentRow {
            cancelWait(.interaction)
            return
        }
        guard OnboardingInputGate.allows(key, isRepeat: isRepeat, at: time, opensAt: inputOpensAt) else { return }
        let target = OnboardingReturnTarget.resolve(
            key, row: currentRow, focused: focusedAction, backEnabled: backEnabled, voiceOver: voiceOverOn)
        switch target {
        case .press(let action): run(action)
        case .cancelAutoAdvance: cancelWait(.interaction)
        case .nothing: break
        }
    }

    private func run(_ action: OnboardingAction) {
        switch action {
        case .main, .second:
            let buttons = currentRow.buttons
            let index = action == .main ? 0 : 1
            if buttons.indices.contains(index) { run(buttons[index]) }
        case .back:
            back()
        case .settings:
            onOpenSettings?()
        case .close:
            dismiss()
        }
    }

    private func run(_ button: OnboardingButton) {
        switch button {
        case .allowMicrophone:
            micRequest?.cancel()
            micRequest = Task { await grantMicrophone() }
        case .allowTyping:
            typingAsked = true
            grantAccessibility()
        case .startWithMac:
            enableLaunchAtLogin()
        case .openLoginItems:
            openLoginItemsSettings()
        case .openSystemSettings:
            switch bandState {
            case .ready(.typingOff), .ready(.loadingTypingOff), .typingStillOff:
                // The pane only: the system alert does not show again.
                permissions.openAccessibilitySettings()
            case .micStillSilent:
                permissions.openSoundSettings()
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
        // The prompt is attributed to the frontmost app, so come forward first.
        // Only a press that passed the gate gets here.
        environment.activate()
        _ = await permissions.requestMicrophone()
        requestingMic = false
        // The band may have closed while the prompt was up: then nothing comes forward.
        guard isLive, !Task.isCancelled else { return }
        // The system prompt takes focus; come back so the band is live again.
        environment.activate()
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
        backStep = nil
        backState = nil
        syncMicCheck()
        syncPresentation()
    }

    /// The previous beat, sliding the other way. A done beat shows its "after
    /// Back" state with Continue and no bloom. Back to a microphone beat whose
    /// voice was heard leaves the microphone off.
    func back() {
        guard isLive, !didFinish, backEnabled, let previous = step.previous else { return }
        step = previous
        backStep = previous
        backState = nil
        backState = baseState
        goingBack = true
        syncMicCheck()
        syncPresentation()
        goingBack = false
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
            willEnd?(kind)
            onComplete(kind)
            return
        }
        outroStartedAt = clock.now()
        after(Outro.end) { model in
            model.willEnd?(kind)
            model.onComplete(kind)
        }
    }

    /// The user closed the band early: ×, or Command W.
    func dismiss() {
        guard !didFinish else { return }
        didFinish = true
        willEnd?(nil)
        teardown()
        onDismiss()
    }

    // MARK: Events from the window and the view

    func panelKeyDidChange(_ isKey: Bool) {
        guard panelIsKey != isKey else { return }
        panelIsKey = isKey
    }

    /// Our app became active: the paused line clears (Continue stays), and a
    /// Typing ask counts as returned.
    func appDidBecomeActive() {
        appIsActive = true
        if typingAsked, !typingReturned { typingReturned = true }
        refresh()
    }

    /// A done step stops moving on while our app is not active, and shows Continue.
    func appDidResignActive() {
        appIsActive = false
        if case .badge(_, .movingOn) = currentRow { cancelWait(.appInactive) }
    }

    /// A click on the band that got through the gate.
    func noteClick() {
        guard isLive, typingAsked, !typingReturned else { return }
        typingReturned = true
        refresh()
    }

    /// The pointer, polled by the window. A report counts as a move only when
    /// the location differs from the last one, so a row swap under a still
    /// pointer cancels nothing.
    func notePointer(_ location: CGPoint, overBand: Bool) {
        let moved = lastPointer.map { $0 != location } ?? false
        lastPointer = location
        if pointerOverBand != overBand { pointerOverBand = overBand }
        if overBand, moved { noteInteraction() }
    }

    /// The view reports where keyboard focus is. A move the model made itself
    /// is not an interaction, nor is focus lost with its button.
    func focusDidChange(to action: OnboardingAction?) {
        guard focusedAction != action else { return }
        focusedAction = action
        guard let action else { return }
        if action == pendingFocusReport {
            pendingFocusReport = nil
            return
        }
        noteInteraction()
    }

    /// A capture key press that setup ignored: the top-bar line nudges for 4 s.
    func noteSwallowedPress() {
        guard isLive else { return }
        let at = clock.now()
        nudgeAt = at
        after(Self.nudgeDuration) { model in
            if model.nudgeAt == at { model.nudgeAt = nil }
        }
    }

    /// The window's poll re-reads Reduce Motion, VoiceOver, Low Power, the
    /// thermal state and Switch Control, and passes them on; only a change
    /// writes. A turn to the still version during the opening skips it, and a
    /// change mid-transition jumps to the rest frame.
    func updatePolicy(_ new: OnboardingMotionPolicy, switchControl: Bool) {
        let switchChanged = switchControl != switchControlOn
        if switchChanged { switchControlOn = switchControl }
        guard new != policy else {
            if switchChanged { syncPresentation() }
            return
        }
        let openingPlays = stageUp && !bandShown && openingSkip == nil
        policy = new
        guard isLive else { return }
        if openingPlays {
            if new.layers == .still { skipOpening() }
        } else {
            beatChange = nil
            rowChange = nil
            dip = nil
        }
        syncMicCheck()
        syncPresentation()
    }

    // MARK: Auto-advance

    /// A key press, a pointer move over the band, or a focus change the model
    /// did not make: a moving-on step stops and shows Continue.
    private func noteInteraction() {
        guard isLive, case .badge(_, .movingOn) = currentRow else { return }
        cancelWait(.interaction)
    }

    /// Final for the beat.
    private func cancelWait(_ cancel: OnboardingAutoAdvance.Cancel) {
        guard isLive, doneWait?.cancel == nil else { return }
        var wait = doneWait ?? OnboardingAutoAdvance(confirmedVisibleAt: nil, pointerOverBand: pointerOverBand)
        wait.cancel = cancel
        doneWait = wait
        waitRun += 1
        syncPresentation()
    }

    /// The timers the state on screen needs: the silence timer on the mic
    /// check's waiting copy, and the auto-advance on a done step. `visibleAt`
    /// is when the copy is fully visible; `restart` is the Heard swap.
    private func syncWaits(_ base: OnboardingState, visibleAt: TimeInterval, restart: Bool) {
        // A fixed clock is a still picture: it never waits.
        guard isLive, !introPlaying, !didFinish, !clock.isFixed else { return }

        switch base {
        case .micWaiting:
            if !silenceArmed {
                silenceArmed = true
                silenceRun += 1
                let run = silenceRun
                after(visibleAt + Self.silence - clock.now()) { model in
                    guard model.silenceRun == run, model.baseState == .micWaiting else { return }
                    model.micStillSilent = true
                    model.syncPresentation()
                }
            }
        case .micStillSilent:
            break
        default:
            if silenceArmed {
                silenceArmed = false
                silenceRun += 1
            }
        }

        guard base.withDoneRow(.movingOn) != nil, !waitsForTap(base) else {
            if base.withDoneRow(.movingOn) == nil { doneWait = nil }
            return
        }
        if var wait = doneWait {
            guard restart, wait.cancel == nil else { return }
            wait.restart(at: visibleAt)
            doneWait = wait
        } else {
            var wait = OnboardingAutoAdvance(confirmedVisibleAt: visibleAt, pointerOverBand: pointerOverBand)
            // Not active when the copy shows: Continue at once, and nothing advances.
            if !appIsActive { wait.cancel = .appInactive }
            doneWait = wait
        }
        scheduleAdvance()
    }

    private func scheduleAdvance() {
        waitRun += 1
        let run = waitRun
        guard let at = doneWait?.advancesAt else { return }
        after(at - clock.now()) { model in
            guard model.waitRun == run, model.doneWait?.advancesAt != nil, model.appIsActive, !model.didFinish,
                  case .badge(_, .movingOn) = model.currentRow
            else { return }
            model.advance()
        }
    }

    // MARK: Presentation

    /// Notes what the band now shows, and starts the frames for what changed: a
    /// dip when the orb's figure changes, a beat transition when the step
    /// changes, and a flourish when the row changes inside a beat. Ready's
    /// variant follows the download, so it changes in place.
    private func syncPresentation() {
        let base = baseState
        let figure = orbFigure
        guard isLive, let shown = shownState else {
            shownState = bandState
            shownFigure = figure
            return
        }
        let now = clock.now()
        let shownBase = shown.withDoneRow(.movingOn) ?? shown
        let stepChanged = base.step != shown.step
        if stepChanged {
            // Each beat has its own auto-advance and silence timer.
            doneWait = nil
            micStillSilent = false
            copyVisibleAt = OnboardingInputGate.opensAt(.step, at: now, policy: policy)
        } else if base != shownBase {
            copyVisibleAt = now + (policy.layers == .full ? Flourish.copySwap : 0)
        }
        let bothDone = base.withDoneRow(.movingOn) != nil && shownBase.withDoneRow(.movingOn) != nil
        syncWaits(base, visibleAt: max(copyVisibleAt, now), restart: !stepChanged && base != shownBase && bothDone)

        let state = bandState
        if figure != shownFigure {
            startDip(from: shownFigure, at: now)
            shownFigure = figure
        }
        guard state != shown else { return }
        shownState = state
        let copy = OnboardingCopy(canRetryEngine: onRetryEngine != nil)
        let old = copy.screen(shown)
        let new = copy.screen(state)
        // VoiceOver reads a new headline once, and the prompt-up swap again,
        // because its row is the news there.
        if new.headline != old.headline || (state == .micPromptUp && shown != .micPromptUp) {
            headlineFocusToken += 1
        }
        if stepChanged {
            beatChange = BeatChange(at: now, previous: shown, heldBloom: heldBloom, backward: goingBack)
            rowChange = nil
            heldBloom = nil
            inputOpensAt = max(inputOpensAt, OnboardingInputGate.opensAt(.step, at: now, policy: policy))
            focusOnBadgeRow(new.row)
            after(BeatTransition.duration(policy: policy)) { model in
                if model.beatChange?.at == now { model.beatChange = nil }
            }
            return
        }
        if case .ready = state {
            // Ready changes in place, but a new row still closes input for 300 ms:
            // a press meant for Try Again must not land on Allow Microphone.
            if new.row != old.row {
                inputOpensAt = max(inputOpensAt, OnboardingInputGate.opensAt(.row, at: now, policy: policy))
            }
            return
        }
        // A grant is a badge that was not there before. A cancel keeps its
        // badge, so it draws no ring and raises no bloom.
        let grant = Self.badgeText(new.row) != nil && Self.badgeText(new.row) != Self.badgeText(old.row)
        rowChange = RowChange(at: now, previous: shown, grant: grant)
        inputOpensAt = max(inputOpensAt, OnboardingInputGate.opensAt(.row, at: now, policy: policy))
        focusOnBadgeRow(new.row)
        // A live grant raises the bloom; the still version raises none.
        if grant, policy.layers == .full {
            heldBloom = OnboardingBloom.hue(for: state.step, heardVoice: heardVoice)
        }
        after(Flourish.duration) { model in
            if model.rowChange?.at == now { model.rowChange = nil }
        }
    }

    private static func badgeText(_ row: OnboardingRow) -> String? {
        if case .badge(let text, _) = row { return text }
        return nil
    }

    /// When Continue shows, focus moves to it. While a step moves on, nothing
    /// holds focus, and Return stops the wait.
    private func focusOnBadgeRow(_ row: OnboardingRow) {
        guard case .badge(_, let done) = row else { return }
        requestFocus(done == .movingOn ? nil : .main)
    }

    private func requestFocus(_ action: OnboardingAction?) {
        pendingFocusReport = action
        focusRequest = FocusRequest(action: action, serial: focusRequest.serial + 1)
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
        let sleep = environment.sleep
        Task { @MainActor [weak self] in
            if delay > 0 { await sleep(delay) }
            guard let self, self.flowGeneration == generation else { return }
            body(self)
        }
    }

    // MARK: Mic check

    /// The mic runs during the microphone beat only, and only once it's allowed
    /// — that beat is the one place the copy says we're listening. Never during
    /// the intro: the user has not been asked anything yet.
    ///
    /// Never under VoiceOver, whose speech the mic would hear; never again
    /// after a failure until Try Again; and not after Back to a beat whose
    /// voice was already heard.
    private func syncMicCheck() {
        let heardBeforeBack = heardVoice && backStep == .microphone
        if isLive, !introPlaying, step == .microphone, micGranted, !voiceOverOn, !micCheckFailed, !heardBeforeBack {
            startMicCheck()
        } else {
            stopMicCheck()
        }
    }

    /// Try Again on the microphone beat: start the mic check over.
    func retryMicCheck() {
        micCheckFailed = false
        stopMicCheck()
        syncMicCheck()
        syncPresentation()
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
            // No meter: the beat shows the failed copy, and Try Again starts
            // the check over. A mid-route-switch input is the usual cause.
            micCheckRunning = false
            micCheckFailed = true
            Log.app.error("Onboarding mic check failed to start: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func consume(level raw: Float) {
        guard isLive, micCheckRunning, !voiceOverOn else { return }
        level = envelope.step(target: raw)
        guard level > Self.voiceThreshold, !heardVoice else { return }
        heardVoice = true
        heardAt = clock.now()
        // This is what the microphone beat was waiting on: the Heard copy and
        // its wait start from here rather than at the next poll tick.
        syncPresentation()
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
        micCheckFailed: Bool = false,
        micStillSilent: Bool = false,
        typingStillOff: Bool = false,
        panelIsKey: Bool = true,
        focusedAction: OnboardingAction? = nil,
        clock: OnboardingClock = .fixed(0),
        engineStatus: @escaping @MainActor () -> EngineStatus = { .ready }
    ) -> NotchOnboardingModel {
        let model = NotchOnboardingModel(
            permissions: PermissionsManager(), clock: clock, engineStatus: engineStatus,
            showsAssistantLine: { showsAssistantLine }, onComplete: { _ in }, onDismiss: {})
        model.micCheckFailed = micCheckFailed
        model.micStillSilent = micStillSilent
        model.typingAsked = typingStillOff
        model.typingReturned = typingStillOff
        model.panelIsKey = panelIsKey
        model.appIsActive = true
        model.focusedAction = focusedAction
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

    /// Pins a reveal with no stage before it `t` seconds in.
    func pinReveal(at t: TimeInterval) {
        startReveal(at: clock.now() - t, gathers: true, afterStage: false)
    }

    /// Pins a change into this state from `previous`, `t` seconds in: a beat
    /// transition when the step differs, a flourish inside one beat. A badge on
    /// `previous` holds its bloom, as a live grant would have left it.
    func pinChange(
        from previous: OnboardingState, previousFigure: OrbFigure, at t: TimeInterval, backward: Bool = false
    ) {
        shownState = previous
        shownFigure = previousFigure
        if case .badge = OnboardingCopy().screen(previous).row {
            heldBloom = OnboardingBloom.hue(for: previous.step, heardVoice: heardVoice)
        }
        isLive = true
        goingBack = backward
        syncPresentation()
        goingBack = false
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

    /// Pins this beat as one the user came back to with Back.
    func pinBack() {
        backStep = step
        backState = nil
        backState = baseState
    }

    /// Pins the beat's auto-advance as cancelled, by a key or by the app not
    /// being active.
    func pinCancel(_ cancel: OnboardingAutoAdvance.Cancel, appActive: Bool) {
        doneWait = OnboardingAutoAdvance(confirmedVisibleAt: 0, pointerOverBand: true, cancel: cancel)
        appIsActive = appActive
    }

    /// Pins the top-bar nudge after an ignored capture key press.
    func pinNudge() {
        nudgeAt = clock.now()
    }
    #endif
}

private extension OnboardingState {
    /// The same done state with another row, or nil for a state that is not done.
    func withDoneRow(_ row: OnboardingDoneRow) -> OnboardingState? {
        switch self {
        case .micHeard: return .micHeard(row)
        case .micOn: return .micOn(row)
        case .typingGranted: return .typingGranted(row)
        case .loginOn: return .loginOn(row)
        default: return nil
        }
    }
}
