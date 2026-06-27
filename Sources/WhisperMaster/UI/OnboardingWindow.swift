import AppKit
import AVFoundation
import SwiftUI

@MainActor
final class OnboardingWindow {
    private let window: NSWindow

    init(
        state: AppState,
        permissions: PermissionsManager,
        microphoneCapture: MicrophoneCaptureService,
        retryEngine: @escaping () -> Void,
        onClose: @escaping () -> Void,
        onComplete: @escaping () -> Void
    ) {
        let root = OnboardingView(
            state: state,
            permissions: permissions,
            microphoneCapture: microphoneCapture,
            retryEngine: retryEngine,
            onClose: onClose,
            onComplete: onComplete
        )
        let host = NSHostingController(rootView: root)
        window = NSWindow(contentViewController: host)
        window.title = "Welcome to Whisper Master"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.setContentSize(NSSize(width: 640, height: 580))
        window.center()
        window.isReleasedWhenClosed = false
        // Normal level (not .floating): a floating window sits above System
        // Settings and the macOS permission modal, hiding them when the user
        // goes to grant Accessibility. We rely on activate()/orderFront instead.
        window.level = .normal
        window.hidesOnDeactivate = false
        window.isMovableByWindowBackground = true
        // Warm-charcoal chrome to match the app theme; dark appearance so native
        // controls (progress, switches) render correctly on the dark canvas.
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(srgbRed: 0.102, green: 0.090, blue: 0.078, alpha: 1)
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func close() {
        window.orderOut(nil)
    }
}

enum OnboardingStep: Int, CaseIterable {
    case welcome
    case microphone
    case accessibility
    case micTest
    case done

    var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .microphone: return "Microphone"
        case .accessibility: return "Accessibility"
        case .micTest: return "Mic check"
        case .done: return "All set"
        }
    }
}

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
    @State private var accessibilitySkipped = false
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

                OnboardingStepHeader(step: step)
                    .padding(.horizontal, 32)
                    .padding(.top, 18)
                    .padding(.bottom, 22)

                stepContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 32)

                footer
                    .padding(.horizontal, 32)
                    .padding(.vertical, 22)
            }
        }
        .frame(width: 640, height: 580)
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
    }

    private var topBar: some View {
        HStack(spacing: 11) {
            BrandLogo(size: 30, cornerRadius: 8)
            Text("Whisper Master")
                .font(.system(size: 14, weight: .semibold))
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
        case .welcome: welcomePage
        case .microphone: microphonePage
        case .accessibility: accessibilityPage
        case .micTest: micTestPage
        case .done: donePage
        }
    }

    private var welcomePage: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center, spacing: 18) {
                BrandLogo(size: 78, cornerRadius: 18)
                VStack(alignment: .leading, spacing: 6) {
                    KickerLabel("Welcome")
                    Text("Whisper Master")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Local-first dictation for macOS")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 12) {
                OnboardingBullet(text: "Speak, and your words land at the cursor — anywhere on your Mac.")
                OnboardingBullet(text: "All transcription runs on-device. Nothing leaves this machine.")
                OnboardingBullet(text: "Two quick permissions, a 5-second mic check, and you're done.")
            }
            .padding(.top, 6)

            Spacer(minLength: 0)
        }
    }

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
            secondaryAction: {
                accessibilitySkipped = true
                advance()
            }
        )
    }

    private var micTestPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                KickerLabel("Sound check")
                Text("Say something")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                Text(testHeardSound
                     ? "Heard you loud and clear. Looking good."
                     : "Speak a sentence — try \"Hello Whisper, can you hear me?\". The bars should move.")
                    .font(Typography.body)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Theme.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(testHeardSound ? Theme.success.opacity(0.5) : Theme.stroke, lineWidth: 1)
                    )

                OnboardingLevelMeter(level: testLevel, active: testRunning)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 24)
            }
            .frame(height: 130)

            HStack(spacing: 8) {
                Image(systemName: testHeardSound ? "checkmark.circle.fill" : (testRunning ? "ear" : "ear.badge.waveform"))
                    .foregroundStyle(testHeardSound ? Theme.success : Theme.textSecondary)
                Text(micStatusText)
                    .font(Typography.body)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                if !testRunning && !testHeardSound {
                    SecondaryButton(title: "Start mic check") { startMicTest() }
                }
            }

            Spacer(minLength: 0)
        }
        .onAppear { startMicTest() }
        .onDisappear { stopMicTest() }
    }

    private var donePage: some View {
        VStack(spacing: 18) {
            Spacer()
            ZStack {
                Circle()
                    .fill(Theme.success.opacity(0.18))
                    .frame(width: 96, height: 96)
                Image(systemName: "checkmark")
                    .font(.system(size: 44, weight: .heavy))
                    .foregroundStyle(Theme.success)
            }
            VStack(spacing: 8) {
                KickerLabel("Ready")
                Text("You're ready")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                Text(engineReady
                     ? "The voice engine is downloaded and loaded. Hold your push-to-talk key and start dictating."
                     : "Hold your push-to-talk key and start dictating. We're finishing the voice engine in the background.")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }

            voiceEngineStatusCard
                .frame(maxWidth: 440)

            Spacer()
        }
    }

    // MARK: Voice engine status

    private var engineReady: Bool { state.preparedEngine == state.selectedEngine }
    private var enginePreparing: Bool { state.preparingEngine != nil }
    private var engineFailed: Bool {
        guard !engineReady, !enginePreparing else { return false }
        if case .failed = state.phase { return true }
        return false
    }

    private var voiceEngineStatusCard: some View {
        HStack(spacing: 12) {
            statusIcon
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(engineStatusTitle)
                    .font(Typography.headline)
                    .foregroundStyle(Theme.textPrimary)
                if let detail = engineStatusDetail {
                    Text(detail)
                        .font(Typography.monoSmall)
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            Spacer(minLength: 0)

            if engineFailed {
                PrimaryButton(title: "Retry") { retryEngine() }
            } else if enginePreparing {
                Text("\(Int((state.download?.fractionCompleted ?? 0) * 100))%")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(engineReady ? Theme.success.opacity(0.5) : Theme.stroke, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var statusIcon: some View {
        if engineReady {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Theme.success)
        } else if engineFailed {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Theme.accent)
        } else {
            ProgressView().controlSize(.small).tint(Theme.accent)
        }
    }

    private var engineStatusTitle: String {
        if engineReady { return "Voice engine ready" }
        if engineFailed { return "Voice engine setup failed" }
        return "Setting up \(state.selectedEngine.displayName) voice engine…"
    }

    private var engineStatusDetail: String? {
        if engineReady { return state.selectedEngine.userFacingName }
        if engineFailed { return "Check your connection and try again." }
        return state.download?.detail ?? "Downloading \(state.selectedEngine.estimatedDownloadSize)…"
    }

    private var footer: some View {
        HStack {
            if step != .welcome {
                SecondaryButton(title: "Back") { goBack() }
            }
            Spacer()
            Text(footerHint)
                .font(Typography.monoSmall)
                .tracking(1)
                .foregroundStyle(Theme.textTertiary)
            Spacer()
            PrimaryButton(title: primaryFooterLabel) {
                if primaryFooterEnabled { primaryFooterAction() }
            }
            .opacity(primaryFooterEnabled ? 1 : 0.4)
        }
    }

    private var footerHint: String {
        if step == .done { return "ALL DONE" }
        return "STEP \(step.rawValue + 1) OF \(OnboardingStep.allCases.count)"
    }

    private var primaryFooterLabel: String {
        switch step {
        case .welcome: return "Get started"
        case .microphone: return micGranted ? "Continue" : "Skip"
        case .accessibility: return accessibilityGranted ? "Continue" : "Skip"
        case .micTest: return "Continue"
        case .done: return "Start dictating"
        }
    }

    private var primaryFooterEnabled: Bool {
        switch step {
        case .micTest: return micGranted
        default: return true
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

    private var micStatusText: String {
        if !micGranted { return "Mic permission not granted." }
        if testHeardSound { return "Audio reaching the app." }
        if testRunning { return "Listening…" }
        return "Press start to test your microphone."
    }

    private func advance() {
        guard let next = OnboardingStep(rawValue: step.rawValue + 1) else {
            onComplete()
            return
        }
        withAnimation(.easeInOut(duration: 0.18)) { step = next }
    }

    private func goBack() {
        if step == .micTest { stopMicTest() }
        guard let prev = OnboardingStep(rawValue: step.rawValue - 1) else { return }
        withAnimation(.easeInOut(duration: 0.18)) { step = prev }
    }

    private func refresh() {
        let micStatus = permissions.microphoneStatus()
        micGranted = micStatus == .granted
        micDenied = micStatus == .denied
        accessibilityGranted = permissions.accessibilityGranted()
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
