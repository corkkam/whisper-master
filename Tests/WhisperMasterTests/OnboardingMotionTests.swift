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

    /// Bytes that differ between two renders. `ImageRenderer` drifts by a few
    /// antialiasing bytes from one render to the next whatever it draws (17 of
    /// 16,384 measured), so "the same frame" means fewer than `sameFrame`.
    private func differingBytes(_ a: Data, _ b: Data) -> Int {
        guard a.count == b.count else { return max(a.count, b.count) }
        return zip(a, b).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) }
    }

    private let sameFrame = 160

    /// `ThinkingOrb` itself, not only the resolver: inside the snapshot renderer
    /// a given time draws that instant, and `staticFrame` still wins over it.
    @MainActor
    func testThinkingOrbDrawsAGivenTimeInTheSnapshotRenderer() throws {
        let still = try pixels(ThinkingOrb(state: .working, renderSize: 64))
        let atFive = try pixels(ThinkingOrb(state: .working, renderSize: 64, time: 5))
        XCTAssertGreaterThan(differingBytes(atFive, still), 10 * sameFrame)
        XCTAssertLessThan(differingBytes(atFive, try pixels(ThinkingOrb(state: .working, renderSize: 64, time: 5))), sameFrame)
        let pinned = try pixels(ThinkingOrb(state: .working, renderSize: 64, time: 5, staticFrame: true))
        XCTAssertLessThan(differingBytes(still, pinned), sameFrame)
    }

    func testSnapshotTimeIsSixTenthsPlusElapsedTimesEffectiveSpeed() {
        let speed = 4.388  // the large listening preset
        let elapsed = 2.0
        XCTAssertEqual(
            OrbTime.resolve(staticFrame: false, time: 0.6 + elapsed, environmentStill: true, wall: 0, speed: speed),
            (0.6 + elapsed) * speed, accuracy: 1e-12)
    }
}

/// The opening, reveal, beat change, flourish and outro as pure functions of
/// time, against the §2 timeline.
final class OnboardingTimelineTests: XCTestCase {
    private let layout = NotchOnboardingLayout()
    private let notch = NotchGeometry(notchWidth: 208, notchHeight: 37.5, screenWidth: 1710)
    private var g: OpeningTimeline.Geometry { OpeningTimeline.Geometry(notch, layout: layout) }

    private func assertFrame(
        _ a: OpeningTimeline.Frame, _ b: OpeningTimeline.Frame, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(a.width, b.width, accuracy: 1e-6, "width", file: file, line: line)
        XCTAssertEqual(a.depth, b.depth, accuracy: 1e-6, "depth", file: file, line: line)
        XCTAssertEqual(a.bottomRadius, b.bottomRadius, accuracy: 1e-6, "radius", file: file, line: line)
        XCTAssertEqual(a.orbDiameter, b.orbDiameter, accuracy: 1e-6, "orb diameter", file: file, line: line)
        XCTAssertEqual(a.orbCenterY, b.orbCenterY, accuracy: 1e-6, "orb centre", file: file, line: line)
        XCTAssertEqual(a.orbGather, b.orbGather, accuracy: 1e-6, "gather", file: file, line: line)
        XCTAssertEqual(a.wordmark.opacity, b.wordmark.opacity, accuracy: 1e-6, "wordmark", file: file, line: line)
        XCTAssertEqual(a.tagline.opacity, b.tagline.opacity, accuracy: 1e-6, "tagline", file: file, line: line)
        XCTAssertEqual(a.opacity, b.opacity, accuracy: 1e-6, "opacity", file: file, line: line)
    }

    func testTheOpeningStartsAsTheNotch() {
        let start = OpeningTimeline.frame(at: 0, g, layout: layout, policy: full)
        XCTAssertEqual(start.width, 208)
        XCTAssertEqual(start.depth, 0)
        XCTAssertEqual(start.orbGather, 0)
        XCTAssertEqual(start.wordmark.opacity, 0)
    }

    /// The stage at the swap is the band at rest, so nothing moves when the
    /// panels change places: width, depth, radius 24, flare 14, the orb's centre
    /// and size, and its figure, gain, gather, opacity and scale.
    func testTheSwapFrameIsTheBandAtRest() {
        let swap = OpeningTimeline.frame(at: OpeningTimeline.swapAt, g, layout: layout, policy: full)
        XCTAssertEqual(swap.width, layout.surfaceWidth(for: notch), accuracy: 1e-6)
        XCTAssertEqual(swap.depth, layout.thickness, accuracy: 1e-6)
        XCTAssertEqual(swap.bottomRadius, 24, accuracy: 1e-6)
        XCTAssertEqual(layout.topConcaveRadius, 14)
        XCTAssertEqual(swap.orbCenterY, layout.orbCenterY, accuracy: 1e-6)
        XCTAssertEqual(swap.orbDiameter, 62, accuracy: 1e-6)
        assertFrame(swap, OpeningTimeline.swapFrame(g, layout: layout))
        // The band orb at the swap: the stage figure, no gain, no dip yet.
        XCTAssertEqual(OrbFigure.stage, .listening)
        XCTAssertEqual(OnboardingOrbGain.resolve(micCheckRunning: false, heardAt: nil, now: 3.56, level: 0), 0)
        let dip = OrbDip.frame(at: -BandReveal.dipAt, policy: full)
        XCTAssertEqual(dip.opacity, 1)
        XCTAssertEqual(dip.scale, 1)
        XCTAssertFalse(dip.figureIsNew)
        XCTAssertEqual(BandReveal.frame(at: 0, gathers: false, policy: full).orbGather, 1)
    }

    func testTheOpeningTimesMatchTheTimeline() {
        XCTAssertEqual(OpeningTimeline.swapAt + BandReveal.dipAt, OpeningTimeline.dipAt, accuracy: 1e-9)
        XCTAssertEqual(OpeningTimeline.swapAt + BandReveal.opensAt, OpeningTimeline.end, accuracy: 1e-9)
        XCTAssertEqual(OpeningTimeline.foldAt + OpeningTimeline.foldDuration, OpeningTimeline.swapAt, accuracy: 1e-9)
        XCTAssertEqual(OpeningTimeline.swapAt + OpeningTimeline.stageOutDelay, 3.6, accuracy: 1e-9)
        XCTAssertEqual(OpeningTimeline.watchdog, 5)
        XCTAssertEqual(OpeningTimeline.stillSwapAt, 2.2)
        XCTAssertEqual(BeatTransition.duration(policy: full), 0.7, accuracy: 1e-9)
        XCTAssertEqual(Outro.end, 0.4)
        XCTAssertEqual(Flourish.duration, 0.56, accuracy: 1e-9)
    }

    /// The words hold long enough to read, then leave before the fold.
    func testTheWordsHoldThenLeave() {
        let hold = OpeningTimeline.frame(at: 2.0, g, layout: layout, policy: full)
        XCTAssertEqual(hold.wordmark.opacity, 1, accuracy: 1e-9)
        XCTAssertEqual(hold.tagline.opacity, 1, accuracy: 1e-9)
        XCTAssertEqual(hold.orbDiameter, 150)
        XCTAssertEqual(hold.width, 640)
        XCTAssertEqual(hold.depth, 420)
        let gone = OpeningTimeline.frame(at: 2.95, g, layout: layout, policy: full)
        XCTAssertEqual(gone.wordmark.opacity, 0, accuracy: 1e-9)
        XCTAssertEqual(gone.tagline.opacity, 0, accuracy: 1e-9)
    }

    /// A skip blends to the swap frame in 250 ms; the band's dip then ends by
    /// skip + 710 ms.
    func testASkipReachesTheSwapFrameAt250ms() {
        let from = OpeningTimeline.frame(at: 1.24, g, layout: layout, policy: full)
        assertFrame(OpeningTimeline.skipFrame(at: 0, from: from, g, layout: layout), from)
        assertFrame(
            OpeningTimeline.skipFrame(at: OpeningTimeline.skipBlend, from: from, g, layout: layout),
            OpeningTimeline.swapFrame(g, layout: layout))
        let dipEnds = OpeningTimeline.skipBlend + BandReveal.dipAt + OrbDip.duration
        XCTAssertEqual(dipEnds, 0.71, accuracy: 1e-9)
        XCTAssertEqual(OpeningTimeline.skipBlend + BandReveal.opensAt, 0.79, accuracy: 1e-9)
    }

    /// The still version holds one frame, swaps at 2,200 ms and never dips.
    func testTheStillOpeningIsOneFrame() {
        let hold = OpeningTimeline.frame(at: 1, g, layout: layout, policy: still)
        for t in stride(from: 0.2, through: 2.2, by: 0.1) {
            assertFrame(OpeningTimeline.frame(at: t, g, layout: layout, policy: still), hold)
        }
        XCTAssertEqual(OpeningTimeline.frame(at: 0, g, layout: layout, policy: still).opacity, 0)
        XCTAssertEqual(OpeningTimeline.frame(at: 2.4, g, layout: layout, policy: still).opacity, 0, accuracy: 1e-9)
        XCTAssertEqual(OrbDip.frame(at: 0.14, policy: still), OrbDip.rest)
    }

    /// With no stage the orb gathers from 0 to 1 over 540 ms; the reveal ends at rest.
    func testTheRevealWithNoStageGathersOver540ms() {
        XCTAssertEqual(BandReveal.frame(at: 0, gathers: true, policy: full).orbGather, 0)
        XCTAssertEqual(BandReveal.frame(at: 0.54, gathers: true, policy: full).orbGather, 1)
        XCTAssertEqual(BandReveal.frame(at: 0, gathers: true, policy: full).rowCap, 0.5)
        XCTAssertEqual(BandReveal.frame(at: 0.8, gathers: true, policy: full), .rest)
        XCTAssertEqual(BandReveal.frame(at: 0.5, gathers: true, policy: still), .rest)
    }

    /// The row draws at half opacity until input opens: 540 ms into a reveal,
    /// 500 ms after a step change, 300 ms after a row change.
    func testTheRowIsCappedUntilInputOpens() {
        XCTAssertEqual(BandReveal.frame(at: 0.53, gathers: false, policy: full).rowCap, 0.5)
        XCTAssertEqual(BeatTransition.frame(at: 0.49, policy: full).rowCap, 0.5)
        XCTAssertEqual(Flourish.frame(at: 0.29, policy: full).rowCap, 0.5)
        XCTAssertEqual(BeatTransition.frame(at: 0.75, policy: full).rowCap, 1)
        XCTAssertEqual(Flourish.frame(at: 0.55, policy: full).rowCap, 1)
        XCTAssertEqual(BeatTransition.frame(at: 0.29, policy: still).rowCap, 0.5)
        XCTAssertEqual(BeatTransition.frame(at: 0.55, policy: still).rowCap, 1)
    }

    func testABeatChangeEndsAtRestAndBackMirrorsForward() {
        let end = BeatTransition.frame(at: 0.7, policy: full)
        XCTAssertEqual(end.outgoing.opacity, 0)
        XCTAssertEqual(end.headline, .rest)
        XCTAssertEqual(end.body, .rest)
        XCTAssertEqual(end.actions, .rest)
        XCTAssertEqual(end.bead, 1)
        for ms in stride(from: 0, through: 700, by: 10) {
            let t = Double(ms) / 1000
            let forward = BeatTransition.frame(at: t, policy: full)
            let back = BeatTransition.frame(at: t, backward: true, policy: full)
            XCTAssertEqual(back.outgoing.x, -forward.outgoing.x, accuracy: 1e-9)
            XCTAssertEqual(back.headline.x, -forward.headline.x, accuracy: 1e-9)
            XCTAssertEqual(back.headline.opacity, forward.headline.opacity, accuracy: 1e-9)
        }
        XCTAssertEqual(BeatTransition.frame(at: 0, policy: full).outgoing.opacity, 1)
        XCTAssertEqual(BeatTransition.frame(at: 0.12, policy: full).headline.opacity, 0)
        XCTAssertEqual(BeatTransition.frame(at: 0.2, policy: full).outgoing.opacity, 0)
    }

    /// A grant draws its ring over 360 ms and its glyph from 200 ms; the still
    /// version shows the badge whole.
    func testAGrantDrawsItsRingThenItsGlyph() {
        XCTAssertEqual(Flourish.frame(at: 0, policy: full).ring, 0)
        XCTAssertEqual(Flourish.frame(at: 0.2, policy: full).glyph, 0)
        XCTAssertEqual(Flourish.frame(at: 0.36, policy: full).ring, 1)
        XCTAssertEqual(Flourish.frame(at: 0.45, policy: full).glyph, 1)
        XCTAssertEqual(Flourish.frame(at: 0.12, policy: full).newRow, 1)
        XCTAssertEqual(Flourish.frame(at: 0.2, policy: full).oldCopy, 0)
        let whole = Flourish.frame(at: 0, policy: still)
        XCTAssertEqual(whole.ring, 1)
        XCTAssertEqual(whole.glyph, 1)
        XCTAssertEqual(whole.newCopy, 1)
    }

    /// The outro fades the content by 150 ms and folds by 400 ms while the orb
    /// gathers in. The orb is resized, never scaled; the still version is a cut.
    func testTheOutroFoldsIntoTheNotch() {
        let start = Outro.frame(at: 0)
        XCTAssertEqual(start.content, 1)
        XCTAssertEqual(start.fold, 0)
        XCTAssertEqual(start.orbGather, 1)
        XCTAssertEqual(Outro.frame(at: 0.15).content, 0)
        XCTAssertEqual(Outro.frame(at: 0.1).fold, 0)
        let end = Outro.frame(at: Outro.end)
        XCTAssertEqual(end.fold, 1)
        XCTAssertEqual(end.orbGather, 0)
        XCTAssertEqual(Outro.duration(policy: still), 0)
        XCTAssertEqual(Outro.duration(policy: full), 0.4)
    }

    /// Every channel stays finite and inside its range, over and past each cue.
    func testEveryFrameIsClampedAndFinite() {
        for ms in stride(from: -200, through: 5_500, by: 20) {
            let t = Double(ms) / 1000
            for policy in [full, still] {
                let o = OpeningTimeline.frame(at: t, g, layout: layout, policy: policy)
                for v in [o.width, o.depth, o.bottomRadius, o.orbDiameter, o.orbCenterY] {
                    XCTAssertTrue(v.isFinite && v >= 0, "opening at \(ms) ms")
                }
                XCTAssertTrue((0...1).contains(o.orbGather) && (0...1).contains(o.opacity), "opening at \(ms) ms")
                let r = BandReveal.frame(at: t, gathers: true, policy: policy)
                XCTAssertTrue((0.5...1).contains(r.rowCap) && (0...1).contains(r.orbGather), "reveal at \(ms) ms")
                let b = BeatTransition.frame(at: t, policy: policy)
                XCTAssertTrue((0...1).contains(b.bead) && (0...1).contains(b.outgoing.opacity), "beat at \(ms) ms")
                let f = Flourish.frame(at: t, policy: policy)
                XCTAssertTrue([f.oldCopy, f.newCopy, f.oldRow, f.newRow, f.ring, f.glyph].allSatisfy { (0...1).contains($0) })
            }
            let out = Outro.frame(at: t)
            XCTAssertTrue([out.content, out.fold, out.orbGather].allSatisfy { (0...1).contains($0) }, "outro at \(ms) ms")
        }
    }

    /// The stage keeps a 28 pt margin on a narrow display, and is 640 wide otherwise.
    func testTheStagePanelSize() {
        XCTAssertEqual(layout.stagePanelSize(for: notch), CGSize(width: 640, height: 37.5 + 420))
        let narrow = NotchGeometry(notchWidth: 0, notchHeight: 0, screenWidth: 600)
        XCTAssertEqual(layout.stagePanelSize(for: narrow).width, 544)
        XCTAssertEqual(OpeningTimeline.Geometry(narrow, layout: layout).startWidth, layout.fallbackBodyWidth)
    }
}
