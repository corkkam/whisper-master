import XCTest

@testable import WhisperMaster

/// The keyboard, focus and auto-advance rules of the model, driven through fake
/// seams: no TCC, no audio, no window. The clock is moved by hand, and every
/// delayed task runs `speed` times faster than the real one.
@MainActor
final class NotchOnboardingKeyModelTests: XCTestCase {
    private let full = OnboardingMotionPolicy.resolve(reduceMotion: false, lowPower: false, thermal: .nominal, voiceOver: false)
    private let voiceOver = OnboardingMotionPolicy.resolve(reduceMotion: false, lowPower: false, thermal: .nominal, voiceOver: true)
    private static let speed = 200.0

    private lazy var permissions = FakePermissions()
    private let capture = FakeCapture()
    private lazy var system = FakeEnvironment(speed: Self.speed)
    private var now: TimeInterval = 1_000
    private var finishes: [OnboardingFinish] = []
    private var dismissals = 0
    private var engine: EngineStatus = .ready

    private func makeModel() -> NotchOnboardingModel {
        NotchOnboardingModel(
            permissions: permissions,
            capture: capture,
            clock: OnboardingClock(now: { [unowned self] in self.now }, isFixed: false),
            engineStatus: { [unowned self] in self.engine },
            onComplete: { [unowned self] in self.finishes.append($0) },
            onDismiss: { [unowned self] in self.dismissals += 1 },
            onRetryEngine: {},
            environment: system.environment)
    }

    /// A replay with input open and the band holding the keyboard.
    private func makeLiveModel(policy: OnboardingMotionPolicy? = nil) -> NotchOnboardingModel {
        let model = makeModel()
        model.begin(.reveal, policy: policy ?? full)
        model.introDidEnd()
        model.panelKeyDidChange(true)
        now = model.inputOpensAt
        return model
    }

    /// Lets the model's delayed tasks run: `seconds` of model time.
    private func elapse(_ seconds: TimeInterval) async {
        try? await Task.sleep(for: .seconds(seconds / Self.speed + 0.05))
    }

    /// Lets a task the model spawned (the microphone request) start.
    private func settle() async {
        try? await Task.sleep(for: .seconds(0.05))
    }

    private func press(_ model: NotchOnboardingModel, _ key: OnboardingKey, isRepeat: Bool = false) {
        model.handleKey(key, isRepeat: isRepeat, at: now)
    }

    /// Moves to Typing and lets its 500 ms input gate pass.
    private func goToTyping(_ model: NotchOnboardingModel) {
        model.advance()
        now = model.inputOpensAt
    }

    // MARK: The input gate

    func testEarlyKeysAndPressesNeverRequestTheMicrophone() async {
        let model = makeModel()
        model.begin(.stage, policy: full)
        // The first Return at T0 skips the stage; the next two land in the skip's gate.
        press(model, .returnKey)
        XCTAssertNotNil(model.openingSkip)
        press(model, .returnKey)
        press(model, .returnKey)
        await elapse(1)
        XCTAssertEqual(permissions.micRequests, 0)

        // Just before input opens: a key, a press through accessibility, and a held Return.
        now = model.inputOpensAt - 0.001
        press(model, .returnKey)
        model.perform(.allowMicrophone)
        model.press(.main)
        now = model.inputOpensAt + 1
        press(model, .returnKey, isRepeat: true)
        await settle()
        XCTAssertEqual(permissions.micRequests, 0)

        // Once input is open, Return presses the main button.
        press(model, .returnKey)
        await settle()
        XCTAssertEqual(permissions.micRequests, 1)
    }

    func testReturnOneMillisecondAfterTheSwapRequestsNothing() async {
        let model = makeModel()
        model.begin(.stage, policy: full)
        let start = now
        await elapse(OpeningTimeline.swapAt)
        now = start + OpeningTimeline.swapAt + 0.001
        press(model, .returnKey)
        await settle()
        XCTAssertEqual(permissions.micRequests, 0)
        XCTAssertEqual(model.inputOpensAt, start + OpeningTimeline.end, accuracy: 0.0001)
    }

    func testEscapeInTheGateAfterASkipDoesNotSkipBeatOne() {
        let model = makeModel()
        model.begin(.stage, policy: full)
        press(model, .escape)
        now += 0.1
        press(model, .escape)
        XCTAssertEqual(model.step, .microphone)
        XCTAssertEqual(model.inputOpensAt, 1_000 + 0.79, accuracy: 0.0001)
    }

    func testCommandWClosesEvenBeforeInputOpens() {
        let model = makeModel()
        model.begin(.reveal, policy: full)
        press(model, .closeWindow)
        XCTAssertEqual(dismissals, 1)
    }

    // MARK: The key map

    func testFocusOnNotNowPlusReturnSkipsAndRequestsNothing() async {
        let model = makeLiveModel()
        model.focusDidChange(to: .second)
        press(model, .returnKey)
        await settle()
        XCTAssertEqual(model.step, .accessibility)
        XCTAssertEqual(permissions.micRequests, 0)
    }

    func testSpacePressesTheFocusedButton() {
        let model = makeLiveModel()
        press(model, .space)
        XCTAssertEqual(model.step, .microphone, "Space with no focus does nothing")
        model.focusDidChange(to: .second)
        press(model, .space)
        XCTAssertEqual(model.step, .accessibility)
    }

    func testEscapePressesNotNowAndLeftArrowGoesBack() {
        let model = makeLiveModel()
        press(model, .escape)
        XCTAssertEqual(model.step, .accessibility)
        now = model.inputOpensAt
        press(model, .leftArrow)
        XCTAssertEqual(model.step, .microphone)
    }

    func testUnderVoiceOverReturnWithNoFocusDoesNothing() {
        let model = makeLiveModel(policy: voiceOver)
        permissions.mic = .denied
        model.refresh()
        press(model, .returnKey)
        XCTAssertEqual(permissions.microphonePaneOpens, 0)
        XCTAssertEqual(model.step, .microphone)
    }

    // MARK: Top-bar line

    private func topBar(_ model: NotchOnboardingModel) -> String? {
        OnboardingCopy().topBarLine(model.topBarContext)?.text
    }

    func testAnIgnoredPressNudgesForFourSeconds() async {
        let model = makeLiveModel()
        goToTyping(model)
        model.noteSwallowedPress()
        XCTAssertEqual(topBar(model), "Finish setup, or close it with Command W.")
        model.panelKeyDidChange(false)
        XCTAssertEqual(topBar(model), "Finish setup first, or click here to use the keyboard.")
        await elapse(NotchOnboardingModel.nudgeDuration)
        XCTAssertEqual(topBar(model), "Click here to use the keyboard.")
    }

    func testNoNudgeWhileTheMicCheckListens() {
        permissions.mic = .granted
        let model = makeLiveModel()
        XCTAssertTrue(model.micCheckRunning)
        model.noteSwallowedPress()
        XCTAssertNil(topBar(model))
    }

    func testTheReadyMicNudgeFollowsTheMicStatus() {
        let model = makeLiveModel()
        for _ in 0..<3 { model.advance() }
        model.noteSwallowedPress()
        XCTAssertEqual(topBar(model), "Allow the microphone first.")
        permissions.mic = .denied
        model.refresh()
        XCTAssertEqual(topBar(model), "Turn on the microphone first.")
    }

    func testReadyWithTheKeyboardSaysCommandWCloses() {
        permissions.mic = .granted
        permissions.trusted = true
        let model = makeLiveModel()
        for _ in 0..<3 { model.advance() }
        XCTAssertEqual(topBar(model), "Command W closes setup.")
        model.panelKeyDidChange(false)
        XCTAssertEqual(topBar(model), "Now hold the fn key and talk.")
    }

    func testTheMovingOnLineNamesEscapeOnlyWithTheKeyboard() {
        XCTAssertTrue(OnboardingCopy.movingOnLine(panelIsKey: true).text.contains("Press Escape to stay"))
        XCTAssertFalse(OnboardingCopy.movingOnLine(panelIsKey: false).text.contains("Escape"))
        XCTAssertFalse(OnboardingCopy.movingOnLine(panelIsKey: false).fallback?.contains("Escape") ?? true)
    }

    // MARK: Our app not active

    func testAGrantWhileNotActiveShowsContinueAndTheSwitchBackLineAndNeverAdvances() async {
        let model = makeLiveModel()
        goToTyping(model)
        system.active = false
        model.appDidResignActive()
        permissions.trusted = true
        model.refresh()
        XCTAssertEqual(model.bandState, .typingGranted(.paused))
        XCTAssertEqual(topBar(model), "Switch back to Whisper Master to go on.")
        await elapse(OnboardingAutoAdvance.floorWithoutPointer + 1)
        XCTAssertEqual(model.step, .accessibility)

        system.active = true
        model.appDidBecomeActive()
        XCTAssertNotEqual(topBar(model), "Switch back to Whisper Master to go on.")
        XCTAssertTrue(model.currentRow.buttons.contains(.continue))
        await elapse(OnboardingAutoAdvance.floorWithoutPointer + 1)
        XCTAssertEqual(model.step, .accessibility)
    }

    func testResigningActiveInAWaitPausesIt() async {
        let model = makeLiveModel()
        goToTyping(model)
        permissions.trusted = true
        model.refresh()
        XCTAssertEqual(model.bandState, .typingGranted(.movingOn))
        system.active = false
        model.appDidResignActive()
        XCTAssertEqual(model.bandState, .typingGranted(.paused))
        await elapse(OnboardingAutoAdvance.floorWithoutPointer + 1)
        XCTAssertEqual(model.step, .accessibility)
    }

    // MARK: Auto-advance

    func testADoneStepAdvancesOnceAtTheFloor() async {
        let model = makeLiveModel()
        model.notePointer(CGPoint(x: 10, y: 10), overBand: true)
        goToTyping(model)
        permissions.trusted = true
        model.refresh()
        // The floor counts from the confirmed copy fully visible, 200 ms after the swap.
        XCTAssertEqual(model.doneWait?.confirmedVisibleAt, now + Flourish.copySwap)
        XCTAssertEqual(model.doneWait?.advancesAt, now + Flourish.copySwap + OnboardingAutoAdvance.floor)
        XCTAssertEqual(model.step, .accessibility)
        await elapse(OnboardingAutoAdvance.floor)
        XCTAssertEqual(model.step, .openAtLogin)
        await elapse(OnboardingAutoAdvance.floorWithoutPointer + 1)
        XCTAssertEqual(model.step, .openAtLogin, "it advances once")
    }

    func testTheFloorIsLongerWithThePointerAway() {
        let model = makeLiveModel()
        goToTyping(model)
        permissions.trusted = true
        model.refresh()
        XCTAssertEqual(model.doneWait?.advancesAt, now + Flourish.copySwap + OnboardingAutoAdvance.floorWithoutPointer)
    }

    private func movingOnModel() -> NotchOnboardingModel {
        let model = makeLiveModel()
        goToTyping(model)
        permissions.trusted = true
        model.refresh()
        return model
    }

    func testAKeyCancelsForGoodAndReturnDoesNotPressContinue() async {
        let model = movingOnModel()
        press(model, .returnKey)
        XCTAssertEqual(model.bandState, .typingGranted(.waits))
        XCTAssertEqual(model.step, .accessibility)
        // The cancel's row change closes input for 300 ms.
        press(model, .returnKey)
        XCTAssertEqual(model.step, .accessibility)
        await elapse(OnboardingAutoAdvance.floorWithoutPointer + 1)
        XCTAssertEqual(model.step, .accessibility)
        // Continue got focus, and that report is not an interaction.
        XCTAssertEqual(model.focusRequest.action, .main)
        now = model.inputOpensAt
        press(model, .returnKey)
        XCTAssertEqual(model.step, .openAtLogin)
    }

    func testARepeatStillCancelsTheWait() {
        let model = movingOnModel()
        press(model, .other, isRepeat: true)
        XCTAssertEqual(model.bandState, .typingGranted(.waits))
    }

    func testAPointerMoveCancelsButASamePointReportDoesNot() {
        let model = movingOnModel()
        model.notePointer(CGPoint(x: 5, y: 5), overBand: true)
        model.notePointer(CGPoint(x: 5, y: 5), overBand: true)
        XCTAssertEqual(model.bandState, .typingGranted(.movingOn))
        model.notePointer(CGPoint(x: 6, y: 5), overBand: true)
        XCTAssertEqual(model.bandState, .typingGranted(.waits))
    }

    func testAPointerMoveAwayFromTheBandDoesNotCancel() {
        let model = movingOnModel()
        model.notePointer(CGPoint(x: 5, y: 5), overBand: false)
        model.notePointer(CGPoint(x: 900, y: 5), overBand: false)
        XCTAssertEqual(model.bandState, .typingGranted(.movingOn))
    }

    func testAUserFocusChangeCancelsButTheModelsOwnDoesNot() {
        let model = movingOnModel()
        // The model moved focus off the vanished button; its report is not a move.
        model.focusDidChange(to: model.focusRequest.action)
        XCTAssertEqual(model.bandState, .typingGranted(.movingOn))
        model.focusDidChange(to: .back)
        XCTAssertEqual(model.bandState, .typingGranted(.waits))
    }

    func testTheHeardSwapRestartsTheWait() async {
        // Real-speed waits, so the restarted wait cannot run out while the voice lands.
        system = FakeEnvironment()
        permissions.mic = .granted
        let model = makeLiveModel()
        XCTAssertEqual(model.bandState, .micOn(.movingOn))
        let first = model.doneWait?.confirmedVisibleAt
        now += 1
        capture.levelHandler?(0.5)
        await settle()
        XCTAssertEqual(model.bandState, .micHeard(.movingOn))
        XCTAssertEqual(model.heldBloom, .voice)
        let restarted = model.doneWait?.confirmedVisibleAt
        XCTAssertNotNil(first)
        XCTAssertGreaterThan(restarted ?? 0, first ?? .infinity)
    }

    // MARK: Back

    func testBackDoesNotAdvanceAndShowsContinue() async {
        let model = movingOnModel()
        await elapse(OnboardingAutoAdvance.floorWithoutPointer + 1)
        XCTAssertEqual(model.step, .openAtLogin)
        now = model.inputOpensAt
        model.press(.back)
        XCTAssertEqual(model.step, .accessibility)
        XCTAssertEqual(model.beatChange?.backward, true)
        XCTAssertEqual(model.bandState, .typingGranted(.waits))
        XCTAssertNil(model.heldBloom, "no bloom after Back")
        await elapse(OnboardingAutoAdvance.floorWithoutPointer + 1)
        XCTAssertEqual(model.step, .accessibility)
    }

    func testBackToAHeardMicrophoneStartsNoMicCheck() async {
        system = FakeEnvironment()
        permissions.mic = .granted
        let model = makeLiveModel()
        capture.levelHandler?(0.5)
        await settle()
        XCTAssertTrue(model.heardVoice)
        goToTyping(model)
        let starts = capture.starts
        XCTAssertFalse(model.micCheckRunning)
        model.back()
        XCTAssertEqual(model.bandState, .micHeard(.waits))
        XCTAssertEqual(capture.starts, starts)
        XCTAssertFalse(model.micCheckRunning)
    }

    func testBackIsDisabledWhileAPromptIsUp() async {
        permissions.holdsRequest = true
        let model = makeLiveModel()
        for _ in 0..<3 { model.advance() }
        now = model.inputOpensAt
        model.perform(.allowMicrophone)
        await settle()
        XCTAssertTrue(model.requestingMic)
        XCTAssertFalse(model.backEnabled)
        model.back()
        XCTAssertEqual(model.step, .ready)
        permissions.answerRequest(false)
        await settle()
    }

    // MARK: The microphone beat

    /// Allowed in this flow, not on entry: the waiting copy.
    private func waitingModel() -> NotchOnboardingModel {
        let model = makeLiveModel()
        permissions.mic = .granted
        model.refresh()
        return model
    }

    func testEightSecondsOfSilenceGiveStillSilentThenAVoiceGivesHeard() async {
        let model = waitingModel()
        XCTAssertEqual(model.bandState, .micWaiting)
        await elapse(NotchOnboardingModel.silence)
        XCTAssertEqual(model.bandState, .micStillSilent)
        XCTAssertEqual(model.currentRow.buttons, [.openSystemSettings, .notNow])
        now = model.inputOpensAt
        model.perform(.openSystemSettings)
        XCTAssertEqual(permissions.soundPaneOpens, 1)
        // System Settings came front, so the Heard step pauses rather than moving on.
        system.active = false
        model.appDidResignActive()
        capture.levelHandler?(0.5)
        await settle()
        XCTAssertEqual(model.bandState, .micHeard(.paused))
    }

    func testNotNowInPromptUpSkips() async {
        permissions.holdsRequest = true
        let model = makeLiveModel()
        model.perform(.allowMicrophone)
        await settle()
        XCTAssertEqual(model.bandState, .micPromptUp)
        now = model.inputOpensAt
        press(model, .escape)
        XCTAssertEqual(model.step, .accessibility)
        permissions.answerRequest(true)
        await settle()
    }

    func testAMicCheckThatCannotStartShowsFailedAndTryAgainRetries() {
        capture.fails = true
        let model = waitingModel()
        XCTAssertEqual(model.bandState, .micFailed)
        XCTAssertEqual(model.orbFigure, .thinking)
        model.refresh()
        XCTAssertEqual(capture.starts, 1, "a failed check waits for Try Again")
        capture.fails = false
        now = model.inputOpensAt
        model.perform(.tryAgain)
        XCTAssertEqual(capture.starts, 2)
        XCTAssertTrue(model.micCheckRunning)
    }

    // MARK: Typing

    func testAllowTypingThenDenyShowsStillOffAfterSystemSettingsLeavesTheFront() {
        let model = makeLiveModel()
        goToTyping(model)
        model.perform(.allowTyping)
        XCTAssertEqual(permissions.accessibilityPrompts, 1)
        XCTAssertEqual(permissions.accessibilityPaneOpens, 1)
        // The pane comes front; the band does not change.
        system.front = "com.apple.systempreferences"
        model.refresh()
        XCTAssertEqual(model.bandState, .typingAsk)
        system.front = "com.apple.TextEdit"
        model.refresh()
        XCTAssertEqual(model.bandState, .typingStillOff)
        now = model.inputOpensAt
        model.perform(.openSystemSettings)
        XCTAssertEqual(permissions.accessibilityPaneOpens, 2)
        XCTAssertEqual(permissions.accessibilityPrompts, 1, "no second prompt")
    }

    func testTypingReturnedIsWrittenOnlyFromFalseToTrue() {
        let model = makeLiveModel()
        goToTyping(model)
        model.perform(.allowTyping)
        XCTAssertFalse(model.typingReturned)
        model.noteClick()
        XCTAssertTrue(model.typingReturned)
        system.front = "com.apple.systempreferences"
        model.refresh()
        model.appDidBecomeActive()
        XCTAssertTrue(model.typingReturned)
    }

    // MARK: VoiceOver and Switch Control

    func testUnderVoiceOverNoMicCheckNoLatchNoBloomAndNoAutoAdvance() async {
        permissions.mic = .granted
        let model = makeLiveModel(policy: voiceOver)
        XCTAssertEqual(system.announcements, [OnboardingCopy.firstAnnouncement])
        XCTAssertEqual(capture.starts, 0)
        XCTAssertEqual(model.bandState, .micOnVoiceOver)
        XCTAssertEqual(model.currentRow.buttons, [.continue])
        goToTyping(model)
        permissions.trusted = true
        model.refresh()
        XCTAssertEqual(model.bandState, .typingGranted(.waits))
        XCTAssertNil(model.heldBloom)
        await elapse(OnboardingAutoAdvance.floorWithoutPointer + 1)
        XCTAssertEqual(model.step, .accessibility)
    }

    func testTheInactiveAnnouncementUnderVoiceOver() {
        system.active = false
        _ = makeLiveModel(policy: voiceOver)
        XCTAssertEqual(system.announcements, [OnboardingCopy.inactiveAnnouncement])
    }

    func testVoiceOverTurningOnStopsARunningCheck() {
        permissions.mic = .granted
        let model = makeLiveModel()
        XCTAssertTrue(model.micCheckRunning)
        model.updatePolicy(voiceOver, switchControl: false)
        XCTAssertFalse(model.micCheckRunning)
        XCTAssertEqual(model.bandState, .micOnVoiceOver)
    }

    func testUnderSwitchControlNoAutoAdvance() async {
        let model = makeLiveModel()
        model.updatePolicy(full, switchControl: true)
        goToTyping(model)
        permissions.trusted = true
        model.refresh()
        XCTAssertEqual(model.bandState, .typingGranted(.waits))
        await elapse(OnboardingAutoAdvance.floorWithoutPointer + 1)
        XCTAssertEqual(model.step, .accessibility)
    }

    // MARK: Focus

    func testTheHeadlineTokenGoesUpPerHeadlineChangeAndAtThePromptUpSwap() async {
        permissions.holdsRequest = true
        let model = makeLiveModel()
        XCTAssertEqual(model.headlineFocusToken, 0)
        model.refresh()
        XCTAssertEqual(model.headlineFocusToken, 0)
        model.perform(.allowMicrophone)
        await settle()
        XCTAssertEqual(model.bandState, .micPromptUp)
        XCTAssertEqual(model.headlineFocusToken, 1, "the prompt-up swap keeps its headline but is read again")
        permissions.answerRequest(false)
        await settle()
        goToTyping(model)
        XCTAssertEqual(model.headlineFocusToken, 2)
        permissions.trusted = true
        model.refresh()
        XCTAssertEqual(model.headlineFocusToken, 3)
        // A cancel changes the row only.
        press(model, .other)
        XCTAssertEqual(model.bandState, .typingGranted(.waits))
        XCTAssertEqual(model.headlineFocusToken, 3)
    }

    // MARK: Ready

    /// Ready changes in place, but a new row still closes input for 300 ms: a
    /// press meant for Try Again must not land on Allow Microphone.
    func testANewReadyRowClosesInputFor300Milliseconds() {
        engine = .failed
        let model = makeLiveModel()
        for _ in 0..<3 { model.advance() }
        now = model.inputOpensAt + 1
        XCTAssertEqual(model.currentRow.buttons, [.tryAgain, .done])
        engine = .downloading(percent: 10)
        model.refresh()
        XCTAssertEqual(model.bandState, .ready(.loadingMicNotAsked))
        XCTAssertEqual(model.currentRow.buttons, [.allowMicrophone, .done])
        XCTAssertEqual(model.inputOpensAt, now + Flourish.opensAt, accuracy: 1e-9)
        press(model, .returnKey)
        model.perform(.allowMicrophone)
        XCTAssertEqual(permissions.micRequests, 0)
        // The download's percent moves the copy, not the row: input stays open.
        permissions.mic = .granted
        permissions.trusted = true
        model.refresh()
        XCTAssertEqual(model.bandState, .ready(.downloading(percent: 10)))
        now = model.inputOpensAt + 1
        let opens = model.inputOpensAt
        engine = .downloading(percent: 20)
        model.refresh()
        XCTAssertEqual(model.bandState, .ready(.downloading(percent: 20)))
        XCTAssertEqual(model.inputOpensAt, opens)
    }

    /// A capture key press ignored while the speech files load says why.
    func testAnIgnoredPressWhileLoadingSaysYouCanTalkOnceImReady() {
        permissions.mic = .granted
        permissions.trusted = true
        engine = .preparing
        let model = makeLiveModel()
        for _ in 0..<3 { model.advance() }
        XCTAssertEqual(model.bandState, .ready(.preparing))
        model.noteSwallowedPress()
        XCTAssertEqual(topBar(model), OnboardingCopy.loadingHeadline)
    }

    // MARK: Microphone request

    /// The band closed while the system prompt was up: the answer brings nothing forward.
    func testAMicAnswerAfterTeardownDoesNotBringTheAppForward() async {
        permissions.holdsRequest = true
        let model = makeLiveModel()
        model.perform(.allowMicrophone)
        await settle()
        XCTAssertEqual(system.activations, 1, "it came forward for the prompt")
        model.teardown()
        permissions.answerRequest(true)
        await settle()
        XCTAssertEqual(system.activations, 1)
        XCTAssertFalse(model.requestingMic)
    }

    func testTheLiveClockIsSystemUptime() {
        XCTAssertEqual(OnboardingClock.live.now(), ProcessInfo.processInfo.systemUptime, accuracy: 0.1)
    }
}
