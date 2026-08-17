import XCTest

@testable import WhisperMaster

/// The detector runs only downstream of the assistant chord, so a miss costs an
/// oddly-filed note rather than a lost transcript. What it must not do is match a
/// *sentence that contains* a transport word, because the chord is also how a note
/// gets dictated.
final class MediaCommandDetectorTests: XCTestCase {
    func testPlainCommands() {
        XCTAssertEqual(MediaCommandDetector.detect("pause"), .pause)
        XCTAssertEqual(MediaCommandDetector.detect("play"), .play)
        XCTAssertEqual(MediaCommandDetector.detect("resume"), .play)
    }

    /// The deterministic formatter has already capitalised and punctuated the
    /// capture by the time the router sees it.
    func testPunctuationAndCaseAreIgnored() {
        XCTAssertEqual(MediaCommandDetector.detect("Pause the music."), .pause)
        XCTAssertEqual(MediaCommandDetector.detect("  PLAY   THE  MUSIC  "), .play)
        XCTAssertEqual(MediaCommandDetector.detect("Stop the music!"), .pause)
    }

    func testTrackSkipping() {
        XCTAssertEqual(MediaCommandDetector.detect("next song"), .next)
        XCTAssertEqual(MediaCommandDetector.detect("skip this song"), .next)
        XCTAssertEqual(MediaCommandDetector.detect("previous track"), .previous)
    }

    /// The whole capture has to *be* the command. This is the line between an
    /// instruction and a note that happens to start with the same word.
    func testASentenceThatMerelyContainsTheWordIsNotACommand() {
        XCTAssertNil(MediaCommandDetector.detect("pause the deploy until I have looked at it"))
        XCTAssertNil(MediaCommandDetector.detect("play with the idea of a weekly digest"))
        XCTAssertNil(MediaCommandDetector.detect("remind me to pause my subscription"))
        XCTAssertNil(MediaCommandDetector.detect("note that the next song list needs work"))
    }

    /// "Next" and "back" on their own are too load-bearing elsewhere to claim.
    func testBareAmbiguousWordsAreNotClaimed() {
        XCTAssertNil(MediaCommandDetector.detect("next"))
        XCTAssertNil(MediaCommandDetector.detect("back"))
        XCTAssertNil(MediaCommandDetector.detect(""))
    }
}
