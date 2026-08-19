import XCTest

@testable import WhisperMaster

/// The rule these exist for: **one press per hold.**
///
/// The shipped first version pressed, re-checked 400 ms later, saw the player's
/// output stream still alive — it lingers ~3.5 s after a real pause — concluded the
/// press had failed, and let the next 0.5 s tick press again. Holding the key for a
/// few seconds toggled the music off, on, off, on, and whichever phase the release
/// landed in is what the user was left with. Every test below is that bug or its
/// neighbours.
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

    /// `confirmWindow` is the interesting knob. The default here is short so most
    /// tests do not wait, but the real one is 6 s — it has to outlast the output-stream
    /// linger — so the tests that matter for the release path pass a long window and
    /// let the release land *inside* the confirmation, which is what happens on every
    /// real dictation.
    private func makePauser(_ world: World, confirmWindow: TimeInterval = 0.05)
        -> MediaPauser
    {
        var env = MediaPauser.Environment()
        env.ownBundleID = "app.whispermaster.mac"
        env.playingApps = { _ in world.take() }
        env.press = { world.presses.append($0) }
        env.confirmInterval = 5_000_000       // 5 ms, so a test is not a 6 s wait
        env.confirmWindow = confirmWindow
        return MediaPauser(environment: env)
    }

    /// Let the pauser's detached look-ups run.
    private func settle(_ rounds: Int = 12) async {
        for _ in 0..<rounds {
            try? await Task.sleep(nanoseconds: 10_000_000)
            await Task.yield()
        }
    }

    // MARK: - The regression

    /// The tick keeps reporting "busy" every 0.5 s for the whole hold, and the
    /// speakers keep reporting the lingering stream. Exactly one press may leave.
    func testHoldPressesOnceEvenWhileTheStreamStillReadsAsPlaying() async {
        let world = World(samples: [["com.spotify.client"]])   // never goes quiet
        let pauser = makePauser(world)

        pauser.update(enabled: true, busy: true)
        await settle()
        for _ in 0..<6 {                                        // six more ticks
            pauser.update(enabled: true, busy: true)
            await settle(2)
        }

        // One press to pause, and one to undo it once the confirmation window shows
        // the stream never went quiet. Never a third.
        XCTAssertLessThanOrEqual(world.presses.count, 2)
        XCTAssertGreaterThanOrEqual(world.presses.count, 1)
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

    /// A press that turned out to start something is undone, and then owes nothing at
    /// release — otherwise the release would pause whatever it had started.
    func testAWrongPressIsUndoneAndNotResumed() async {
        let world = World(samples: [["com.google.Chrome.helper"]])  // never quiet
        let pauser = makePauser(world)

        pauser.update(enabled: true, busy: true)
        await settle()
        let afterHold = world.presses.count

        pauser.update(
            enabled: true, busy: false,
            now: Date().addingTimeInterval(MediaPauser.resumeGrace + 1))
        await settle()

        XCTAssertEqual(world.presses.count, afterHold, "nothing owed at release")
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

    // MARK: - The second regression: the music never came back

    /// **The shipped bug this pins.** The confirmation watches for up to six seconds,
    /// because it has to outlast the ~3.5 s output-stream linger — and a dictation is
    /// normally over long before that. The confirmation used to hold the "one Core
    /// Audio conversation at a time" flag for its whole run, so the release found the
    /// pauser busy, dropped the press, and the music stayed off for good. Every short
    /// dictation and every assistant question ended in silence.
    func testReleaseInsideTheConfirmationStillHandsTheMusicBack() async {
        // Never goes quiet, so the confirmation is still watching at release — the same
        // reading a player gives for the first ~3.5 s after a pause that worked.
        let world = World(samples: [["com.spotify.client"]])
        let pauser = makePauser(world, confirmWindow: 60)

        pauser.update(enabled: true, busy: true)
        await settle()
        XCTAssertEqual(world.presses.count, 1, "one press to pause")

        pauser.update(
            enabled: true, busy: false,
            now: Date().addingTimeInterval(MediaPauser.resumeGrace + 1))
        await settle()

        XCTAssertEqual(world.presses, [.playPause, .playPause], "the music comes back")
    }

    /// The release must not ask the speakers for permission first. Our own paused
    /// player is still lingering, and Chrome opens a silent output stream of its own
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
    /// back — once, at the end, with the confirmation still in flight throughout.
    func testAWholeAssistantExchangeResumesOnceAtTheEnd() async {
        let world = World(samples: [["com.apple.Music"]])
        let pauser = makePauser(world, confirmWindow: 60)
        let start = Date()

        pauser.update(enabled: true, busy: true, now: start)   // chord down
        await settle()
        // Recording, the agent run, then the answer being spoken: the tick reports busy
        // throughout, with the sub-second idle gaps the grace exists to cover.
        for step in stride(from: 0.5, through: 6.0, by: 0.5) {
            pauser.update(
                enabled: true, busy: true, now: start.addingTimeInterval(step))
            await settle(2)
        }
        XCTAssertEqual(world.presses.count, 1, "still held for the whole exchange")

        pauser.update(
            enabled: true, busy: false,
            now: start.addingTimeInterval(6.0 + MediaPauser.resumeGrace + 0.5))
        await settle()
        XCTAssertEqual(world.presses, [.playPause, .playPause])
    }

    /// A second dictation right after the first pauses and resumes again — the release
    /// has to leave the pauser able to press, not just able to decide.
    func testASecondHoldPausesAndResumesAgain() async {
        let world = World(samples: [["com.apple.Music"]])
        let pauser = makePauser(world, confirmWindow: 60)

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
    /// again, and the cancelled confirmation must not press after it.
    func testTerminationReleasesOnceWhileConfirming() async {
        let world = World(samples: [["com.apple.Music"]])
        let pauser = makePauser(world, confirmWindow: 60)

        pauser.update(enabled: true, busy: true)
        await settle()
        pauser.releaseForTermination()
        await settle()

        XCTAssertEqual(world.presses, [.playPause, .playPause])
    }
}
