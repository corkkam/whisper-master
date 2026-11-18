import XCTest

@testable import WhisperMaster

@MainActor
private final class FakePermissions: PermissionsProviding {
    var mic: PermissionsManager.MicStatus = .notDetermined

    func microphoneStatus() -> PermissionsManager.MicStatus { mic }
    func requestMicrophone() async -> Bool { false }
    func accessibilityGranted() -> Bool { false }
    func promptAccessibility() {}
    func openAccessibilitySettings() {}
    func openMicrophoneSettings() {}
}

private final class FakeCapture: MicCheckCapturing {
    private(set) var starts = 0
    private(set) var stops = 0

    func start(
        bufferHandler: @escaping MicrophoneCaptureService.BufferHandler,
        levelHandler: @escaping MicrophoneCaptureService.LevelHandler
    ) throws { starts += 1 }

    func stop() { stops += 1 }
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

    private func makeModel() -> NotchOnboardingModel {
        NotchOnboardingModel(
            permissions: permissions,
            capture: capture,
            engineStatus: { [unowned self] in self.engine },
            onComplete: { [unowned self] in self.finishes.append($0) },
            onDismiss: { [unowned self] in self.dismissals += 1 },
            onRetryEngine: { [unowned self] in self.retries += 1 })
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

    /// The Ready beat's microphone state follows the permission on each refresh,
    /// and no mic check starts while the microphone is off.
    func testRefreshReadsTheMicrophoneStatus() {
        let model = makeModel()
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
        model.refresh()
        model.refresh()
        XCTAssertEqual(model.readyMicStatus, .on)
        XCTAssertEqual(capture.starts, 1)
        XCTAssertEqual(capture.stops, 0)
        model.finish(.handBack)
        XCTAssertEqual(capture.stops, 1)
    }
}
