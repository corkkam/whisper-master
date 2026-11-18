import XCTest

@testable import WhisperMaster

/// The pure decisions behind onboarding's input: what a dictation key does while
/// setup is open, what a finish does, when a done step moves on, and when Typing
/// reads "still off".
final class OnboardingInputTests: XCTestCase {
    // MARK: Capture decision

    func testNoWindowAllows() {
        for step in NotchOnboardingStep.allCases {
            XCTAssertEqual(OnboardingCaptureDecision.resolve(onboardingOpen: false, step: step, micGranted: false), .allow)
        }
    }

    func testBeatsOneToThreeIgnore() {
        for step in [NotchOnboardingStep.microphone, .accessibility, .openAtLogin] {
            for mic in [false, true] {
                XCTAssertEqual(OnboardingCaptureDecision.resolve(onboardingOpen: true, step: step, micGranted: mic), .ignore)
            }
        }
    }

    /// The engine state is not an input: a hold while the speech files load still
    /// hands off, and the pill shows the progress.
    func testReadyWithTheMicOnHandsOffWhateverTheEngine() {
        XCTAssertEqual(OnboardingCaptureDecision.resolve(onboardingOpen: true, step: .ready, micGranted: true), .handOffThenAllow)
    }

    func testReadyWithTheMicOffIgnores() {
        XCTAssertEqual(OnboardingCaptureDecision.resolve(onboardingOpen: true, step: .ready, micGranted: false), .ignore)
    }

    func testApplyIgnoreResetsAndNudgesOnceAndDoesNotRecord() {
        var resets = 0, nudges = 0, handOffs = 0
        let records = OnboardingCaptureDecision.apply(
            .ignore, micCheckListening: false,
            resetGesture: { resets += 1 }, noteSwallowedPress: { nudges += 1 }, handOff: { handOffs += 1 })
        XCTAssertFalse(records)
        XCTAssertEqual([resets, nudges, handOffs], [1, 1, 0])
    }

    func testApplyIgnoreDoesNotNudgeWhileTheMicCheckListens() {
        var resets = 0, nudges = 0
        let records = OnboardingCaptureDecision.apply(
            .ignore, micCheckListening: true,
            resetGesture: { resets += 1 }, noteSwallowedPress: { nudges += 1 }, handOff: {})
        XCTAssertFalse(records)
        XCTAssertEqual([resets, nudges], [1, 0])
    }

    func testApplyHandOffCallsHandOffAndRecords() {
        var resets = 0, nudges = 0, handOffs = 0
        let records = OnboardingCaptureDecision.apply(
            .handOffThenAllow, micCheckListening: false,
            resetGesture: { resets += 1 }, noteSwallowedPress: { nudges += 1 }, handOff: { handOffs += 1 })
        XCTAssertTrue(records)
        XCTAssertEqual([resets, nudges, handOffs], [0, 0, 1])
    }

    func testApplyAllowRecordsAndTouchesNothing() {
        var calls = 0
        let records = OnboardingCaptureDecision.apply(
            .allow, micCheckListening: false,
            resetGesture: { calls += 1 }, noteSwallowedPress: { calls += 1 }, handOff: { calls += 1 })
        XCTAssertTrue(records)
        XCTAssertEqual(calls, 0)
    }

    // MARK: Capture flow through the real gesture recogniser

    /// Feeds one key event through the gesture, then through `apply`, the way the
    /// hotkey handler will. Returns the signal only if the caller would record.
    private func press(
        _ gesture: inout HotkeyGesture, at time: TimeInterval, step: NotchOnboardingStep, resets: Bool
    ) -> (signal: HotkeyGesture.Signal?, decision: OnboardingCaptureDecision?) {
        guard let signal = gesture.press(now: time) else { return (nil, nil) }
        // `.start` and `.handsFree` are gated; `.stop` never is.
        guard signal != .stop else { return (signal, nil) }
        let decision = OnboardingCaptureDecision.resolve(onboardingOpen: true, step: step, micGranted: true)
        var reset = false
        _ = OnboardingCaptureDecision.apply(
            decision, micCheckListening: false,
            resetGesture: { reset = true }, noteSwallowedPress: {}, handOff: {})
        if reset && resets { gesture.reset() }
        return (signal, decision)
    }

    private func doubleTapOnTypingThenHoldOnReady(resets: Bool) -> (HotkeyGesture.Signal?, OnboardingCaptureDecision?) {
        var gesture = HotkeyGesture()
        _ = press(&gesture, at: 0, step: .accessibility, resets: resets)
        _ = gesture.release(now: 0.1)
        _ = press(&gesture, at: 0.3, step: .accessibility, resets: resets)
        _ = gesture.release(now: 0.4)
        _ = gesture.flush(now: 1.5)
        return press(&gesture, at: 2, step: .ready, resets: resets)
    }

    func testADoubleTapOnTypingThenAHoldOnReadyStartsAndHandsOff() {
        let (signal, decision) = doubleTapOnTypingThenHoldOnReady(resets: true)
        XCTAssertEqual(signal, .start)
        XCTAssertEqual(decision, .handOffThenAllow)
    }

    /// Without the reset the double-tap latches hands-free, and the hold on Ready
    /// ends that latch instead of starting a recording.
    func testWithoutTheResetTheHoldOnReadyDoesNotStart() {
        let (signal, decision) = doubleTapOnTypingThenHoldOnReady(resets: false)
        XCTAssertNotEqual(signal, .start)
        XCTAssertNil(decision)
    }

    // MARK: Finish plan

    func testDoneHandsBackWithoutSettings() {
        XCTAssertEqual(
            OnboardingFinishPlan.plan(for: .handBack, signOutInFlight: false),
            OnboardingFinishPlan(opensSettings: false, handsFocusBack: true))
    }

    func testCloseAndOpenSettingsOpensSettingsAndKeepsFocus() {
        XCTAssertEqual(
            OnboardingFinishPlan.plan(for: .openSettings, signOutInFlight: false),
            OnboardingFinishPlan(opensSettings: true, handsFocusBack: false))
    }

    func testNoSettingsWindowWhileASignOutIsInFlight() {
        XCTAssertFalse(OnboardingFinishPlan.plan(for: .openSettings, signOutInFlight: true).opensSettings)
        XCTAssertFalse(OnboardingFinishPlan.plan(for: .handBack, signOutInFlight: true).opensSettings)
    }

    // MARK: Auto-advance

    func testAdvancesAfterTheFloorWithThePointerOverTheBand() {
        let wait = OnboardingAutoAdvance(confirmedVisibleAt: 10, pointerOverBand: true)
        XCTAssertEqual(wait.advancesAt, 12.5)
    }

    func testWaitsLongerWithThePointerAway() {
        let wait = OnboardingAutoAdvance(confirmedVisibleAt: 10, pointerOverBand: false)
        XCTAssertEqual(wait.advancesAt, 14.5)
    }

    func testAnyCancelIsFinal() {
        for cancel in [OnboardingAutoAdvance.Cancel.interaction, .appInactive] {
            var wait = OnboardingAutoAdvance(confirmedVisibleAt: 10, pointerOverBand: true, cancel: cancel)
            XCTAssertNil(wait.advancesAt)
            wait.restart(at: 20)
            XCTAssertNil(wait.advancesAt)
        }
    }

    func testNothingAdvancesBeforeTheConfirmedCopyShows() {
        XCTAssertNil(OnboardingAutoAdvance(confirmedVisibleAt: nil, pointerOverBand: true).advancesAt)
    }

    func testTheHeardSwapRestartsTheWait() {
        var wait = OnboardingAutoAdvance(confirmedVisibleAt: 10, pointerOverBand: true)
        wait.restart(at: 11.2)
        XCTAssertEqual(wait.advancesAt, 13.7)
    }

    // MARK: Typing status

    func testTypingStatusFourCases() {
        XCTAssertEqual(TypingStatus.resolve(trusted: true, asked: true, returned: true), .granted)
        XCTAssertEqual(TypingStatus.resolve(trusted: false, asked: false, returned: true), .ask)
        XCTAssertEqual(TypingStatus.resolve(trusted: false, asked: true, returned: false), .ask)
        XCTAssertEqual(TypingStatus.resolve(trusted: false, asked: true, returned: true), .stillOff)
    }
}
