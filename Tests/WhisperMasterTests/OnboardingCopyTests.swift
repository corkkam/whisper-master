import AppKit
import XCTest

@testable import WhisperMaster

/// What onboarding says, and whether it fits the band, for every push-to-talk
/// key and both forms. A string that does not fit falls back to its shorter
/// form; a string with no fallback that fits is a failure, never a test to
/// loosen. The fit is a guard: the `WM_SNAPSHOT` render has the last word.
final class OnboardingCopyTests: XCTestCase {
    /// A headline or body: 380 pt less 5%.
    private static let textWidth: CGFloat = 361
    /// The action row: 412 pt less 5%.
    private static let rowWidth: CGFloat = 391
    private static let topBarWidth = NotchOnboardingLayout().topBarLineMaxWidth

    private let cases = OnboardingCopyCases.self

    override func setUp() {
        super.setUp()
        XCTAssertTrue(BrandFontsForTests.register(), "the brand fonts did not register")
        XCTAssertTrue(BrandFont.hasHeading)
        XCTAssertTrue(BrandFont.hasBody)
    }

    // MARK: Measurement

    private var headlineFont: NSFont { BrandFontsForTests.sans(19, .bold) }
    private var bodyFont: NSFont { BrandFontsForTests.sans(13) }
    /// `Typography.notchBody`: status lines, the top-bar line, the moving-on line.
    private var lineFont: NSFont { BrandFontsForTests.sans(13, .medium) }
    private var labelFont: NSFont { BrandFontsForTests.sans(14, .semibold) }

    private func width(_ text: String, _ font: NSFont) -> CGFloat { BrandFontsForTests.width(text, font) }

    /// The badge: a 16 pt check glyph, `Space.sm`, then its text.
    private func badgeWidth(_ text: String) -> CGFloat {
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        let glyph = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)?.size.width ?? 16
        return glyph + Theme.Space.sm + width(text, labelFont)
    }

    /// A band button: its label, the ladder's 18 pt sides and the band's 2 pt extra.
    private func buttonWidth(_ button: OnboardingButton) -> CGFloat {
        width(button.title, labelFont) + 2 * (18 + 2)
    }

    private static let badges = ["Heard you", "Microphone on", "Allowed", "Turned on"]

    /// Shows `text` if it fits, else its fallback. Prints which strings need
    /// their fallback, and fails when nothing fits.
    private func check(
        _ text: String, fallback: String?, limit: String, fits: (String) -> Bool, measure: (String) -> String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard !fits(text) else { return }
        guard let fallback else {
            XCTFail("Does not fit \(limit), no fallback: '\(text)' (\(measure(text)))", file: file, line: line)
            return
        }
        if fallback.isEmpty {
            print("FIT fallback (line drops) [\(limit)]: '\(text)' (\(measure(text)))")
            return
        }
        if fits(fallback) {
            print("FIT fallback [\(limit)]: '\(text)' (\(measure(text))) -> '\(fallback)' (\(measure(fallback)))")
        } else {
            XCTFail(
                "Does not fit \(limit), nor does its fallback: '\(text)' (\(measure(text))) -> '\(fallback)' (\(measure(fallback)))",
                file: file, line: line)
        }
    }

    // MARK: Fit

    func testHeadlinesFitOneLine() {
        for copy in cases.copies {
            for state in cases.states {
                let headline = copy.screen(state).headline
                check(
                    headline, fallback: nil, limit: "one line at 19 bold",
                    fits: { self.width($0, self.headlineFont) <= Self.textWidth },
                    measure: { "\(Int(self.width($0, self.headlineFont).rounded())) pt" })
            }
        }
    }

    func testBodiesFitTwoLines() {
        var seen = Set<String>()
        for copy in cases.copies {
            for state in cases.states {
                let screen = copy.screen(state)
                guard seen.insert(screen.body).inserted else { continue }
                check(
                    screen.body, fallback: screen.fallbackBody, limit: "two lines at 13",
                    fits: { BrandFontsForTests.lineCount($0, self.bodyFont, width: Self.textWidth) <= 2 },
                    measure: { "\(BrandFontsForTests.lineCount($0, self.bodyFont, width: Self.textWidth)) lines" })
            }
        }
    }

    func testTopBarLinesFit() {
        var seen = Set<String>()
        for copy in cases.copies {
            for context in cases.topBarContexts {
                guard let line = copy.topBarLine(context), seen.insert(line.text).inserted else { continue }
                check(
                    line.text, fallback: line.fallback, limit: "\(Int(Self.topBarWidth)) pt top bar",
                    fits: { self.width($0, self.lineFont) <= Self.topBarWidth },
                    measure: { "\(Int(self.width($0, self.lineFont).rounded())) pt" })
            }
        }
    }

    func testTheMovingOnLineFitsBesideTheWidestBadge() {
        let badge = Self.badges.map(badgeWidth).max()!
        let line = OnboardingCopy.movingOnLine
        check(
            line.text, fallback: line.fallback, limit: "\(Int(Self.rowWidth)) pt row beside the badge",
            fits: { badge + Theme.Space.sm + self.width($0, self.lineFont) <= Self.rowWidth },
            measure: { "\(Int((badge + Theme.Space.sm + self.width($0, self.lineFont)).rounded())) pt" })
    }

    func testThePausedLineFitsBesideTheWidestBadgeAndContinue() {
        let fixed = Self.badges.map(badgeWidth).max()! + 2 * Theme.Space.sm + buttonWidth(.continue)
        let line = OnboardingCopy.pausedLine
        check(
            line.text, fallback: line.fallback, limit: "\(Int(Self.rowWidth)) pt row beside badge and Continue",
            fits: { fixed + self.width($0, self.lineFont) <= Self.rowWidth },
            measure: { "\(Int((fixed + self.width($0, self.lineFont)).rounded())) pt" })
        // With the line dropped, the badge and Continue alone must fit.
        XCTAssertLessThanOrEqual(fixed - Theme.Space.sm, Self.rowWidth)
    }

    /// The measuring face is the 700 face, never the family's default.
    func testHeadlinesAreMeasuredInTheBoldFace() {
        XCTAssertEqual(headlineFont.fontName, BrandFontsForTests.postScriptName(ofFile: "InstrumentSans-700.ttf"))
        XCTAssertEqual(bodyFont.fontName, BrandFontsForTests.postScriptName(ofFile: "InstrumentSans-400.ttf"))
        XCTAssertEqual(BrandFontsForTests.fontFiles.count, 8)
    }

    // MARK: Every state

    func testEveryStateHasAHeadlineABodyAndAButtonOrBadge() {
        let copy = OnboardingCopy()
        for state in cases.states {
            let screen = copy.screen(state)
            XCTAssertFalse(screen.headline.isEmpty, "\(state)")
            XCTAssertFalse(screen.body.isEmpty, "\(state)")
            switch screen.row {
            case .badge(let badge, _): XCTAssertFalse(badge.isEmpty, "\(state)")
            default: XCTAssertFalse(screen.row.buttons.isEmpty, "\(state)")
            }
        }
    }

    func testEveryBeatHasADeniedOrFailedState() {
        let copy = OnboardingCopy()
        for state: OnboardingState in [.micDenied, .micFailed, .typingStillOff, .loginFailed, .ready(.failed), .ready(.micDenied)] {
            XCTAssertFalse(copy.screen(state).row.buttons.isEmpty, "\(state)")
        }
        let beats = Set([OnboardingState.micFailed, .typingStillOff, .loginFailed, .ready(.failed)].map(\.step))
        XCTAssertEqual(beats, Set(NotchOnboardingStep.allCases))
    }

    func testThePercentIsAlwaysFilled() {
        for copy in cases.copies {
            for (source, text) in OnboardingCopyCases.allStrings(copy) {
                XCTAssertFalse(text.contains("{") || text.contains("}"), "\(source): \(text)")
            }
        }
        let screen = OnboardingCopy().screen(.ready(.downloading(percent: 42)))
        XCTAssertTrue(screen.body.contains("(42%)"))
        XCTAssertTrue(screen.fallbackBody?.contains("(42%)") == true)
    }

    // MARK: The key placeholder

    func testKeyNamesForEveryKey() {
        XCTAssertEqual(OnboardingCopy.key(.fn, form: .name), "the fn key")
        XCTAssertEqual(
            OnboardingCopy.key(.fn, form: .first),
            "the fn key (the key with a globe symbol), at the bottom left of most Mac keyboards")
        XCTAssertEqual(OnboardingCopy.key(.fn, form: .firstWithoutLocation), "the fn key (the key with a globe symbol)")
        XCTAssertEqual(OnboardingCopy.key(.fn, form: .cap), "The fn key")
        XCTAssertEqual(OnboardingCopy.key(.rightOption, form: .first), "the right Option key, to the right of the space bar")
        XCTAssertEqual(OnboardingCopy.key(.leftOption, form: .first), "the left Option key, to the left of the space bar")
        XCTAssertEqual(OnboardingCopy.key(.rightCommand, form: .first), "the right Command key, just right of the space bar")
        XCTAssertEqual(OnboardingCopy.key(.rightCommand, form: .firstWithoutLocation), "the right Command key")
        XCTAssertEqual(OnboardingCopy.key(.leftOption, form: .cap), "The left Option key")
    }

    /// Every key name renders from the chosen key, and "fn" appears only in
    /// the chord line and the fn key's own names.
    func testEveryKeyNameComesFromTheChosenKey() {
        for copy in cases.copies {
            let own = [OnboardingKeyForm.first, .firstWithoutLocation, .name, .cap].map {
                OnboardingCopy.key(copy.key, form: $0)
            }
            let others = HotkeyManager.HotkeyOption.allCases.filter { $0 != copy.key }.map {
                OnboardingCopy.key($0, form: .name)
            }
            for (source, text) in OnboardingCopyCases.allStrings(copy) {
                let withoutChord = text.replacingOccurrences(of: OnboardingCopy.chordLine, with: "")
                var rest = withoutChord
                for name in own { rest = rest.replacingOccurrences(of: name, with: "") }
                XCTAssertFalse(rest.contains("fn"), "\(copy.key) \(source): \(text)")
                for other in others {
                    XCTAssertFalse(withoutChord.lowercased().contains(other.lowercased()), "\(copy.key) \(source): \(text)")
                }
            }
        }
    }

    func testTheMicrophoneAskNamesWhereTheKeyIs() {
        for copy in cases.copies {
            let screen = copy.screen(.micAsk)
            XCTAssertTrue(screen.body.contains(OnboardingCopy.key(copy.key, form: .first)), screen.body)
            XCTAssertTrue(
                screen.fallbackBody?.contains(OnboardingCopy.key(copy.key, form: .firstWithoutLocation)) == true)
        }
    }

    func testTheChordIsFnAndControl() {
        XCTAssertEqual(
            ModifierChord.command.masks,
            [NSEvent.ModifierFlags.function.rawValue, NSEvent.ModifierFlags.control.rawValue])
    }

    // MARK: Labels

    func testEverySkipSaysNotNow() {
        for copy in cases.copies {
            for (source, text) in OnboardingCopyCases.allStrings(copy) {
                for banned in ["Skip the test", "Skip for now", "My Mac", "Finish in Settings", "where your cursor is"] {
                    XCTAssertFalse(text.contains(banned), "\(source): \(text)")
                }
            }
        }
        let copy = OnboardingCopy()
        for state in cases.states where state.step != .ready {
            let buttons = copy.screen(state).row.buttons
            if buttons.count == 2 { XCTAssertEqual(buttons.last, .notNow, "\(state)") }
        }
    }

    func testAccessibilityIsNamedOnceInQuotes() {
        for copy in cases.copies {
            let hits = OnboardingCopyCases.allStrings(copy).map(\.text).filter { $0.contains("Accessibility") }
            XCTAssertEqual(Set(hits).count, 1, "\(hits)")
            XCTAssertTrue(hits.allSatisfy { $0.contains("\"Accessibility\"") })
        }
        XCTAssertEqual(NotchOnboardingStep.accessibility.title, "Typing")
    }

    /// The Typing ask says what skipping does. Its fallback drops that, and the
    /// Ready typing-off variants still say it.
    func testSkippingTypingIsExplained() {
        let copy = OnboardingCopy()
        XCTAssertTrue(copy.screen(.typingAsk).body.contains("If you skip, I copy your words."))
        for variant: ReadyVariant in [.typingOff, .loadingTypingOff] {
            let screen = copy.screen(.ready(variant))
            XCTAssertTrue(screen.body.contains("copy your words"), "\(variant)")
            XCTAssertTrue((screen.fallbackBody ?? screen.body).contains("copy your words"), "\(variant)")
        }
    }

    // MARK: Ready

    func testReadyVariantTable() {
        func resolve(_ engine: EngineStatus, _ mic: ReadyMicStatus, typing: Bool, assistant: Bool = false) -> ReadyVariant {
            ReadyVariant.resolve(engine: engine, mic: mic, typingOn: typing, showsAssistantLine: assistant)
        }
        for mic in [ReadyMicStatus.notAsked, .denied, .on] {
            for typing in [false, true] { XCTAssertEqual(resolve(.failed, mic, typing: typing), .failed) }
        }
        for engine in [EngineStatus.downloading(percent: 3), .preparing] {
            XCTAssertEqual(resolve(engine, .notAsked, typing: true), .loadingMicNotAsked)
            XCTAssertEqual(resolve(engine, .denied, typing: false), .loadingMicDenied)
            XCTAssertEqual(resolve(engine, .on, typing: false), .loadingTypingOff)
        }
        XCTAssertEqual(resolve(.downloading(percent: 3), .on, typing: true), .downloading(percent: 3))
        XCTAssertEqual(resolve(.preparing, .on, typing: true), .preparing)
        XCTAssertEqual(resolve(.ready, .notAsked, typing: true), .micNotAsked)
        XCTAssertEqual(resolve(.ready, .denied, typing: true), .micDenied)
        XCTAssertEqual(resolve(.ready, .on, typing: false), .typingOff)
        XCTAssertEqual(resolve(.ready, .on, typing: true), .ready(assistantLine: false))
        XCTAssertEqual(resolve(.ready, .on, typing: true, assistant: true), .ready(assistantLine: true))
    }

    func testOnlyAReadyEngineWithTheMicOnSaysYoureReady() {
        let engines: [EngineStatus] = [.ready, .downloading(percent: 50), .preparing, .failed]
        for copy in cases.copies {
            for engine in engines {
                for mic in [ReadyMicStatus.notAsked, .denied, .on] {
                    for typing in [false, true] {
                        let variant = ReadyVariant.resolve(engine: engine, mic: mic, typingOn: typing, showsAssistantLine: true)
                        let screen = copy.screen(.ready(variant))
                        let says = (screen.headline + screen.body + (screen.fallbackBody ?? "")).contains("You're ready")
                        XCTAssertEqual(says, engine == .ready && mic == .on, "\(engine) \(mic) \(typing)")
                    }
                }
            }
        }
    }

    func testOneThingLeftForEachMicStatusOnAReadyEngine() {
        let copy = OnboardingCopy()
        let notAsked = copy.screen(.ready(.resolve(engine: .ready, mic: .notAsked, typingOn: true, showsAssistantLine: false)))
        XCTAssertEqual(notAsked.headline, "One thing left: your microphone.")
        XCTAssertEqual(notAsked.row, .buttons([.allowMicrophone, .done]))
        let denied = copy.screen(.ready(.resolve(engine: .ready, mic: .denied, typingOn: true, showsAssistantLine: false)))
        XCTAssertEqual(denied.headline, "Your microphone is still off.")
        XCTAssertEqual(denied.row, .buttons([.openSystemSettings, .done]))
        let on = copy.screen(.ready(.resolve(engine: .ready, mic: .on, typingOn: true, showsAssistantLine: false)))
        XCTAssertEqual(on.headline, "You're ready. Try it now.")
    }

    func testEveryLoadingVariantSaysYouCanTalkOnceImReady() {
        let copy = OnboardingCopy()
        for variant: ReadyVariant in [.downloading(percent: 1), .preparing, .loadingTypingOff, .loadingMicNotAsked, .loadingMicDenied] {
            XCTAssertEqual(copy.screen(.ready(variant)).headline, "You can talk once I'm ready.")
        }
    }

    func testEveryReadyVariantEndsWithDone() {
        for copy in cases.copies {
            for variant in cases.readyVariants {
                XCTAssertEqual(copy.screen(.ready(variant)).row.buttons.last, .done, "\(variant)")
            }
        }
    }

    func testFailedDoesNotMentionSettings() {
        let screen = OnboardingCopy().screen(.ready(.failed))
        XCTAssertFalse(screen.body.contains("Settings"))
        XCTAssertFalse(screen.fallbackBody?.contains("Settings") == true)
        XCTAssertEqual(screen.row, .buttons([.tryAgain, .done]))
    }

    /// With no engine retry wired, Failed offers Done alone and never names Try Again.
    func testFailedWithoutARetryOffersDoneAlone() {
        let screen = OnboardingCopy(canRetryEngine: false).screen(.ready(.failed))
        XCTAssertEqual(screen.row, .buttons([.done]))
        for text in [screen.body, screen.fallbackBody ?? ""] {
            XCTAssertFalse(text.contains("Try Again"))
            XCTAssertFalse(text.contains("Settings"))
        }
        XCTAssertTrue(screen.body.contains("Press Done"))
    }

    func testTheReadyVariantsStartWithWhereToClick() {
        for copy in cases.copies {
            for variant: ReadyVariant in [.ready(assistantLine: true), .ready(assistantLine: false)] {
                let screen = copy.screen(.ready(variant))
                XCTAssertTrue(screen.body.hasPrefix("Click where you want to type."))
                XCTAssertTrue(screen.fallbackBody?.hasPrefix("Click where you want to type.") == true)
            }
        }
    }

    func testTheAssistantLineNeedsShowsAssistantLine() {
        let copy = OnboardingCopy()
        XCTAssertTrue(copy.screen(.ready(.ready(assistantLine: true))).body.contains(OnboardingCopy.chordLine))
        for variant in cases.readyVariants where variant != .ready(assistantLine: true) {
            XCTAssertFalse(copy.screen(.ready(variant)).body.contains("ask about your day"), "\(variant)")
        }
    }

    func testTypingOffSaysToHoldTheKeyAndTalk() {
        let screen = OnboardingCopy(key: .rightOption).screen(.ready(.typingOff))
        XCTAssertTrue(screen.body.hasPrefix("Hold the right Option key and talk."))
        XCTAssertTrue(screen.fallbackBody?.hasPrefix("Hold the right Option key and talk.") == true)
    }

    func testLoadingSaysWhatTheKeyDoesEarlyAndThatTheWorkKeepsGoing() {
        for copy in cases.copies {
            let verb = copy.holdToTalk ? "Holding" : "Pressing"
            for variant: ReadyVariant in [.downloading(percent: 9), .preparing] {
                let screen = copy.screen(.ready(variant))
                for text in [screen.body, screen.fallbackBody ?? ""] {
                    XCTAssertTrue(text.contains("\(verb) \(OnboardingCopy.key(copy.key, form: .name)) early"), text)
                    XCTAssertTrue(text.contains("keeps going"), text)
                }
            }
        }
    }

    // MARK: Press form

    func testThePressFormNeverSaysHold() {
        for copy in cases.copies where !copy.holdToTalk {
            for (source, text) in OnboardingCopyCases.allStrings(copy) {
                let rest = text.replacingOccurrences(of: OnboardingCopy.chordLine, with: "")
                XCTAssertFalse(rest.lowercased().contains("hold"), "\(copy.key) \(source): \(text)")
            }
            // The chord is held whatever the push-to-talk setting is.
            XCTAssertTrue(copy.screen(.ready(.ready(assistantLine: true))).body.contains("hold the fn key and Control"))
        }
    }

    // MARK: Lines and hints

    func testTopBarRules() {
        let copy = OnboardingCopy(key: .leftOption)
        let ready = OnboardingTopBarContext(step: .ready, readyVariant: .ready(assistantLine: false))
        XCTAssertEqual(copy.topBarLine(ready)?.text, "Now hold the left Option key and talk.")
        XCTAssertNil(copy.topBarLine(OnboardingTopBarContext(step: .ready, readyVariant: .failed)))
        XCTAssertNil(copy.topBarLine(OnboardingTopBarContext(step: .ready, readyVariant: .typingOff, panelIsKey: true)))
        XCTAssertEqual(
            OnboardingCopy(key: .leftOption, holdToTalk: false).topBarLine(ready)?.text,
            "Press the left Option key and talk.")

        let beat2 = OnboardingTopBarContext(step: .accessibility)
        XCTAssertEqual(copy.topBarLine(beat2)?.text, "Click here to use the keyboard.")
        var nudge = beat2
        nudge.nudging = true
        XCTAssertEqual(copy.topBarLine(nudge), OnboardingLine(
            "Finish setup first, or click here to use the keyboard.", fallback: "Finish setup first."))
        nudge.micCheckListening = true
        XCTAssertEqual(copy.topBarLine(nudge)?.text, "Click here to use the keyboard.")

        var paused = beat2
        paused.pausedWhileInactive = true
        XCTAssertEqual(copy.topBarLine(paused)?.text, "Switch back to Whisper Master to go on.")
    }

    func testTheReadyMicNudgeFollowsTheMicStatusAlsoWhileLoading() {
        let copy = OnboardingCopy()
        for variant: ReadyVariant in [.micNotAsked, .loadingMicNotAsked] {
            let context = OnboardingTopBarContext(step: .ready, readyVariant: variant, readyMic: .notAsked, nudging: true)
            XCTAssertEqual(copy.topBarLine(context)?.text, "Allow the microphone first.")
        }
        for variant: ReadyVariant in [.micDenied, .loadingMicDenied] {
            let context = OnboardingTopBarContext(step: .ready, readyVariant: variant, readyMic: .denied, nudging: true)
            XCTAssertEqual(copy.topBarLine(context)?.text, "Turn on the microphone first.")
        }
    }

    func testNoClickHereOnReadyAndEachMicNudgeOnlyInItsState() {
        for copy in cases.copies {
            for context in cases.topBarContexts {
                guard let line = copy.topBarLine(context)?.text else { continue }
                if context.step == .ready { XCTAssertFalse(line.contains("Click here"), line) }
                if line == "Turn on the microphone first." { XCTAssertEqual(context.readyMic, .denied) }
                if line == "Allow the microphone first." { XCTAssertEqual(context.readyMic, .notAsked) }
            }
        }
    }

    /// Lines name no key the band does not answer yet.
    func testNoLineOrHintNamesAKeyTheBandDoesNotAnswerYet() {
        for copy in cases.copies {
            for (source, text) in OnboardingCopyCases.allStrings(copy) {
                for key in ["Return", "Escape", "Left Arrow", "Command W", "⌘W", "←"] {
                    XCTAssertFalse(text.contains(key), "\(source): \(text)")
                }
            }
        }
    }

    func testTheDoneHintInvitesTheKeyOnlyWhenReady() {
        for copy in cases.copies {
            let verb = copy.holdToTalk ? "hold" : "press"
            let keyName = OnboardingCopy.key(copy.key, form: .name)
            for variant in cases.readyVariants {
                let hint = copy.hint(for: .done, in: .ready(variant)) ?? ""
                XCTAssertEqual(hint.contains("\(verb) \(keyName)"), variant.invitesHold, "\(variant): \(hint)")
                XCTAssertTrue(hint.hasPrefix("Closes setup."))
            }
        }
    }

    func testStillSilentKeepsTheSettingsSentenceFirst() {
        for copy in cases.copies {
            let screen = copy.screen(.micStillSilent)
            let keyLine = copy.holdToTalk ? "Hold \(OnboardingCopy.key(copy.key, form: .name))" : "Press \(OnboardingCopy.key(copy.key, form: .name))"
            for text in [screen.body, screen.fallbackBody ?? ""] {
                XCTAssertTrue(text.hasPrefix("Check"), text)
                XCTAssertTrue(text.contains("System Settings"), text)
                XCTAssertTrue(text.hasSuffix("\(keyLine) \(copy.holdToTalk ? "while" : "before") you speak."), text)
            }
        }
    }

    func testThePausedLineSaysWhatContinueDoes() {
        XCTAssertEqual(OnboardingCopy.pausedLine.text, "Continue goes to the next step.")
    }

    func testNoStateBothMovesOnAndShowsContinue() {
        let copy = OnboardingCopy()
        for state in cases.states {
            let row = copy.screen(state).row
            if case .badge(_, .movingOn) = row { XCTAssertFalse(row.buttons.contains(.continue), "\(state)") }
        }
    }

    func testHeardYouOnlyWhenAVoiceWasHeard() {
        let copy = OnboardingCopy()
        for state in cases.states {
            guard case .badge(let badge, _) = copy.screen(state).row, badge == "Heard you" else { continue }
            guard case .micHeard = state else { return XCTFail("\(state) says Heard you") }
        }
    }

    func testLoginFailedNeverEchoesTheRawError() {
        XCTAssertEqual(OnboardingCopy().screen(.loginFailed).body, "You can turn it on later in Settings.")
    }

    func testNoStringHasASemicolon() {
        for copy in cases.copies {
            for (source, text) in OnboardingCopyCases.allStrings(copy) {
                XCTAssertFalse(text.contains(";"), "\(source): \(text)")
            }
        }
    }

    // MARK: VoiceOver strings

    func testStepProgressValue() {
        XCTAssertEqual(
            OnboardingCopy.stepProgressValue(current: .openAtLogin, micOn: true, typingOn: false, loginOn: false),
            "Step 3 of 4, Start with your Mac. Microphone done, Typing skipped.")
        XCTAssertEqual(
            OnboardingCopy.stepProgressValue(current: .microphone, micOn: false, typingOn: false, loginOn: false),
            "Step 1 of 4, Microphone.")
        XCTAssertEqual(OnboardingCopy.bandLabel(.accessibility), "Setup, step 2 of 4: Typing")
    }

    /// One predicate: a microphone that is on, whose voice test was skipped, is done.
    func testAMicThatIsOnIsDoneEvenWhenItsTestWasSkipped() {
        XCTAssertTrue(OnboardingCopy.stepIsDone(.microphone, micOn: true, typingOn: false, loginOn: false))
        XCTAssertFalse(OnboardingCopy.stepIsDone(.accessibility, micOn: true, typingOn: false, loginOn: true))
    }

    func testTheFirstAnnouncementCarriesThePrivacyLine() {
        XCTAssertTrue(OnboardingCopy.firstAnnouncement.contains("Your voice stays on this Mac."))
        XCTAssertTrue(OnboardingCopy.inactiveAnnouncement.contains("Switch to Whisper Master"))
    }

    func testReadyNotice() {
        XCTAssertEqual(OnboardingCopy(key: .rightCommand).readyNotice(typingOn: true), "I'm ready. Hold the right Command key and talk.")
        XCTAssertEqual(
            OnboardingCopy(key: .rightCommand, holdToTalk: false).readyNotice(typingOn: true),
            "I'm ready. Press the right Command key and talk.")
        XCTAssertEqual(OnboardingCopy().readyNotice(typingOn: false), "I'm ready. Typing is off, so I'll copy your words.")
    }
}
