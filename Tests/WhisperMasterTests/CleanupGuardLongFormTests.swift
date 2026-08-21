import XCTest

@testable import WhisperMaster

/// The long-form band, written against the four outputs the eval actually
/// produced for a 521-word dictation. Every one of them was **accepted** by the
/// short-input band, which is what let 60% of a paragraph disappear silently.
final class CleanupGuardLongFormTests: XCTestCase {

    private func words(_ n: Int) -> String {
        (0..<n).map { "word\($0)" }.joined(separator: " ")
    }

    /// `n` short sentences, so the text is long-form *and* properly terminated —
    /// the shape a real cleaned paragraph has.
    private func sentences(_ n: Int) -> String {
        (0..<n).map { "This is sentence number \($0)." }.joined(separator: " ")
    }

    // MARK: - The measured failures

    /// Full suite, chunking off: 207 words back from 521. Ratio 0.40, which
    /// cleared the 0.30 floor. The paragraph lost three fifths of itself and the
    /// text shipped.
    func testTheSixtyPercentDropIsRejected() {
        let verdict = CleanupFaithfulnessGuard.verdict(
            original: words(521), cleaned: words(207), allowRephrase: true)
        XCTAssertFalse(verdict.isAccepted, "0.40 retention on a long input is data loss")
    }

    /// Full suite, chunking on: 765 words back from 521 — a sentence repeated 19
    /// times. Ratio 1.47, which cleared the 2.0 rephrase ceiling.
    func testTheDegenerateLoopIsRejected() {
        let verdict = CleanupFaithfulnessGuard.verdict(
            original: words(521), cleaned: words(765), allowRephrase: true)
        XCTAssertFalse(verdict.isAccepted, "1.47 expansion on a long input is a loop")
    }

    /// Isolated, chunking off: 437 words back from 521, stopping on the word "We".
    /// **Ratio 0.84 — no floor rejects it without also rejecting the good 0.95 pass
    /// beside it.** What makes it wrong is where it stops, so that is what's tested.
    func testTheMidSentenceTruncationIsRejected() {
        let truncated = sentences(60) + " and we were 3 versions behind training. We"
        let verdict = CleanupFaithfulnessGuard.verdict(
            original: sentences(75), cleaned: truncated, allowRephrase: true)
        XCTAssertEqual(verdict, .cutOff)
    }

    /// Isolated, chunking on: ends where the speaker did. A faithful long-form pass
    /// has to survive, or the band is useless.
    func testTheGoodChunkedPassIsAccepted() {
        let verdict = CleanupFaithfulnessGuard.verdict(
            original: sentences(75), cleaned: sentences(72), allowRephrase: true)
        XCTAssertTrue(verdict.isAccepted, "a complete long-form cleanup must pass")
    }

    /// **The casual register omits the final period on purpose** (S1-mini's card),
    /// so a missing terminator is only evidence of truncation when the model was
    /// punctuating at all. An unpunctuated output must not be read as cut off.
    func testAnUnpunctuatedCasualOutputIsNotReadAsTruncated() {
        XCTAssertFalse(CleanupFaithfulnessGuard.endsMidSentence(words(200)))
        XCTAssertTrue(
            CleanupFaithfulnessGuard.endsMidSentence("One thing. Then another. And a third"))
    }

    func testAQuotedOrBracketedEndingIsNotTruncation() {
        for ending in ["he said \"fine\"", "the note (see above)", "here it is:"] {
            XCTAssertFalse(
                CleanupFaithfulnessGuard.endsMidSentence("A sentence. Another one. " + ending),
                ending)
        }
    }

    // MARK: - The short band is untouched

    /// The loose band exists because short utterances swing wildly, and the cases
    /// it was tuned against must not start failing.
    func testAShortUtteranceKeepsItsLooseBand() {
        // "so um i think maybe we should go" -> "I think we should go": 0.62,
        // under no circumstances a long-form ratio, and correct here.
        let verdict = CleanupFaithfulnessGuard.verdict(
            original: words(8), cleaned: words(5))
        XCTAssertTrue(verdict.isAccepted)
    }

    func testAModerateInputIsStillJudgedLoosely() {
        let n = CleanupFaithfulnessGuard.longFormMinWords - 1
        let verdict = CleanupFaithfulnessGuard.verdict(
            original: words(n), cleaned: words(Int(Double(n) * 0.5)))
        XCTAssertTrue(verdict.isAccepted, "below the threshold the old band applies")
    }

    /// The boundary is a real switch, not a gradient — assert it flips exactly
    /// where it is documented to.
    func testTheBandTightensExactlyAtTheThreshold() {
        let n = CleanupFaithfulnessGuard.longFormMinWords
        let half = Int(Double(n) * 0.5)
        XCTAssertFalse(
            CleanupFaithfulnessGuard.verdict(original: words(n), cleaned: words(half))
                .isAccepted)
        XCTAssertTrue(
            CleanupFaithfulnessGuard.verdict(original: words(n - 1), cleaned: words(half))
                .isAccepted)
    }
}
