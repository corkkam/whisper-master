import XCTest

@testable import WhisperMaster

/// The cheap keyword gate + the model-JSON parser + the deterministic fallback
/// mapping — all pure, so they test without a model or audio.
final class VoiceCommandTests: XCTestCase {
    // MARK: - CommandDetector

    func testDetectsReminderTrigger() {
        let cmd = CommandDetector.detect("remind me to call mom")
        XCTAssertEqual(cmd?.kind, .reminder)
        XCTAssertEqual(cmd?.payload, "call mom")
    }

    func testDetectsNoteTrigger() {
        let cmd = CommandDetector.detect("add a note that buy milk and eggs")
        XCTAssertEqual(cmd?.kind, .note)
        XCTAssertEqual(cmd?.payload, "buy milk and eggs")
    }

    func testLongestTriggerWinsSoNoDanglingWord() {
        // "remind me to" must win over "remind me", leaving no leading "to".
        let cmd = CommandDetector.detect("remind me to go shopping")
        XCTAssertEqual(cmd?.kind, .reminder)
        XCTAssertEqual(cmd?.payload, "go shopping")
    }

    func testStripsLeadingConnector() {
        let cmd = CommandDetector.detect("make a note - buy milk")
        XCTAssertEqual(cmd?.kind, .note)
        XCTAssertEqual(cmd?.payload, "buy milk")
    }

    func testReminderCheckedBeforeNoteForAmbiguousPhrasing() {
        // "reminder to" is a reminder trigger; ensure it isn't swallowed as a note.
        let cmd = CommandDetector.detect("reminder to water the plants")
        XCTAssertEqual(cmd?.kind, .reminder)
    }

    func testOrdinaryDictationIsNotACommand() {
        XCTAssertNil(CommandDetector.detect("the meeting went really well today"))
        XCTAssertNil(CommandDetector.detect("what time is the standup tomorrow"))
        XCTAssertNil(CommandDetector.detect(""))
    }

    func testTriggerMustBeLeading() {
        // A trigger phrase mid-sentence is not a command.
        XCTAssertNil(CommandDetector.detect("i told her to remind me to call"))
    }

    // MARK: - IntentClassifier.parse

    func testParsesCleanJSON() {
        let raw = #"{"kind":"reminder","title":"Call mom","body":"","time":"tomorrow morning"}"#
        let intent = IntentClassifier.parse(raw)
        XCTAssertEqual(intent?.kind, .reminder)
        XCTAssertEqual(intent?.title, "Call mom")
        XCTAssertEqual(intent?.timePhrase, "tomorrow morning")
    }

    func testParsesJSONWrappedInProseAndFences() {
        let raw = "Sure, here you go:\n```json\n{\"kind\":\"note\",\"title\":\"Groceries\",\"body\":\"Buy milk.\",\"time\":null}\n```"
        let intent = IntentClassifier.parse(raw)
        XCTAssertEqual(intent?.kind, .note)
        XCTAssertEqual(intent?.title, "Groceries")
        XCTAssertEqual(intent?.body, "Buy milk.")
        XCTAssertNil(intent?.timePhrase)
    }

    func testTreatsNullAndNoneTimeAsNoTime() {
        for token in ["null", "none", "N/A", "", "  "] {
            let raw = "{\"kind\":\"reminder\",\"title\":\"X\",\"body\":\"\",\"time\":\"\(token)\"}"
            XCTAssertNil(IntentClassifier.parse(raw)?.timePhrase, "time '\(token)' should mean no time")
        }
    }

    func testRejectsMalformedOrMissingKind() {
        XCTAssertNil(IntentClassifier.parse("not json at all"))
        XCTAssertNil(IntentClassifier.parse(#"{"title":"X"}"#))
        XCTAssertNil(IntentClassifier.parse(#"{"kind":"banana","title":"X"}"#))
    }

    // MARK: - Deterministic fallback mapping

    func testDetectedNoteMapsToNoteIntent() {
        let intent = ClassifiedIntent(DetectedCommand(kind: .note, payload: "buy milk"))
        XCTAssertEqual(intent.kind, .note)
        XCTAssertEqual(intent.title, "")
        XCTAssertEqual(intent.body, "buy milk")
        XCTAssertNil(intent.timePhrase)
    }

    func testDetectedReminderMapsToReminderIntentWithNoTime() {
        let intent = ClassifiedIntent(DetectedCommand(kind: .reminder, payload: "go shopping"))
        XCTAssertEqual(intent.kind, .reminder)
        XCTAssertEqual(intent.title, "go shopping")
        XCTAssertNil(intent.timePhrase, "fallback never invents a time")
    }
}
