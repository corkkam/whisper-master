import SwiftUI
import XCTest

@testable import WhisperMaster

private let full = OnboardingMotionPolicy.resolve(reduceMotion: false, lowPower: false, thermal: .nominal, voiceOver: false)
private let still = OnboardingMotionPolicy.resolve(reduceMotion: true, lowPower: false, thermal: .nominal, voiceOver: false)

/// The orb's dip and the grant bloom, as pure functions of elapsed time. The
/// opening, beat-change and outro frames land with the view that draws them.
final class OnboardingMotionTests: XCTestCase {
    // MARK: OrbDip

    func testDipReachesItsLowAtTheFigureSwap() {
        let low = OrbDip.frame(at: 0.14, policy: full)
        XCTAssertEqual(low.opacity, 0.35, accuracy: 1e-9)
        XCTAssertEqual(low.scale, 0.90, accuracy: 1e-9)
        XCTAssertTrue(low.figureIsNew)
        XCTAssertFalse(OrbDip.frame(at: 0.139, policy: full).figureIsNew)
    }

    func testDipIsBackAtRestAt420ms() {
        XCTAssertEqual(OrbDip.frame(at: 0.42, policy: full), OrbDip.rest)
        XCTAssertEqual(OrbDip.frame(at: 3, policy: full), OrbDip.rest)
    }

    func testDipStartsAtRest() {
        let start = OrbDip.frame(at: 0, policy: full)
        XCTAssertEqual(start.opacity, 1)
        XCTAssertEqual(start.scale, 1)
        XCTAssertFalse(start.figureIsNew)
    }

    /// A second change before the low point only changes the target figure.
    func testAChangeAt100msKeepsTheRunningDip() {
        XCTAssertFalse(OrbDip.restarts(changeAt: 0.10))
    }

    /// From the low point on, a new dip starts from wherever the orb is.
    func testAChangeAt300msStartsANewDipFromTheCurrentFrame() {
        XCTAssertTrue(OrbDip.restarts(changeAt: 0.30))
        let current = OrbDip.frame(at: 0.30, policy: full)
        XCTAssertEqual(OrbDip.frame(at: 0, from: current, policy: full).opacity, current.opacity, accuracy: 1e-9)
        let low = OrbDip.frame(at: 0.14, from: current, policy: full)
        XCTAssertEqual(low.opacity, 0.35, accuracy: 1e-9)
        XCTAssertEqual(low.scale, 0.90, accuracy: 1e-9)
    }

    func testDipIsClampedAndFinite() {
        for ms in stride(from: -100, through: 1000, by: 5) {
            let frame = OrbDip.frame(at: Double(ms) / 1000, policy: full)
            XCTAssertTrue(frame.opacity.isFinite && frame.scale.isFinite)
            XCTAssertTrue((0.35 - 1e-9...1 + 1e-9).contains(frame.opacity), "opacity at \(ms) ms")
            XCTAssertTrue((0.90 - 1e-9...1 + 1e-9).contains(frame.scale), "scale at \(ms) ms")
        }
    }

    func testStillPolicyNeverDips() {
        for ms in stride(from: 0, through: 500, by: 10) {
            XCTAssertEqual(OrbDip.frame(at: Double(ms) / 1000, policy: still), OrbDip.rest)
        }
    }

    func testDipDurationsMatchTheTimeline() {
        XCTAssertEqual(OrbDip.low, 0.14)
        XCTAssertEqual(OrbDip.duration, 0.42)
    }

    // MARK: Bloom

    func testBloomRisesFrom140msToItsCapAt560ms() {
        XCTAssertEqual(OnboardingBloom.alpha(at: 0, liveGrant: true, policy: full), 0)
        XCTAssertEqual(OnboardingBloom.alpha(at: 0.139, liveGrant: true, policy: full), 0)
        XCTAssertGreaterThan(OnboardingBloom.alpha(at: 0.2, liveGrant: true, policy: full), 0)
        XCTAssertEqual(OnboardingBloom.alpha(at: 0.56, liveGrant: true, policy: full), 0.16, accuracy: 1e-9)
    }

    /// It holds still while the badge shows: no pulse, ever.
    func testBloomHoldsStillUntilTheBeatChanges() {
        for seconds in [0.56, 1, 2.5, 4.5, 30] {
            XCTAssertEqual(OnboardingBloom.alpha(at: seconds, liveGrant: true, policy: full), 0.16, accuracy: 1e-9)
        }
    }

    /// "Heard, after Back" and "Granted, after Back" draw no bloom.
    func testNoBloomWhenTheGrantIsNotLive() {
        for ms in stride(from: 0, through: 2000, by: 20) {
            XCTAssertEqual(OnboardingBloom.alpha(at: Double(ms) / 1000, liveGrant: false, policy: full), 0)
        }
    }

    func testNoBloomUnderTheStillPolicy() {
        let voiceOver = OnboardingMotionPolicy.resolve(
            reduceMotion: false, lowPower: false, thermal: .nominal, voiceOver: true)
        for policy in [still, voiceOver] {
            XCTAssertEqual(OnboardingBloom.alpha(at: 1, liveGrant: true, policy: policy), 0)
        }
    }

    func testBloomHueFollowsWhoseMomentItIs() {
        XCTAssertEqual(OnboardingBloom.hue(for: .microphone, heardVoice: true), .voice)
        // A microphone grant alone gives no bloom.
        XCTAssertNil(OnboardingBloom.hue(for: .microphone, heardVoice: false))
        XCTAssertEqual(OnboardingBloom.hue(for: .accessibility, heardVoice: false), .machine)
        XCTAssertEqual(OnboardingBloom.hue(for: .openAtLogin, heardVoice: true), .machine)
        XCTAssertNil(OnboardingBloom.hue(for: .ready, heardVoice: true))
    }

    func testBloomCapSitsInsideTheGlowBand() {
        XCTAssertEqual(Theme.Notch.bloomAlpha, 0.16)
        XCTAssertTrue((0.10...0.22).contains(Theme.Notch.bloomAlpha))
    }
}

/// The policy that decides how much of onboarding moves.
final class OnboardingMotionPolicyTests: XCTestCase {
    func testNothingSetGivesTheFullVersion() {
        XCTAssertEqual(full, OnboardingMotionPolicy(layers: .full, skipsStage: false, orbIsStatic: false))
    }

    func testEachInputSelectsTheStillVersion() {
        let inputs: [OnboardingMotionPolicy] = [
            .resolve(reduceMotion: true, lowPower: false, thermal: .nominal, voiceOver: false),
            .resolve(reduceMotion: false, lowPower: true, thermal: .nominal, voiceOver: false),
            .resolve(reduceMotion: false, lowPower: false, thermal: .serious, voiceOver: false),
            .resolve(reduceMotion: false, lowPower: false, thermal: .critical, voiceOver: false),
            .resolve(reduceMotion: false, lowPower: false, thermal: .nominal, voiceOver: true),
        ]
        for policy in inputs { XCTAssertEqual(policy.layers, .still) }
        XCTAssertEqual(
            OnboardingMotionPolicy.resolve(reduceMotion: false, lowPower: false, thermal: .fair, voiceOver: false).layers,
            .full)
    }

    func testOnlyVoiceOverSkipsTheStage() {
        XCTAssertTrue(OnboardingMotionPolicy.resolve(
            reduceMotion: false, lowPower: false, thermal: .nominal, voiceOver: true).skipsStage)
        XCTAssertFalse(OnboardingMotionPolicy.resolve(
            reduceMotion: true, lowPower: true, thermal: .critical, voiceOver: false).skipsStage)
    }

    func testOnlyReduceMotionStillsTheOrb() {
        XCTAssertTrue(still.orbIsStatic)
        XCTAssertFalse(OnboardingMotionPolicy.resolve(
            reduceMotion: false, lowPower: true, thermal: .critical, voiceOver: true).orbIsStatic)
    }
}

/// Which figure the orb draws on each beat, and when a change dips.
final class OrbFigureTests: XCTestCase {
    private func figure(
        _ step: NotchOnboardingStep, prompt: Bool = false, granted: Bool, failed: Bool = false
    ) -> OrbFigure {
        OrbFigure.resolve(step: step, requestingMic: prompt, granted: granted, micCheckFailed: failed)
    }

    func testMicrophoneBeat() {
        XCTAssertEqual(figure(.microphone, prompt: true, granted: false), .working)
        XCTAssertEqual(figure(.microphone, granted: false), .thinking)
        XCTAssertEqual(figure(.microphone, granted: true), .listening)
    }

    func testAFailedMicCheckThinks() {
        XCTAssertEqual(figure(.microphone, granted: true, failed: true), .thinking)
    }

    func testTypingAndLoginListenOnlyWhenGranted() {
        for step in [NotchOnboardingStep.accessibility, .openAtLogin] {
            XCTAssertEqual(figure(step, granted: true), .listening)
            XCTAssertEqual(figure(step, granted: false), .thinking)
        }
    }

    func testReadyAndTheStageListen() {
        XCTAssertEqual(figure(.ready, granted: false), .listening)
        XCTAssertEqual(OrbFigure.stage, .listening)
    }

    /// First launch: the mic is not asked yet, so beat 1 thinks and the stage's
    /// listening figure dips into it.
    func testTheFirstLaunchOpeningDips() {
        XCTAssertTrue(OrbDip.plays(from: OrbFigure.stage, to: figure(.microphone, granted: false)))
    }

    func testAReplayWithTheMicOnDoesNotDip() {
        XCTAssertFalse(OrbDip.plays(from: OrbFigure.stage, to: figure(.microphone, granted: true)))
    }

    func testLoginOnToReadyDoesNotDip() {
        XCTAssertFalse(OrbDip.plays(from: figure(.openAtLogin, granted: true), to: figure(.ready, granted: true)))
    }
}

/// The onboarding orb's gain: never scripted, only a heard voice moves it.
final class OnboardingOrbGainTests: XCTestCase {
    func testZeroWithoutTheMicCheckAtEveryLevel() {
        for level: Float in [0, 0.01, 0.05, 0.5, 1] {
            XCTAssertEqual(OnboardingOrbGain.resolve(micCheckRunning: false, heardAt: 1, now: 5, level: level), 0)
        }
    }

    func testZeroBeforeTheLatch() {
        for level: Float in [0, 0.05, 1] {
            XCTAssertEqual(OnboardingOrbGain.resolve(micCheckRunning: true, heardAt: nil, now: 5, level: level), 0)
        }
        XCTAssertEqual(OnboardingOrbGain.resolve(micCheckRunning: true, heardAt: 6, now: 5, level: 1), 0)
    }

    func testTheFloorComesInOver280ms() {
        XCTAssertEqual(OnboardingOrbGain.resolve(micCheckRunning: true, heardAt: 10, now: 10, level: 0), 0)
        XCTAssertEqual(OnboardingOrbGain.resolve(micCheckRunning: true, heardAt: 10, now: 10.28, level: 0), 0.35, accuracy: 1e-9)
        XCTAssertEqual(OnboardingOrbGain.resolve(micCheckRunning: true, heardAt: 10, now: 60, level: 0), 0.35, accuracy: 1e-9)
    }

    /// After the floor is in, the level adds the same 1.05 × activity the pill uses.
    func testTheLevelAddsOrbViewsActivity() {
        let gain = OnboardingOrbGain.resolve(micCheckRunning: true, heardAt: 0, now: 1, level: 0.02)
        XCTAssertEqual(gain, OrbView.waveGain(level: 0.02), accuracy: 1e-9)
    }

    /// The pill keeps its own mapping, so its snapshots stay byte-identical.
    func testOrbViewWithoutAGainKeepsItsMapping() {
        XCTAssertEqual(OrbView.waveGain(level: 0), 0.35)
        XCTAssertEqual(OrbView.waveGain(level: 1), 1.4, accuracy: 1e-9)
    }
}

/// Which instant the orb draws.
final class OrbTimeTests: XCTestCase {
    func testStaticFrameWinsEvenWithATime() {
        XCTAssertEqual(OrbTime.resolve(staticFrame: true, time: 3, environmentStill: false, wall: 100, speed: 2), 0.6)
        XCTAssertEqual(OrbTime.resolve(staticFrame: true, time: nil, environmentStill: false, wall: 100, speed: 2), 0.6)
    }

    /// The snapshot renderer, `paused` and Reduce Motion each make the
    /// environment still (`ThinkingOrb` ORs them); a given time wins over that.
    func testATimeWinsOverSnapshotPausedAndReduceMotion() {
        XCTAssertEqual(OrbTime.resolve(staticFrame: false, time: 1.5, environmentStill: true, wall: 100, speed: 4), 6)
    }

    func testNoTimeInAStillEnvironmentIsTheStillFrame() {
        XCTAssertEqual(OrbTime.resolve(staticFrame: false, time: nil, environmentStill: true, wall: 100, speed: 4), 0.6)
    }

    func testOtherwiseTheWallClockTimesTheSpeed() {
        XCTAssertEqual(OrbTime.resolve(staticFrame: false, time: nil, environmentStill: false, wall: 100, speed: 4), 400)
    }

    /// The orb as the snapshot renderer draws it, as raw pixels.
    @MainActor
    private func pixels(_ orb: ThinkingOrb) throws -> Data {
        let renderer = ImageRenderer(content: orb.environment(\.isSnapshot, true))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        return try XCTUnwrap(image.dataProvider?.data) as Data
    }

    /// `ThinkingOrb` itself, not only the resolver: inside the snapshot renderer
    /// a given time draws that instant, and `staticFrame` still wins over it.
    @MainActor
    func testThinkingOrbDrawsAGivenTimeInTheSnapshotRenderer() throws {
        let still = try pixels(ThinkingOrb(state: .working, renderSize: 64))
        let atFive = try pixels(ThinkingOrb(state: .working, renderSize: 64, time: 5))
        XCTAssertNotEqual(atFive, still)
        XCTAssertEqual(atFive, try pixels(ThinkingOrb(state: .working, renderSize: 64, time: 5)))
        XCTAssertEqual(still, try pixels(ThinkingOrb(state: .working, renderSize: 64, time: 5, staticFrame: true)))
    }

    func testSnapshotTimeIsSixTenthsPlusElapsedTimesEffectiveSpeed() {
        let speed = 4.388  // the large listening preset
        let elapsed = 2.0
        XCTAssertEqual(
            OrbTime.resolve(staticFrame: false, time: 0.6 + elapsed, environmentStill: true, wall: 0, speed: speed),
            (0.6 + elapsed) * speed, accuracy: 1e-12)
    }
}
