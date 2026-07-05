import AppKit
import SwiftUI

/// The first-run wizard container: brand chrome, the segmented progress bar, the
/// per-step content, and the footer. Owns step state, permission polling, and
/// navigation; the individual pages are dumb views fed from here.
struct OnboardingView: View {
    let state: AppState
    let permissions: PermissionsManager
    let microphoneCapture: MicrophoneCaptureService
    let retryEngine: () -> Void
    let onClose: () -> Void
    let onComplete: () -> Void

    init(
        state: AppState,
        permissions: PermissionsManager,
        microphoneCapture: MicrophoneCaptureService,
        retryEngine: @escaping () -> Void,
        onClose: @escaping () -> Void,
        onComplete: @escaping () -> Void,
        initialStep: OnboardingStep = .welcome
    ) {
        self.state = state
        self.permissions = permissions
        self.microphoneCapture = microphoneCapture
        self.retryEngine = retryEngine
        self.onClose = onClose
        self.onComplete = onComplete
        _step = State(initialValue: initialStep)
    }

    @State private var step: OnboardingStep
    @State private var micGranted = false
    @State private var micDenied = false
    @State private var requestingMic = false
    @State private var accessibilityGranted = false
    @State private var notifGranted = false
    @State private var notifDenied = false
    @State private var requestingNotif = false
    @State private var testLevel: Float = 0
    @State private var testRunning = false
    @State private var testHeardSound = false

    var body: some View {
        ZStack {
            Theme.canvasGradient.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, 28)
                    .padding(.top, 18)

                OnboardingProgressBar(step: step)
                    .padding(.horizontal, 32)
                    .padding(.top, 20)
                    .padding(.bottom, 24)

                stepContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 32)

                footer
                    .padding(.horizontal, 32)
                    .padding(.vertical, 22)
            }
        }
        .frame(width: 640, height: 600)
        .onAppear(perform: refresh)
        .onReceive(Timer.publish(every: 0.75, on: .main, in: .common).autoconnect()) { _ in
            refresh()
        }
        .onChange(of: micGranted) { _, granted in
            if granted, step == .microphone { advance() }
        }
        .onChange(of: accessibilityGranted) { _, granted in
            if granted, step == .accessibility { advance() }
        }
        .onChange(of: notifGranted) { _, granted in
            if granted, step == .notifications { advance() }
        }
    }

    private var topBar: some View {
        HStack(spacing: 11) {
            BrandLogo(size: 30, cornerRadius: 8)
            Text("Whisper Master")
                .font(Typography.sans(14, .bold))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Theme.surface))
                    .overlay(Circle().strokeBorder(Theme.stroke, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Close — you can reopen this later from the menu bar")
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .welcome:
            WelcomePage()
        case .microphone:
            microphonePage
        case .accessibility:
            accessibilityPage
        case .notifications:
            notificationsPage
        case .micTest:
            MicTestPage(
                micGranted: micGranted,
                level: testLevel,
                running: testRunning,
                heardSound: testHeardSound,
                onStart: startMicTest,
                onStop: stopMicTest
            )
        case .smartCleanup:
            SmartCleanupPage(enabled: state.llmCleanupEnabled, onEnable: enableSmartCleanup)
        case .done:
            DonePage(state: state, retryEngine: retryEngine)
        }
    }

    /// Opt into smart cleanup: flip the toggle (starts the background download
    /// via the refresh-loop reconcile) and move on.
    private func enableSmartCleanup() {
        state.llmCleanupEnabled = true
        advance()
    }

    // MARK: Permission pages

    private var microphonePage: some View {
        OnboardingPermissionPage(
            kicker: "Permission",
            icon: "mic.fill",
            heading: "Let me hear you",
            bodyText: "Whisper Master needs microphone access so it can transcribe your voice while you hold the record key. Audio stays on this Mac.",
            granted: micGranted,
            denied: micDenied,
            working: requestingMic,
            primaryLabel: micDenied ? "Open System Settings" : "Allow Microphone",
            primaryAction: { Task { await grantMicrophone() } }
        )
    }

    private var accessibilityPage: some View {
        OnboardingPermissionPage(
            kicker: "Permission",
            icon: "keyboard",
            heading: "Type at the cursor",
            bodyText: "Accessibility lets Whisper Master paste your transcription into whichever app you're using. You can skip this and copy manually if you'd rather not.",
            granted: accessibilityGranted,
            denied: false,
            working: false,
            primaryLabel: "Open Accessibility Settings",
            primaryAction: { permissions.openAccessibilitySettings() },
            secondaryLabel: accessibilityGranted ? nil : "Skip for now",
            secondaryAction: { advance() }
        )
    }

    private var notificationsPage: some View {
        OnboardingPermissionPage(
            kicker: "Permission",
            icon: "bell.badge",
            heading: "Know when there's an update",
            bodyText: "Whisper Master can let you know when a new version is ready to install. That's the only thing it will notify you about.",
            granted: notifGranted,
            denied: notifDenied,
            working: requestingNotif,
            primaryLabel: notifDenied ? "Open Notification Settings" : "Allow Notifications",
            primaryAction: { Task { await grantNotifications() } },
            secondaryLabel: notifGranted ? nil : "Skip for now",
            secondaryAction: { advance() }
        )
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if step != .welcome {
                SecondaryButton(title: "Back") { goBack() }
            }
            Spacer()
            PrimaryButton(title: primaryFooterLabel) { primaryFooterAction() }
        }
    }

    private var primaryFooterLabel: String {
        switch step {
        case .welcome: return "Get started"
        case .microphone: return micGranted ? "Continue" : "Skip"
        case .accessibility: return accessibilityGranted ? "Continue" : "Skip"
        case .notifications: return notifGranted ? "Continue" : "Skip"
        case .micTest: return "Continue"
        case .smartCleanup: return state.llmCleanupEnabled ? "Continue" : "Skip"
        case .done: return "Start dictating"
        }
    }

    private func primaryFooterAction() {
        if step == .done {
            stopMicTest()
            onComplete()
            return
        }
        advance()
    }

    // MARK: Navigation

    private func advance() {
        guard let next = OnboardingStep(rawValue: step.rawValue + 1) else {
            onComplete()
            return
        }
        withAnimation(.easeInOut(duration: 0.2)) { step = next }
    }

    private func goBack() {
        if step == .micTest { stopMicTest() }
        guard let prev = OnboardingStep(rawValue: step.rawValue - 1) else { return }
        withAnimation(.easeInOut(duration: 0.2)) { step = prev }
    }

    // MARK: Permission state

    private func refresh() {
        let micStatus = permissions.microphoneStatus()
        micGranted = micStatus == .granted
        micDenied = micStatus == .denied
        accessibilityGranted = permissions.accessibilityGranted()
        Task {
            let status = await permissions.notificationStatus()
            notifGranted = status == .granted
            notifDenied = status == .denied
        }
    }

    private func grantMicrophone() async {
        refresh()
        if micDenied {
            permissions.openMicrophoneSettings()
            return
        }
        requestingMic = true
        let granted = await permissions.requestMicrophone()
        requestingMic = false
        micGranted = granted
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        if !granted {
            permissions.openMicrophoneSettings()
        }
    }

    private func grantNotifications() async {
        if notifDenied {
            permissions.openNotificationSettings()
            return
        }
        requestingNotif = true
        let granted = await permissions.requestNotifications()
        requestingNotif = false
        notifGranted = granted
        notifDenied = !granted
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Mic test

    private func startMicTest() {
        guard micGranted, !testRunning else { return }
        do {
            try microphoneCapture.start(
                bufferHandler: { _ in },
                levelHandler: { level in
                    Task { @MainActor in
                        testLevel = level
                        if level > 0.02 { testHeardSound = true }
                    }
                }
            )
            testRunning = true
        } catch {
            testRunning = false
        }
    }

    private func stopMicTest() {
        guard testRunning else { return }
        microphoneCapture.stop()
        testRunning = false
        testLevel = 0
    }
}
