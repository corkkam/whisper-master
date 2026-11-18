import Foundation

/// The microphone and Accessibility calls the onboarding model makes, so tests
/// can drive the flow without the real TCC state. `PermissionsManager` is the
/// live one.
@MainActor
protocol PermissionsProviding {
    func microphoneStatus() -> PermissionsManager.MicStatus
    func requestMicrophone() async -> Bool
    func accessibilityGranted() -> Bool
    func promptAccessibility()
    func openAccessibilitySettings()
    func openMicrophoneSettings()
}

extension PermissionsManager: PermissionsProviding {}

/// The onboarding mic check's capture session. The live one is the model's own
/// `MicrophoneCaptureService`, never the dictation view model's: each owns an
/// `AVAudioEngine`. A fake lets tests run the mic beat with no audio hardware.
protocol MicCheckCapturing {
    func start(
        bufferHandler: @escaping MicrophoneCaptureService.BufferHandler,
        levelHandler: @escaping MicrophoneCaptureService.LevelHandler
    ) throws
    func stop()
}

extension MicrophoneCaptureService: MicCheckCapturing {}
