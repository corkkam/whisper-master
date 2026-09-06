import XCTest

@testable import WhisperMaster

final class DeterministicITNTests: XCTestCase {
    // Regression: a bare "one" was digitized with no context — "one honest
    // footnote" → "1 honest footnote", "one day" → "1 day".
    func testBareOneStaysAWord() {
        XCTAssertEqual(DeterministicITN.normalize("one honest footnote"), "one honest footnote")
        XCTAssertEqual(DeterministicITN.normalize("remind me in one day"), "remind me in one day")
        XCTAssertEqual(DeterministicITN.normalize("one of them is broken"), "one of them is broken")
        XCTAssertEqual(DeterministicITN.normalize("no one showed up"), "no one showed up")
    }

    func testOneWithUnitStillDigitizes() {
        XCTAssertEqual(DeterministicITN.normalize("give me one dollar"), "give me $1")
        XCTAssertEqual(DeterministicITN.normalize("it grew one percent"), "it grew 1%")
    }

    func testMultiWordNumbersStillDigitize() {
        XCTAssertEqual(DeterministicITN.normalize("twenty five people came"), "25 people came")
        XCTAssertEqual(
            DeterministicITN.normalize("send twenty five dollars today"),
            "send $25 today"
        )
    }

    func testTimeStillWorks() {
        XCTAssertEqual(DeterministicITN.normalize("meet at one thirty"), "meet at 1:30")
        XCTAssertEqual(DeterministicITN.normalize("meet at four thirty today"), "meet at 4:30 today")
    }

    // Regression: "mic testing one two three" came out as "mic testing 6" —
    // consecutive unit words were summed (1+2+3). A run of number words that
    // isn't a well-formed single cardinal must stay as spoken words, never
    // collapse to a number.
    func testDigitSequencesAreNotSummed() {
        XCTAssertEqual(DeterministicITN.normalize("mic testing one two three"), "mic testing one two three")
        XCTAssertEqual(DeterministicITN.normalize("testing one two three"), "testing one two three")
        XCTAssertEqual(DeterministicITN.normalize("five three seven nine"), "five three seven nine")
        XCTAssertEqual(DeterministicITN.normalize("count down five four three two one"), "count down five four three two one")
    }

    // Regression: "room two oh five" came out as "room 2:05" — a room number
    // spoken as digit-chunks ("two oh five", "two fourteen") was misread as a
    // clock time. After a room-like keyword it's a digit sequence, not a time
    // or a cardinal: "two oh five" → 205, "two fourteen" → 214.
    func testRoomNumbersAreDigitSequencesNotTimes() {
        XCTAssertEqual(DeterministicITN.normalize("the meeting is in room two oh five"), "the meeting is in room 205")
        XCTAssertEqual(DeterministicITN.normalize("the interview is in room two fourteen"), "the interview is in room 214")
        XCTAssertEqual(DeterministicITN.normalize("suite three oh one"), "suite 301")
        XCTAssertEqual(DeterministicITN.normalize("apartment twenty five"), "apartment 25")
        XCTAssertEqual(DeterministicITN.normalize("unit one twenty"), "unit 120")
    }

    // A room keyword must not swallow a following single number word oddly, and
    // must not turn a genuine time (with time context) into a room number.
    func testRoomNumberDoesNotBreakTimesOrSingleDigits() {
        XCTAssertEqual(DeterministicITN.normalize("meet at two oh five pm"), "meet at 2:05 PM")
        XCTAssertEqual(DeterministicITN.normalize("go to room five"), "go to room 5")
    }

    // The fix must not regress genuinely valid multi-word cardinals.
    func testValidCompoundNumbersStillDigitize() {
        XCTAssertEqual(DeterministicITN.normalize("one hundred twenty three"), "123")
        XCTAssertEqual(DeterministicITN.normalize("three thousand five hundred"), "3500")
        XCTAssertEqual(DeterministicITN.normalize("twenty one"), "21")
        XCTAssertEqual(DeterministicITN.normalize("one hundred and five"), "105")
    }

    // MARK: - Emails, and the locative "at" that is not an @

    func testSpokenEmailJoins() {
        XCTAssertEqual(DeterministicITN.normalize("email me at shobhit at gmail dot com"),
                       "email me at shobhit@gmail.com")
        XCTAssertEqual(DeterministicITN.normalize("ninja at gmail dot com"),
                       "ninja@gmail.com")
        // Known limitation, unchanged by this work: a *dotted local part* is not
        // assembled, because "smith" is not a TLD and nothing else joins it. The
        // address still forms from the last segment.
        XCTAssertEqual(DeterministicITN.normalize("mail john dot smith at gmail dot com"),
                       "mail john dot smith@gmail.com")
    }

    /// Found by the eval: "the repo is at github dot com" became
    /// `the repo is@github.com`, because the only test on the local-part was
    /// `isWordy` and "is" is wordy. A sentence turned into a plausible-looking
    /// address is the worst kind of wrong -- nothing downstream questions it.
    func testLocativeAtIsNotAnEmail() {
        XCTAssertEqual(DeterministicITN.normalize("the repo is at github dot com"),
                       "the repo is at github.com")
        XCTAssertEqual(DeterministicITN.normalize("the docs live at example dot com"),
                       "the docs live at example.com")
        XCTAssertEqual(DeterministicITN.normalize("we meet at zoom dot us"),
                       "we meet at zoom.us")
        XCTAssertEqual(DeterministicITN.normalize("mail me at example dot com"),
                       "mail me at example.com")
    }

    /// The already-collapsed-domain branch takes the same guard, or the bug just
    /// moves to whichever form the ASR happened to emit.
    func testLocativeAtIsNotAnEmailWhenTheAsrCollapsedTheDomain() {
        XCTAssertEqual(DeterministicITN.normalize("the repo is at github.com"),
                       "the repo is at github.com")
        XCTAssertEqual(DeterministicITN.normalize("ping sam at example.com"),
                       "ping sam@example.com")
    }

    // MARK: - Spoken domains that are not addresses

    func testSpokenDomainBecomesADomain() {
        XCTAssertEqual(DeterministicITN.normalize("the repo is at github dot com slash corkkam"),
                       "the repo is at github.com slash corkkam")
        XCTAssertEqual(DeterministicITN.normalize("go to example dot co dot uk"),
                       "go to example.co.uk")
    }

    /// "dot" is an ordinary English word. The TLD set is closed so that prose
    /// is never rewritten into a hostname.
    func testOrdinaryDotIsLeftAlone() {
        XCTAssertEqual(DeterministicITN.normalize("take the dot product first"),
                       "take the dot product first")
        XCTAssertEqual(DeterministicITN.normalize("connect the dot to the line"),
                       "connect the dot to the line")
    }
}
