import AppKit
import XCTest

@testable import WhisperMaster

/// The pure decisions behind onboarding's input: what a dictation key does while
/// setup is open, what a finish does, when a done step moves on, and when Typing
/// reads "still off".
final class OnboardingInputTests: XCTestCase {
    // MARK: Capture decision

    private func decide(
        open: Bool = true, _ step: NotchOnboardingStep, mic: Bool = true, engineReady: Bool = true
    ) -> OnboardingCaptureDecision {
        OnboardingCaptureDecision.resolve(onboardingOpen: open, step: step, micGranted: mic, engineReady: engineReady)
    }

    func testNoWindowAllows() {
        for step in NotchOnboardingStep.allCases {
            XCTAssertEqual(decide(open: false, step, mic: false, engineReady: false), .allow)
        }
    }

    func testBeatsOneToThreeIgnore() {
        for step in [NotchOnboardingStep.microphone, .accessibility, .openAtLogin] {
            for mic in [false, true] {
                XCTAssertEqual(decide(step, mic: mic), .ignore)
            }
        }
    }

    func testReadyWithTheMicOnAndTheEngineReadyHandsOff() {
        XCTAssertEqual(decide(.ready), .handOffThenAllow)
    }

    /// While the speech files load (or after they failed) the recording would be
    /// refused, so a hand-off would close setup and record nothing. Setup stays.
    func testReadyWithTheEngineNotReadyIgnores() {
        XCTAssertEqual(decide(.ready, engineReady: false), .ignore)
    }

    func testReadyWithTheMicOffIgnores() {
        XCTAssertEqual(decide(.ready, mic: false), .ignore)
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
        let decision = decide(step)
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

    // MARK: Input gate

    private let full = OnboardingMotionPolicy.resolve(reduceMotion: false, lowPower: false, thermal: .nominal, voiceOver: false)
    private let still = OnboardingMotionPolicy.resolve(reduceMotion: true, lowPower: false, thermal: .nominal, voiceOver: false)

    func testInputOpensAtEachCause() {
        let gate = OnboardingInputGate.self
        XCTAssertEqual(gate.opensAt(.opening, at: 0, policy: full), 4.1, accuracy: 1e-9)
        XCTAssertEqual(gate.opensAt(.skip, at: 1.24, policy: full), 1.24 + 0.79, accuracy: 1e-9)
        XCTAssertEqual(gate.opensAt(.replay, at: 0, policy: full), 0.54, accuracy: 1e-9)
        XCTAssertEqual(gate.opensAt(.step, at: 10, policy: full), 10.5, accuracy: 1e-9)
        XCTAssertEqual(gate.opensAt(.row, at: 10, policy: full), 10.3, accuracy: 1e-9)
        // Still: 300 ms after the band appears, and after a step change.
        XCTAssertEqual(gate.opensAt(.replay, at: 0, policy: still), 0.3, accuracy: 1e-9)
        XCTAssertEqual(gate.opensAt(.opening, at: 0, policy: still), OpeningTimeline.stillSwapAt + 0.3, accuracy: 1e-9)
        XCTAssertEqual(gate.opensAt(.step, at: 10, policy: still), 10.3, accuracy: 1e-9)
    }

    func testRepeatsAndEarlyKeysAreRefusedAndCommandWAlwaysPasses() {
        let gate = OnboardingInputGate.self
        XCTAssertFalse(gate.allows(.returnKey, isRepeat: false, at: 0.999, opensAt: 1))
        XCTAssertTrue(gate.allows(.returnKey, isRepeat: false, at: 1, opensAt: 1))
        XCTAssertFalse(gate.allows(.returnKey, isRepeat: true, at: 5, opensAt: 1))
        XCTAssertTrue(gate.allows(.closeWindow, isRepeat: false, at: 0, opensAt: 1))
        XCTAssertTrue(gate.allows(.closeWindow, isRepeat: true, at: 0, opensAt: .infinity))
    }

    // MARK: Key map

    private func target(
        _ key: OnboardingKey, _ row: OnboardingRow, focused: OnboardingAction? = nil, back: Bool = true,
        voiceOver: Bool = false
    ) -> OnboardingKeyAction {
        OnboardingReturnTarget.resolve(key, row: row, focused: focused, backEnabled: back, voiceOver: voiceOver)
    }

    private let ask = OnboardingRow.buttons([.allowTyping, .notNow])

    func testReturn() {
        XCTAssertEqual(target(.returnKey, ask, focused: .second), .press(.second))
        XCTAssertEqual(target(.returnKey, ask), .press(.main))
        XCTAssertEqual(target(.returnKey, .badge("Allowed", .movingOn)), .cancelAutoAdvance)
        XCTAssertEqual(target(.returnKey, .buttons([.done]), focused: .second), .nothing, "not in this state")
        XCTAssertEqual(target(.returnKey, ask, focused: .back, back: false), .nothing)
        XCTAssertEqual(target(.returnKey, ask, voiceOver: true), .nothing)
        XCTAssertEqual(target(.returnKey, ask, focused: .main, voiceOver: true), .press(.main))
        XCTAssertEqual(target(.returnKey, ask, focused: .settings), .press(.settings))
    }

    func testEscape() {
        for state in OnboardingCopyCases.states {
            let row = OnboardingCopy().screen(state).row
            let got = target(.escape, row)
            switch row {
            case .badge(_, .movingOn):
                XCTAssertEqual(got, .cancelAutoAdvance, "\(state)")
            case .badge:
                XCTAssertEqual(got, .nothing, "\(state): only Continue")
            case .waiting:
                XCTAssertEqual(got, .press(.main), "\(state): the sole Not now")
            case .buttons(let buttons):
                if buttons.count == 2 {
                    XCTAssertEqual(got, .press(.second), "\(state)")
                    XCTAssertTrue(buttons[1] == .notNow || buttons[1] == .done, "\(state)")
                } else {
                    XCTAssertEqual(got, buttons == [.notNow] || buttons == [.done] ? .press(.main) : .nothing, "\(state)")
                }
            }
        }
        // Done in every Ready variant.
        for variant in OnboardingCopyCases.readyVariants {
            for retry in [true, false] {
                let row = OnboardingCopy(canRetryEngine: retry).screen(.ready(variant)).row
                guard case .press(let action) = target(.escape, row) else { return XCTFail("\(variant)") }
                XCTAssertEqual(row.buttons[action == .main ? 0 : 1], .done, "\(variant)")
            }
        }
    }

    func testSpaceAndLeftArrow() {
        XCTAssertEqual(target(.space, ask, focused: .second), .press(.second))
        XCTAssertEqual(target(.space, ask), .nothing)
        XCTAssertEqual(target(.leftArrow, ask), .press(.back))
        XCTAssertEqual(target(.leftArrow, ask, back: false), .nothing)
        XCTAssertEqual(target(.closeWindow, .badge("Allowed", .movingOn)), .press(.close))
        XCTAssertEqual(target(.passThrough, ask), .nothing)
        XCTAssertEqual(target(.other, .badge("Allowed", .movingOn)), .cancelAutoAdvance)
    }

    func testKeyCodes() {
        func key(_ code: UInt16, _ mods: NSEvent.ModifierFlags = [], chars: String? = nil, fka: Bool = false) -> OnboardingKey {
            OnboardingKey(keyCode: code, characters: chars, modifiers: mods, fullKeyboardAccess: fka)
        }
        XCTAssertEqual(key(36), .returnKey)
        XCTAssertEqual(key(76), .returnKey)
        XCTAssertEqual(key(53), .escape)
        XCTAssertEqual(key(123, [.function, .numericPad]), .leftArrow)
        XCTAssertEqual(key(49), .space)
        XCTAssertEqual(key(49, fka: true), .passThrough)
        XCTAssertEqual(key(48), .passThrough)
        XCTAssertEqual(key(48, .shift), .passThrough)
        XCTAssertEqual(key(13, .command, chars: "w"), .closeWindow)
        XCTAssertEqual(key(13, chars: "w"), .other)
        XCTAssertEqual(key(13, [.command, .shift], chars: "W"), .other)
        XCTAssertEqual(key(0), .other)
    }

    /// Command W follows the layout, not the key code: on AZERTY, W sits on
    /// key 6 and key 13 types Z.
    func testCommandWFollowsTheKeyboardLayout() {
        func key(_ code: UInt16, _ chars: String) -> OnboardingKey {
            OnboardingKey(keyCode: code, characters: chars, modifiers: .command, fullKeyboardAccess: false)
        }
        XCTAssertEqual(key(6, "w"), .closeWindow)
        XCTAssertEqual(key(13, "z"), .other)
    }

    // MARK: Typing status

    func testTypingStatusFourCases() {
        XCTAssertEqual(TypingStatus.resolve(trusted: true, asked: true, returned: true), .granted)
        XCTAssertEqual(TypingStatus.resolve(trusted: false, asked: false, returned: true), .ask)
        XCTAssertEqual(TypingStatus.resolve(trusted: false, asked: true, returned: false), .ask)
        XCTAssertEqual(TypingStatus.resolve(trusted: false, asked: true, returned: true), .stillOff)
    }
}
