import XCTest

@testable import WhisperMaster

/// The label is the *spoken* handle for a connection, so this is the test that keeps
/// "what's on my work calendar" pointed at the right account. Pure — no store, no
/// EventKit, no model.
@MainActor
final class ConnectorLabelMatcherTests: XCTestCase {
    private func instance(_ label: String, kind: ConnectorKind = .googleCalendar) -> ConnectorInstance {
        ConnectorInstance(kind: kind, label: label, identity: "x@y.com",
                          config: .calendars(identifiers: ["c"], sourceTitle: "Google"))
    }

    private var workAndPersonal: [ConnectorInstance] {
        [instance("Work"), instance("Personal")]
    }

    // MARK: - Naming an instance

    func testMatchesASpokenLabel() {
        let hit = ConnectorLabelMatcher.match("what's on my work calendar", in: workAndPersonal)
        XCTAssertEqual(hit?.label, "Work")
    }

    func testMatchesRegardlessOfCaseAndPunctuation() {
        XCTAssertEqual(
            ConnectorLabelMatcher.match("What's on my PERSONAL calendar?", in: workAndPersonal)?.label,
            "Personal")
    }

    func testMatchesALabelThatCarriesTheKindName() {
        // The kind's own words are stripped from the label, so "Google Calendar Work"
        // still reduces to the distinctive "work".
        let instances = [instance("Google Calendar Work"), instance("Google Calendar Personal")]
        XCTAssertEqual(
            ConnectorLabelMatcher.match("what's on my work calendar", in: instances)?.label,
            "Google Calendar Work")
    }

    func testMatchesAMultiWordLabelOnItsStrongerOverlap() {
        let instances = [instance("Work Main"), instance("Work Side")]
        XCTAssertEqual(
            ConnectorLabelMatcher.match("what's on my work side calendar", in: instances)?.label,
            "Work Side")
    }

    // MARK: - Refusing to guess

    /// The central behaviour: an unqualified question names nothing, so the caller
    /// merges every calendar instead of silently answering from one.
    func testUnqualifiedQuestionNamesNothing() {
        XCTAssertNil(ConnectorLabelMatcher.match("what's my day", in: workAndPersonal))
        XCTAssertNil(ConnectorLabelMatcher.match("what's on my calendar", in: workAndPersonal))
        XCTAssertNil(ConnectorLabelMatcher.match("what do i have today", in: workAndPersonal))
    }

    /// A label made only of connector vocabulary has nothing distinctive left, so it
    /// can never be matched by name — correct, because the user never gave it one.
    /// This is the migrated instance's shape.
    func testAnInstanceLabelledOnlyWithItsKindIsNeverNamed() {
        let instances = [instance("Google Calendar")]
        XCTAssertNil(ConnectorLabelMatcher.match("what's on my google calendar", in: instances))
        XCTAssertTrue(ConnectorLabelMatcher.distinctiveTokens(for: instances[0]).isEmpty)
    }

    /// Two instances the utterance names equally well is exactly where guessing is
    /// wrong, so a tie resolves to nil rather than to the first candidate.
    func testATieResolvesToNilRatherThanTheFirstCandidate() {
        let instances = [instance("Alpha"), instance("Beta")]
        XCTAssertNil(ConnectorLabelMatcher.match("check alpha and beta", in: instances))
    }

    func testEmptyInputsMatchNothing() {
        XCTAssertNil(ConnectorLabelMatcher.match("", in: workAndPersonal))
        XCTAssertNil(ConnectorLabelMatcher.match("   ", in: workAndPersonal))
        XCTAssertNil(ConnectorLabelMatcher.match("work", in: []))
    }

    func testAWordThatIsNoInstanceNameMatchesNothing() {
        XCTAssertNil(ConnectorLabelMatcher.match("what's on my school calendar", in: workAndPersonal))
    }

    // MARK: - Tokenising

    func testApostrophesAreStrippedNotSplitOn() {
        // "what's" must become the stopword "whats", not "what" + "s" — otherwise a
        // stray "s" token could collide with a one-letter label.
        XCTAssertEqual(ConnectorLabelMatcher.tokens("what's up"), ["whats", "up"])
        XCTAssertEqual(ConnectorLabelMatcher.tokens("what\u{2019}s up"), ["whats", "up"])
    }

    func testTokensDropPunctuationAndKeepNumbers() {
        XCTAssertEqual(ConnectorLabelMatcher.tokens("Work-2, please!"), ["work", "2", "please"])
    }

    func testDistinctiveTokensStripKindWordsAndStopwords() {
        let hit = instance("My Work Calendar")
        XCTAssertEqual(ConnectorLabelMatcher.distinctiveTokens(for: hit), ["work"])
    }

    // MARK: - namesAnInstance

    func testNamesAnInstanceAgreesWithMatch() {
        XCTAssertTrue(ConnectorLabelMatcher.namesAnInstance("my work calendar", in: workAndPersonal))
        XCTAssertFalse(ConnectorLabelMatcher.namesAnInstance("what's my day", in: workAndPersonal))
    }
}
