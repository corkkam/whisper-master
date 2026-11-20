import AppKit

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
    /// The Sound pane, where the input device and its level are.
    func openSoundSettings()
}

extension PermissionsManager: PermissionsProviding {}

/// What the onboarding model asks of the app and the system, so tests can say
/// whether the app is active, catch an announcement, and run the waits fast.
/// The time itself is `OnboardingClock`, in system uptime.
@MainActor
struct OnboardingEnvironment {
    /// Whether our app is active. The band takes the keyboard only then.
    var isActive: () -> Bool
    /// Brings our app forward, after a press that asked for the microphone.
    var activate: () -> Void
    /// A VoiceOver announcement.
    var announce: (String) -> Void
    /// The app in front, to tell when the user leaves System Settings.
    var frontmostBundleID: () -> String?
    /// Waits before a delayed task runs.
    var sleep: (TimeInterval) async -> Void

    static let live = OnboardingEnvironment(
        isActive: { NSApplication.shared.isActive },
        activate: { NSApplication.shared.activate(ignoringOtherApps: true) },
        announce: { text in
            NSAccessibility.post(
                element: NSApplication.shared, notification: .announcementRequested,
                userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        },
        frontmostBundleID: { NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
        sleep: { try? await Task.sleep(for: .seconds($0)) })
}

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
