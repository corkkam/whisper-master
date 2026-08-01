import XCTest

@testable import WhisperMaster

/// The only part of "read the answer aloud" that can be wrong in a way you'd have to
/// *listen* for. Kept pure so the failure shows up here instead of as a garbled
/// sentence on someone's Mac.
final class SpokenAnswerTests: XCTestCase {

    // MARK: - Sanitising

    /// A 3B model emits markdown whether or not the prompt asked for it, and every
    /// marker is nonsense when spoken ("star star three star star meetings").
    func testStripsMarkdownEmphasisAndCodeTicks() {
        XCTAssertEqual(
            SpokenAnswer.prepare(headline: "You have **three** meetings and `one` call"),
            ["You have three meetings and one call"])
    }

    /// Underscores inside a word are part of the word, not emphasis — dropping them
    /// turns `snake_case` into an unpronounceable "snakecase".
    func testKeepsUnderscoresInsideWords() {
        XCTAssertEqual(
            SpokenAnswer.prepare(headline: "The _big_ one is in project_alpha"),
            ["The big one is in project_alpha"])
    }

    /// The markers go, and each item becomes its own sentence — a list read as one
    /// breathless run-on is the thing markdown-to-speech gets wrong most often.
    func testStripsHeadingAndBulletMarkersAndSeparatesItems() {
        XCTAssertEqual(
            SpokenAnswer.prepare(headline: "# Today\n- Standup at nine\n• Review at ten"),
            ["Today.", "Standup at nine.", "Review at ten"])
        XCTAssertEqual(
            SpokenAnswer.prepare(headline: "1. Standup\n2) Review"),
            ["Standup.", "Review"],
            "numbered items too")
    }

    /// …but a paragraph the model merely *wrapped* is one sentence. Inserting a full
    /// stop at a soft wrap would stop the voice dead mid-thought, so only a line that
    /// carried a marker earns a sentence break.
    func testSoftWrappedProseIsNotBrokenIntoSentences() {
        XCTAssertEqual(
            SpokenAnswer.prepare(headline: "You have three meetings today\nand a gap at noon"),
            ["You have three meetings today and a gap at noon"])
    }

    /// `#1` mid-sentence is a real word, unlike a leading heading marker.
    func testKeepsHashInsideALine() {
        XCTAssertEqual(
            SpokenAnswer.prepare(headline: "You are #1 on the list"),
            ["You are #1 on the list"])
    }

    /// A markdown link keeps its label; the URL it hides never reaches the URL pass.
    func testMarkdownLinkKeepsItsLabel() {
        XCTAssertEqual(
            SpokenAnswer.prepare(headline: "Join the [team standup](https://meet.example.com/abc-def) now"),
            ["Join the team standup now"])
        XCTAssertEqual(
            SpokenAnswer.prepare(headline: "Sort by [priority] then act"),
            ["Sort by [priority] then act"],
            "a bracket that isn't a link is left alone")
    }

    /// Nobody wants "h t t p colon slash slash" read to them.
    func testBareURLsBecomeTheWordLink() {
        XCTAssertEqual(
            SpokenAnswer.prepare(headline: "Notes are at https://example.com/x and www.example.org"),
            ["Notes are at link and link"])
    }

    func testStripsEmojiButKeepsDigitsAndPunctuation() {
        XCTAssertEqual(
            SpokenAnswer.prepare(headline: "📅 3 meetings today 🎉, first at 9:30"),
            ["3 meetings today, first at 9:30"])
    }

    /// A flag is two regional indicators and a thumbs-up carries a skin-tone modifier;
    /// both would survive a naive `isEmojiPresentation` filter.
    func testStripsCompositeEmoji() {
        XCTAssertEqual(
            SpokenAnswer.prepare(headline: "Ship it 👍🏽 in 🇬🇧 today"),
            ["Ship it in today"])
    }

    /// A four-line list arriving from the model should read as one continuous answer,
    /// not four with ragged dead air between them.
    func testCollapsesNewlinesAndRunsOfSpaces() {
        XCTAssertEqual(
            SpokenAnswer.prepare(headline: "Standup\n\nthen   review\tthen lunch"),
            ["Standup then review then lunch"])
    }

    // MARK: - Nothing to say

    /// Callers treat an empty result as "don't speak" — it must never be an error, and
    /// must never be a single empty utterance the backend then chokes on.
    func testEmptyInputYieldsNothingToSay() {
        XCTAssertEqual(SpokenAnswer.prepare(headline: ""), [])
        XCTAssertEqual(SpokenAnswer.prepare(headline: "   \n\t "), [])
        XCTAssertEqual(SpokenAnswer.prepare(headline: "✨"), [], "emoji-only is nothing to say")
    }

    // MARK: - Provenance

    /// The agent path passes no detail: "From Work Calendar" is chrome worth seeing and
    /// not worth hearing. The deterministic path passes it, because there it carries
    /// the actual next thing.
    func testDetailIsSpokenOnlyWhenProvided() {
        XCTAssertEqual(
            SpokenAnswer.prepare(headline: "Three meetings today", detail: nil),
            ["Three meetings today"])
        XCTAssertEqual(
            SpokenAnswer.prepare(headline: "Three meetings today", detail: "Next up: standup at nine"),
            ["Three meetings today.", "Next up: standup at nine"])
    }

    /// A headline that already ends in a full stop shouldn't collect a second one —
    /// the synthesizer reads ".." as a longer, wrong-sounding pause.
    func testDoesNotDoublePunctuateBeforeTheDetail() {
        XCTAssertEqual(
            SpokenAnswer.prepare(headline: "You're free today.", detail: "Nothing scheduled"),
            ["You're free today.", "Nothing scheduled"])
    }

    func testEmptyDetailIsIgnored() {
        XCTAssertEqual(
            SpokenAnswer.prepare(headline: "You're free today", detail: "  "),
            ["You're free today"])
    }

    // MARK: - Sentence splitting

    func testSplitsOnTerminalPunctuation() {
        XCTAssertEqual(
            SpokenAnswer.prepare(headline: "You have three meetings. The first is at nine! Ready?"),
            ["You have three meetings.", "The first is at nine!", "Ready?"])
    }

    /// Requiring whitespace after the period is what stops a decimal or a hostname
    /// from being read as two sentences.
    func testDoesNotSplitInsideNumbersOrHostnames() {
        XCTAssertEqual(
            SpokenAnswer.prepare(headline: "It ran 3.5 hours on example.com servers"),
            ["It ran 3.5 hours on example.com servers"])
    }

    func testDoesNotSplitAfterCommonAbbreviations() {
        XCTAssertEqual(
            SpokenAnswer.prepare(headline: "Dr. Chen moved it to 4 p.m. today"),
            ["Dr. Chen moved it to 4 p.m. today"])
        XCTAssertEqual(
            SpokenAnswer.prepare(headline: "J. Alvarez is joining"),
            ["J. Alvarez is joining"],
            "a lone initial is not a sentence end")
    }

    // MARK: - Length limits

    /// `KokoroAneManager` throws over 512 IPA tokens, so this is a hard requirement of
    /// the natural backend — not a nicety. Every chunk must clear the ceiling.
    func testLongSentenceIsChunkedUnderTheUtteranceLimit() {
        let long = String(repeating: "meeting ", count: 120)   // ~960 chars, no full stop
        let sentences = SpokenAnswer.prepare(headline: long)
        XCTAssertGreaterThan(sentences.count, 1)
        for sentence in sentences {
            XCTAssertLessThanOrEqual(sentence.count, SpokenAnswer.maxSentenceCharacters)
        }
    }

    /// Chunking breaks at a space, so no word is sliced in half when there is one.
    func testChunkingBreaksOnWordBoundaries() {
        let long = String(repeating: "alpha bravo ", count: 40)
        for sentence in SpokenAnswer.prepare(headline: long) {
            XCTAssertFalse(sentence.hasPrefix("lpha"), "chunk began mid-word: \(sentence)")
            XCTAssertFalse(sentence.hasSuffix("brav"), "chunk ended mid-word: \(sentence)")
        }
    }

    /// A single word longer than the limit has no space to break on. Cutting it beats
    /// throwing at the backend, which would mean silence.
    func testAnUnbreakableWordIsCutRatherThanDropped() {
        let sentences = SpokenAnswer.prepare(headline: String(repeating: "a", count: 700))
        XCTAssertFalse(sentences.isEmpty)
        for sentence in sentences {
            XCTAssertLessThanOrEqual(sentence.count, SpokenAnswer.maxSentenceCharacters)
        }
    }

    /// The whole answer is capped at whole-sentence granularity — we stop between
    /// sentences rather than mid-thought, and we never speak an apology about it.
    func testTotalLengthIsCappedAtASentenceBoundary() {
        let sentence = String(repeating: "word ", count: 20) + "end. "   // ~105 chars
        let sentences = SpokenAnswer.prepare(headline: String(repeating: sentence, count: 20))
        let total = sentences.reduce(0) { $0 + $1.count }
        XCTAssertLessThanOrEqual(total, SpokenAnswer.maxSpokenCharacters + SpokenAnswer.maxSentenceCharacters)
        XCTAssertFalse(sentences.isEmpty)
        for spoken in sentences {
            XCTAssertFalse(spoken.lowercased().contains("truncated"))
        }
    }

    /// Even when the first sentence alone blows the total budget, something is said —
    /// it's already chunked to the utterance limit, so there is always a first chunk.
    func testAlwaysSpeaksAtLeastTheFirstSentence() {
        let sentences = SpokenAnswer.prepare(headline: String(repeating: "long ", count: 400))
        XCTAssertFalse(sentences.isEmpty)
    }
}
