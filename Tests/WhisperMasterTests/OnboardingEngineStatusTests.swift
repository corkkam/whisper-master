import AVFoundation
import XCTest

@testable import WhisperMaster

/// The Ready beat's two inputs: the engine and the microphone.
final class OnboardingEngineStatusTests: XCTestCase {
    private func status(
        prepared: TranscriberEngine? = nil,
        preparing: TranscriberEngine? = nil,
        failed: Bool = false,
        download: Double? = nil
    ) -> EngineStatus {
        EngineStatus.resolve(
            prepared: prepared,
            selected: .slidingWindow,
            preparing: preparing,
            phaseFailed: failed,
            download: download.map { ModelDownloadSnapshot(fractionCompleted: $0, detail: "") })
    }

    func testReadyOnlyWhenThePreparedEngineIsTheSelectedOne() {
        XCTAssertEqual(status(prepared: .slidingWindow), .ready)
        XCTAssertEqual(status(prepared: .slidingWindow, failed: true, download: 0.5), .ready)
        XCTAssertNotEqual(status(prepared: nil), .ready)
    }

    func testADownloadReportsItsPercent() {
        XCTAssertEqual(status(download: 0.42), .downloading(percent: 42))
        XCTAssertEqual(status(failed: true, download: 0.1), .downloading(percent: 10))
    }

    func testFailedOnlyWithNothingRunning() {
        XCTAssertEqual(status(failed: true), .failed)
        XCTAssertEqual(status(preparing: .slidingWindow, failed: true), .preparing)
    }

    /// A prep that has not started yet is still "preparing", never "ready".
    func testAnythingElseIsPreparing() {
        XCTAssertEqual(status(), .preparing)
        XCTAssertEqual(status(preparing: .slidingWindow), .preparing)
    }

    @MainActor
    func testReadsAppState() {
        let state = AppState()
        state.preparedEngine = nil
        state.download = ModelDownloadSnapshot(fractionCompleted: 0.5, detail: "")
        XCTAssertEqual(EngineStatus(state), .downloading(percent: 50))
        state.download = nil
        state.phase = .failed("offline")
        XCTAssertEqual(EngineStatus(state), .failed)
        state.preparedEngine = state.selectedEngine
        XCTAssertEqual(EngineStatus(state), .ready)
    }

    func testReadyMicStatusForEachAuthorization() {
        XCTAssertEqual(ReadyMicStatus(PermissionsManager.MicStatus(.notDetermined)), .notAsked)
        XCTAssertEqual(ReadyMicStatus(PermissionsManager.MicStatus(.denied)), .denied)
        XCTAssertEqual(ReadyMicStatus(PermissionsManager.MicStatus(.restricted)), .denied)
        XCTAssertEqual(ReadyMicStatus(PermissionsManager.MicStatus(.authorized)), .on)
    }
}
