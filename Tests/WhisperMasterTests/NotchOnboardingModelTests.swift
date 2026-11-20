import XCTest

@testable import WhisperMaster

private let full = OnboardingMotionPolicy.resolve(reduceMotion: false, lowPower: false, thermal: .nominal, voiceOver: false)

@MainActor
final class FakePermissions: PermissionsProviding {
    var mic: PermissionsManager.MicStatus = .notDetermined
    var trusted = false
    /// Hold the microphone request open, as the system prompt does, until the test answers.
    var holdsRequest = false
    private var pendingRequest: CheckedContinuation<Bool, Never>?
    private(set) var micRequests = 0
    private(set) var accessibilityPrompts = 0
    private(set) var accessibilityPaneOpens = 0
    private(set) var microphonePaneOpens = 0
    private(set) var soundPaneOpens = 0

    func microphoneStatus() -> PermissionsManager.MicStatus { mic }
    func requestMicrophone() async -> Bool {
        micRequests += 1
        guard holdsRequest else { return false }
        return await withCheckedContinuation { pendingRequest = $0 }
    }
    func answerRequest(_ granted: Bool) {
        pendingRequest?.resume(returning: granted)
        pendingRequest = nil
    }
    func accessibilityGranted() -> Bool { trusted }
    func promptAccessibility() { accessibilityPrompts += 1 }
    func openAccessibilitySettings() { accessibilityPaneOpens += 1 }
    func openMicrophoneSettings() { microphonePaneOpens += 1 }
    func openSoundSettings() { soundPaneOpens += 1 }
}

final class FakeCapture: MicCheckCapturing {
    struct Unavailable: Error {}

    private(set) var starts = 0
    private(set) var stops = 0
    var fails = false
    private(set) var levelHandler: MicrophoneCaptureService.LevelHandler?

    func start(
        bufferHandler: @escaping MicrophoneCaptureService.BufferHandler,
        levelHandler: @escaping MicrophoneCaptureService.LevelHandler
    ) throws {
        starts += 1
        if fails { throw Unavailable() }
        self.levelHandler = levelHandler
    }

    func stop() { stops += 1 }
}

/// The app and system around the model: whether the app is active, the app in
/// front, and the announcements. `speed` runs every wait that many times faster.
@MainActor
final class FakeEnvironment {
    var active = true
    var front: String? = "com.apple.finder"
    private(set) var announcements: [String] = []
    private(set) var activations = 0
    let speed: Double

    init(speed: Double = 1) {
        self.speed = speed
    }

    var environment: OnboardingEnvironment {
        let speed = speed
        return OnboardingEnvironment(
            isActive: { [unowned self] in self.active },
            activate: { [unowned self] in self.activations += 1 },
            announce: { [unowned self] in self.announcements.append($0) },
            frontmostBundleID: { [unowned self] in self.front },
            sleep: { seconds in try? await Task.sleep(for: .seconds(seconds / speed)) })
    }
}

/// The model's finish API and its microphone state, with fake seams so no test
/// touches TCC or audio.
@MainActor
final class NotchOnboardingModelTests: XCTestCase {
    private var finishes: [OnboardingFinish] = []
    private var dismissals = 0
    private var retries = 0
    private var engine: EngineStatus = .ready
    /// Lazy so it is made on the main actor, inside a test.
    private lazy var permissions = FakePermissions()
    private let capture = FakeCapture()
    private lazy var environment = FakeEnvironment()
    /// Added to system uptime. The clock runs in real time, because these tests
    /// wait in real time for the model's delayed tasks; a test moves it ahead to
    /// let a press pass the input gate.
    private var offset: TimeInterval = 0

    private func makeModel() -> NotchOnboardingModel {
        NotchOnboardingModel(
            permissions: permissions,
            capture: capture,
            clock: OnboardingClock(
                now: { [unowned self] in ProcessInfo.processInfo.systemUptime + self.offset }, isFixed: false),
            engineStatus: { [unowned self] in self.engine },
            onComplete: { [unowned self] in self.finishes.append($0) },
            onDismiss: { [unowned self] in self.dismissals += 1 },
            onRetryEngine: { [unowned self] in self.retries += 1 },
            environment: environment.environment)
    }

    /// No mic check ran, so finishing has nothing to release.
    private func assertNoMicCheck(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(capture.starts, 0, file: file, line: line)
        XCTAssertEqual(capture.stops, 0, file: file, line: line)
    }

    func testDoneFinishesWithHandBackOnce() {
        let model = makeModel()
        model.finish(.handBack)
        model.finish(.handBack)
        model.finish(.openSettings)
        model.dismiss()
        XCTAssertEqual(finishes, [.handBack])
        XCTAssertEqual(dismissals, 0)
        assertNoMicCheck()
    }

    func testCloseAndOpenSettingsFinishesWithOpenSettings() {
        let model = makeModel()
        model.finish(.openSettings)
        XCTAssertEqual(finishes, [.openSettings])
        assertNoMicCheck()
    }

    func testHandOffFinishesWithHandBackAtOnce() {
        let model = makeModel()
        model.handOff()
        XCTAssertEqual(finishes, [.handBack])
        model.handOff()
        XCTAssertEqual(finishes, [.handBack])
        assertNoMicCheck()
    }

    func testAdvancingPastReadyHandsBack() {
        let model = makeModel()
        for _ in NotchOnboardingStep.allCases { model.advance() }
        XCTAssertEqual(finishes, [.handBack])
        assertNoMicCheck()
    }

    func testCloseIsNotAFinish() {
        let model = makeModel()
        model.dismiss()
        model.finish(.handBack)
        XCTAssertEqual(dismissals, 1)
        XCTAssertEqual(finishes, [])
        assertNoMicCheck()
    }

    func testTheEngineSeamIsReadLive() {
        let model = makeModel()
        XCTAssertEqual(model.engineStatus(), .ready)
        engine = .downloading(percent: 7)
        XCTAssertEqual(model.engineStatus(), .downloading(percent: 7))
    }

    func testRetryEngineIsPassedThrough() {
        let model = makeModel()
        model.onRetryEngine?()
        XCTAssertEqual(retries, 1)
    }

    /// The band is live from `begin` to `teardown`; a closed window reads nothing.
    private func makeLiveModel() -> NotchOnboardingModel {
        let model = makeModel()
        model.begin(.reveal, policy: full)
        model.introDidEnd()
        offset += BandReveal.opensAt
        return model
    }

    /// The Ready beat's microphone state follows the permission on each refresh,
    /// and no mic check starts while the microphone is off.
    func testRefreshReadsTheMicrophoneStatus() {
        let model = makeLiveModel()
        model.refresh()
        XCTAssertEqual(model.readyMicStatus, .notAsked)
        permissions.mic = .denied
        model.refresh()
        XCTAssertEqual(model.readyMicStatus, .denied)
        XCTAssertTrue(model.micDenied)
        assertNoMicCheck()
    }

    /// The mic check starts once on the microphone beat and is released when
    /// setup finishes.
    func testTheMicCheckStartsOnceAndStopsOnFinish() {
        permissions.mic = .granted
        let model = makeModel()
        model.begin(.reveal, policy: full)
        // Nothing listens until input opens.
        XCTAssertEqual(capture.starts, 0)
        model.introDidEnd()
        model.refresh()
        XCTAssertEqual(model.readyMicStatus, .on)
        XCTAssertEqual(capture.starts, 1)
        XCTAssertEqual(capture.stops, 0)
        model.finish(.handBack)
        XCTAssertEqual(capture.stops, 1)
    }

    // MARK: Lifecycle and motion

    /// Waits on the real clock, for the model's delayed tasks.
    private func wait(_ seconds: TimeInterval) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    /// A closed window does nothing: refresh reads no permission and starts no check.
    func testAModelThatIsNotLiveReadsNothing() {
        permissions.mic = .granted
        let model = makeModel()
        model.refresh()
        XCTAssertEqual(model.readyMicStatus, .notAsked)
        let live = makeLiveModel()
        live.teardown()
        live.refresh()
        XCTAssertEqual(capture.starts, 1)
        XCTAssertEqual(capture.stops, 1)
    }

    /// Done folds the band first, then completes once. A second tap in the outro
    /// is ignored.
    func testDoneCompletesOnceAfterTheOutro() async {
        let model = makeLiveModel()
        model.finish(.handBack)
        model.finish(.handBack)
        XCTAssertEqual(finishes, [])
        XCTAssertNotNil(model.outroStartedAt)
        await wait(Outro.end + 0.3)
        XCTAssertEqual(finishes, [.handBack])
    }

    /// The capture key's hand-off is a cut, even with the band on screen.
    func testHandOffIsACutWhileTheBandIsUp() {
        let model = makeLiveModel()
        model.handOff()
        XCTAssertEqual(finishes, [.handBack])
        XCTAssertNil(model.outroStartedAt)
    }

    /// After teardown, the reveal's delayed tasks stand down: input never opens.
    func testStaleTasksDoNothing() async {
        permissions.mic = .granted
        let model = makeModel()
        model.begin(.reveal, policy: full)
        model.teardown()
        await wait(BandReveal.duration(policy: full) + 0.3)
        XCTAssertTrue(model.introPlaying)
        XCTAssertNotNil(model.revealStartedAt)
        XCTAssertEqual(capture.starts, 0)
    }

    /// With no stage (no screen for it) the band reveals at once and gathers the
    /// orb; input opens 540 ms in.
    func testWithNoStageTheBandRevealsAtOnce() async {
        let model = makeModel()
        var cues: [OnboardingStageCue] = []
        model.onStageCue = { cues.append($0) }
        model.begin(.reveal, policy: full)
        XCTAssertNotNil(model.revealStartedAt)
        XCTAssertTrue(model.revealGathers)
        XCTAssertNil(model.dip)
        XCTAssertTrue(model.introPlaying)
        await wait(BandReveal.opensAt + 0.3)
        XCTAssertFalse(model.introPlaying)
        XCTAssertEqual(cues, [])
    }

    /// A click on the stage primes the band, swaps after the 250 ms blend, and
    /// the stage leaves. The band orb starts on the stage figure and dips to the
    /// beat-1 figure; nothing listens until input opens.
    func testASkipSwapsToTheBandAfterTheBlend() async {
        let model = makeModel()
        var cues: [OnboardingStageCue] = []
        model.onStageCue = { cues.append($0) }
        model.begin(.stage, policy: full)
        XCTAssertNil(model.revealStartedAt)
        model.skipOpening()
        model.skipOpening()
        XCTAssertEqual(cues, [.primeBand])
        await wait(OpeningTimeline.skipBlend + 0.25)
        XCTAssertEqual(cues, [.primeBand, .swap, .end])
        XCTAssertFalse(model.revealGathers)
        XCTAssertEqual(model.dip?.from, OrbFigure.stage)
        XCTAssertTrue(model.introPlaying)
        await wait(BandReveal.opensAt)
        XCTAssertFalse(model.introPlaying)
    }

    /// Under VoiceOver there is no stage, even on the launch path.
    func testVoiceOverSkipsTheStage() {
        let model = makeModel()
        let voiceOver = OnboardingMotionPolicy.resolve(
            reduceMotion: false, lowPower: false, thermal: .nominal, voiceOver: true)
        model.begin(.stage, policy: voiceOver)
        XCTAssertNil(model.openingStartedAt)
        XCTAssertNotNil(model.revealStartedAt)
        XCTAssertFalse(model.revealGathers)
    }

    /// A step change is a beat transition; a live grant inside a beat is a
    /// flourish with a held bloom, which falls at the next beat change.
    func testAGrantRaisesAHeldBloomThatFallsAtTheBeatChange() {
        let model = makeLiveModel()
        model.advance()
        XCTAssertEqual(model.beatChange?.previous, .micAsk)
        XCTAssertEqual(model.bandState, .typingAsk)
        permissions.trusted = true
        model.refresh()
        XCTAssertEqual(model.rowChange?.previous, .typingAsk)
        XCTAssertEqual(model.rowChange?.grant, true)
        XCTAssertEqual(model.heldBloom, .machine)
        // Thinking to listening: the orb dips.
        XCTAssertEqual(model.dip?.from, .thinking)
        model.advance()
        XCTAssertNil(model.heldBloom)
        XCTAssertEqual(model.beatChange?.heldBloom, .machine)
    }

    /// The still version raises no bloom.
    func testNoBloomUnderTheStillVersion() {
        let still = OnboardingMotionPolicy.resolve(
            reduceMotion: true, lowPower: false, thermal: .nominal, voiceOver: false)
        let model = makeModel()
        model.begin(.reveal, policy: still)
        model.introDidEnd()
        model.advance()
        permissions.trusted = true
        model.refresh()
        XCTAssertEqual(model.rowChange?.grant, true)
        XCTAssertNil(model.heldBloom)
    }

    /// A window closed after its stage swapped (a sign-out, or a finish) and
    /// shown again, on the launch path or as a replay from About or the tray,
    /// plays a fresh opening, and the band swaps in again.
    func testASecondBeginAfterTeardownSwapsTheBandIn() async {
        let model = makeModel()
        var cues: [OnboardingStageCue] = []
        model.onStageCue = { cues.append($0) }
        model.begin(.stage, policy: full)
        model.skipOpening()
        await wait(OpeningTimeline.skipBlend + 0.25)
        XCTAssertEqual(cues, [.primeBand, .swap, .end])
        model.teardown()

        cues = []
        model.begin(.stage, policy: full)
        XCTAssertTrue(model.introPlaying)
        XCTAssertNil(model.revealStartedAt)
        XCTAssertNil(model.openingSkip)
        model.skipOpening()
        await wait(OpeningTimeline.skipBlend + 0.25)
        XCTAssertEqual(cues, [.primeBand, .swap, .end])
        await wait(BandReveal.opensAt)
        XCTAssertFalse(model.introPlaying)
    }

    /// Try Again on the microphone beat starts the mic check over through the
    /// capture seam. It never reaches the login-item call.
    func testTryAgainOnTheMicrophoneBeatRetriesTheMicCheck() {
        permissions.mic = .granted
        let model = makeLiveModel()
        XCTAssertEqual(capture.starts, 1)
        model.perform(.tryAgain)
        XCTAssertEqual(capture.stops, 1)
        XCTAssertEqual(capture.starts, 2)
        XCTAssertEqual(model.step, .microphone)
    }

    /// Try Again on Ready runs the engine retry, and only that.
    func testTryAgainOnReadyRetriesTheEngine() {
        let model = makeLiveModel()
        for _ in 0..<3 { model.advance() }
        XCTAssertEqual(model.step, .ready)
        // A step change closes input for 500 ms.
        offset += BeatTransition.opensAt
        model.perform(.tryAgain)
        XCTAssertEqual(retries, 1)
    }

    /// With every timestamp cleared, nothing runs: the band draws its rest frame.
    func testWithNoTimestampsTheTimelineRests() {
        XCTAssertEqual(makeModel().activeUntil, -.infinity)
    }
}
