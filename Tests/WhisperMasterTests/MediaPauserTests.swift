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

    private func makePauser(_ world: World) -> MediaPauser {
        var env = MediaPauser.Environment()
        env.ownBundleID = "app.whispermaster.mac"
        env.playingApps = { _ in world.take() }
        env.press = { world.presses.append($0) }
        env.confirmInterval = 5_000_000       // 5 ms, so a test is not a 6 s wait
        env.confirmWindow = 0.05
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
}
