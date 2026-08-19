import XCTest

@testable import WhisperMaster

/// The rule every test here defends: **two key presses per hold, one down and one up,
/// and nothing in between.**
///
/// Both bugs this feature shipped were a press in the middle of a hold, and both had
/// the same root: the only signal for "is media playing" is whether a process is
/// running a Core Audio output stream, and that stays true for seconds after playback
/// stops — longer still for a browser. So any mid-hold press acts on a guess, and the
/// cost of a wrong guess is the user's music starting in the middle of the sentence
/// they are dictating.
///
/// 1. The first version pressed, re-checked 400 ms later, saw the stream still alive,
///    decided the press had failed, and pressed again on the next tick: off, on, off,
///    on for as long as the key was held.
/// 2. The second version pressed once and watched up to six seconds for the speakers
///    to go quiet, pressing back if they never did. A browser holds its stream open
///    past that window, so a *correct* pause was undone a few seconds into every
///    dictation — and never handed back, because the press-back cleared the debt.
///
/// A press that went the wrong way is corrected by the release press, which happens
/// anyway and needs no inference to be right.
@MainActor
final class MediaPauserTests: XCTestCase {
    /// Records presses and answers "what is playing" from a script.
    private final class World {
        var presses: [MediaKey.Key] = []
        /// Answers, consumed one per look; the last one repeats forever.
        var samples: [[String]]

        init(samples: [[String]]) { self.samples = samples }

        func take() -> [String] {
            guard samples.count > 1 else { return samples.first ?? [] }
            return samples.removeFirst()
        }
    }

    private func makePauser(_ world: World) -> MediaPauser {
        var env = MediaPauser.Environment()
        env.ownBundleID = "app.whispermaster.mac"
        env.playingApps = { _ in world.take() }
        env.press = { world.presses.append($0) }
        return MediaPauser(environment: env)
    }

    /// Let the pauser's detached look-ups run.
    private func settle(_ rounds: Int = 12) async {
        for _ in 0..<rounds {
            try? await Task.sleep(nanoseconds: 10_000_000)
            await Task.yield()
        }
    }

    /// The tick keeps saying "busy" every 0.5 s, so this is what a hold looks like from
    /// the pauser's side.
    private func hold(_ pauser: MediaPauser, ticks: Int, from start: Date) async {
        for tick in 0...ticks {
            pauser.update(
                enabled: true, busy: true, now: start.addingTimeInterval(Double(tick) * 0.5))
            await settle(2)
        }
    }

    // MARK: - The invariant

    /// **The bug this file exists for, in one test.** The hold runs for thirty ticks and
    /// the speakers never go quiet — which is what a browser looks like for as long as
    /// it feels like after a pause that worked perfectly. Exactly one press may leave
    /// during the hold. A second one is the music coming back mid-sentence.
    func testNothingIsPressedMidHoldHoweverLongTheHold() async {
        let world = World(samples: [["com.brave.Browser.helper"]])   // never goes quiet
        let pauser = makePauser(world)
        let start = Date()

        await hold(pauser, ticks: 30, from: start)

        XCTAssertEqual(world.presses, [.playPause], "one press for the whole hold")

        pauser.update(
            enabled: true, busy: false,
            now: start.addingTimeInterval(15 + MediaPauser.resumeGrace + 1))
        await settle()
        XCTAssertEqual(world.presses, [.playPause, .playPause], "and one to hand it back")
    }

    /// The good case: something is playing, it goes quiet after the press, and the
    /// release hands it back. Two presses, one each way.
    func testPausesOnceAndResumesOnce() async {
        let world = World(samples: [["com.apple.Music"], []])
        let pauser = makePauser(world)

        pauser.update(enabled: true, busy: true)
        await settle()
        XCTAssertEqual(world.presses.count, 1, "one press to pause")

        pauser.update(
            enabled: true, busy: false,
            now: Date().addingTimeInterval(MediaPauser.resumeGrace + 1))
        await settle()
        XCTAssertEqual(world.presses, [.playPause, .playPause], "one press back")
    }

    /// Nothing playing means nothing to do — the press that would *start* the user's
    /// paused music must never leave.
    func testSilenceIsNeverPressed() async {
        let world = World(samples: [[]])
        let pauser = makePauser(world)

        pauser.update(enabled: true, busy: true)
        await settle()
        pauser.update(
            enabled: true, busy: false,
            now: Date().addingTimeInterval(MediaPauser.resumeGrace + 1))
        await settle()

        XCTAssertTrue(world.presses.isEmpty)
    }

    /// A press that went the wrong way — the stream we saw was the tail of playback the
    /// user had already stopped by hand, so the press *started* their music — is put
    /// right by the release press, not by a guess made mid-hold. The music plays for the
    /// length of the dictation and is then silenced, so the user's media ends where they
    /// left it.
    func testAWrongPressIsUndoneAtRelease() async {
        let world = World(samples: [["com.google.Chrome.helper"]])  // never quiet
        let pauser = makePauser(world)
        let start = Date()

        await hold(pauser, ticks: 8, from: start)
        XCTAssertEqual(world.presses, [.playPause], "nothing presses mid-hold")

        pauser.update(
            enabled: true, busy: false,
            now: start.addingTimeInterval(4 + MediaPauser.resumeGrace + 1))
        await settle()
        XCTAssertEqual(world.presses, [.playPause, .playPause], "the release puts it back")
    }

    /// The release waits out the grace, so the gaps between recording, the agent run
    /// and the answer being spoken do not flick the music on mid-question.
    func testReleaseWaitsForTheGrace() async {
        let world = World(samples: [["com.apple.Music"], []])
        let pauser = makePauser(world)

        pauser.update(enabled: true, busy: true)
        await settle()
        pauser.update(enabled: true, busy: false)      // idle, but only just
        await settle()
        XCTAssertEqual(world.presses.count, 1, "still held")

        pauser.update(
            enabled: true, busy: false,
            now: Date().addingTimeInterval(MediaPauser.resumeGrace + 1))
        await settle()
        XCTAssertEqual(world.presses.count, 2)
    }

    /// A spoken "play" or "pause" takes the wheel: the automatic release must not
    /// press afterwards and undo what the user just asked for.
    func testYieldingToTheUserStopsTheAutomaticRelease() async {
        let world = World(samples: [["com.apple.Music"], []])
        let pauser = makePauser(world)

        pauser.update(enabled: true, busy: true)
        await settle()
        XCTAssertEqual(world.presses.count, 1)

        pauser.yieldToUser()
        pauser.update(
            enabled: true, busy: false,
            now: Date().addingTimeInterval(MediaPauser.resumeGrace + 1))
        await settle()

        XCTAssertEqual(world.presses.count, 1, "the user owns playback now")
    }

    /// Turning the setting off mid-hold gives the music back rather than stranding it.
    func testSwitchingTheSettingOffReleasesTheHold() async {
        let world = World(samples: [["com.apple.Music"], []])
        let pauser = makePauser(world)

        pauser.update(enabled: true, busy: true)
        await settle()
        pauser.update(enabled: false, busy: true)
        await settle()

        XCTAssertEqual(world.presses.count, 2)
    }

    // MARK: - The release always presses back

    /// The release must not ask the speakers for permission first. Our own paused
    /// player is still lingering, and a browser opens a silent output stream of its own
    /// whenever anything else plays — including this app reading an answer aloud. Both
    /// read as "something is playing", and both used to swallow the resume.
    func testAStreamPlayingAtReleaseDoesNotSwallowTheResume() async {
        // Playing → quiet (the pause takes) → a courtesy stream appears while the
        // answer is spoken, and is still there when the exchange ends.
        let world = World(samples: [["com.apple.Music"], [], ["com.google.Chrome.helper"]])
        let pauser = makePauser(world)

        pauser.update(enabled: true, busy: true)
        await settle()

        pauser.update(
            enabled: true, busy: false,
            now: Date().addingTimeInterval(MediaPauser.resumeGrace + 1))
        await settle()

        XCTAssertEqual(world.presses, [.playPause, .playPause])
    }

    /// The whole assistant exchange, stage by stage: the chord goes down, recording
    /// ends, the agent runs, the answer is read aloud, and only then is the music owed
    /// back — once, at the end.
    func testAWholeAssistantExchangeResumesOnceAtTheEnd() async {
        let world = World(samples: [["com.apple.Music"]])
        let pauser = makePauser(world)
        let start = Date()

        // Recording, the agent run, then the answer being spoken: the tick reports busy
        // throughout, with the sub-second idle gaps the grace exists to cover.
        await hold(pauser, ticks: 12, from: start)
        XCTAssertEqual(world.presses.count, 1, "still held for the whole exchange")

        pauser.update(
            enabled: true, busy: false,
            now: start.addingTimeInterval(6 + MediaPauser.resumeGrace + 0.5))
        await settle()
        XCTAssertEqual(world.presses, [.playPause, .playPause])
    }

    /// A second dictation right after the first pauses and resumes again — the release
    /// has to leave the pauser able to press, not just able to decide.
    func testASecondHoldPausesAndResumesAgain() async {
        let world = World(samples: [["com.apple.Music"]])
        let pauser = makePauser(world)

        for round in 0..<2 {
            pauser.update(enabled: true, busy: true)
            await settle()
            pauser.update(
                enabled: true, busy: false,
                now: Date().addingTimeInterval(MediaPauser.resumeGrace + 1))
            await settle()
            XCTAssertEqual(world.presses.count, (round + 1) * 2, "round \(round)")
        }
    }

    /// Quitting mid-hold gives the music back even though the tick will never run
    /// again.
    func testTerminationReleasesOnceWhileHolding() async {
        let world = World(samples: [["com.apple.Music"]])
        let pauser = makePauser(world)

        pauser.update(enabled: true, busy: true)
        await settle()
        pauser.releaseForTermination()
        await settle()

        XCTAssertEqual(world.presses, [.playPause, .playPause])
    }
}
