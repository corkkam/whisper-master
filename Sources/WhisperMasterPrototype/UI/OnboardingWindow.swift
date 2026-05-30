import AppKit
import AVFoundation
import SwiftUI

@MainActor
final class OnboardingWindow {
    private let window: NSWindow

    init(
        state: PrototypeAppState,
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
        window.level = .floating
        window.hidesOnDeactivate = false
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor(srgbRed: 0.906, green: 0.882, blue: 0.824, alpha: 1)
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

private enum OnboardingStep: Int, CaseIterable {
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

private struct OnboardingView: View {
    let state: PrototypeAppState
    let permissions: PermissionsManager
    let microphoneCapture: MicrophoneCaptureService
    let retryEngine: () -> Void
    let onClose: () -> Void
    let onComplete: () -> Void

    @State private var step: OnboardingStep = .welcome
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
            Studio.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, 28)
                    .padding(.top, 18)

                stepHeader
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
            VStack(alignment: .leading, spacing: 1) {
                Text("Whisper Master")
                    .font(StudioFont.sans(14, .bold))
                    .foregroundStyle(Studio.ink)
                Text("STUDIO")
                    .font(StudioFont.monoSmall)
                    .tracking(2.5)
                    .foregroundStyle(Studio.red)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Studio.inkSecondary)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Studio.surface))
                    .overlay(Circle().strokeBorder(Studio.cardBorder, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Close — you can reopen this later from the menu bar")
        }
    }

    private var stepHeader: some View {
        HStack(spacing: 10) {
            ForEach(OnboardingStep.allCases, id: \.rawValue) { stepValue in
                stepDot(for: stepValue)
                if stepValue != OnboardingStep.allCases.last {
                    Rectangle()
                        .fill(stepValue.rawValue < step.rawValue ? Studio.red : Studio.cardBorder)
                        .frame(height: 2)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func stepDot(for stepValue: OnboardingStep) -> some View {
        let isCurrent = stepValue == step
        let isComplete = stepValue.rawValue < step.rawValue
        return ZStack {
            Circle()
                .fill(isCurrent || isComplete ? Studio.red : Studio.surface)
                .frame(width: 22, height: 22)
                .overlay(
                    Circle().strokeBorder(isCurrent ? Color.white.opacity(0.3) : Studio.cardBorder, lineWidth: 1)
                )
            if isComplete {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(.white)
            } else if isCurrent {
                Circle().fill(.white).frame(width: 6, height: 6)
            }
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
                    Text("Whisper Master")
                        .font(StudioFont.sans(30, .heavy))
                        .foregroundStyle(Studio.ink)
                    Text("Local-first dictation for macOS")
                        .font(StudioFont.subtitle)
                        .foregroundStyle(Studio.inkSecondary)
                }
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 12) {
                bullet("Speak, and your words land at the cursor — anywhere on your Mac.")
                bullet("All transcription runs on-device. Nothing leaves this machine.")
                bullet("Two quick permissions, a 5-second mic check, and you're done.")
            }
            .padding(.top, 6)

            Spacer(minLength: 0)
        }
    }

    private var microphonePage: some View {
        permissionPage(
            icon: "mic.fill",
            heading: "Let me hear you",
            body: "Whisper Master needs microphone access so it can transcribe your voice while you hold the record key. Audio stays on this Mac.",
            granted: micGranted,
            denied: micDenied,
            working: requestingMic,
            primaryLabel: micDenied ? "Open System Settings" : "Allow Microphone",
            primaryAction: { Task { await grantMicrophone() } }
        )
    }

    private var accessibilityPage: some View {
        permissionPage(
            icon: "keyboard",
            heading: "Type at the cursor",
            body: "Accessibility lets Whisper Master paste your transcription into whichever app you're using. You can skip this and copy manually if you'd rather not.",
            granted: accessibilityGranted,
            denied: false,
            working: false,
            primaryLabel: "Open Accessibility Settings",
            primaryAction: {
                permissions.promptAccessibility()
                permissions.openAccessibilitySettings()
            },
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
                Text("Say something")
                    .font(StudioFont.sans(22, .bold))
                    .foregroundStyle(Studio.ink)
                Text(testHeardSound
                     ? "Heard you loud and clear. Looking good."
                     : "Speak a sentence — try \"Hello Whisper, can you hear me?\". The bars should move.")
                    .font(StudioFont.cardBody)
                    .foregroundStyle(Studio.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Studio.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(testHeardSound ? Studio.green.opacity(0.5) : Studio.cardBorder, lineWidth: 1)
                    )

                LevelMeter(level: testLevel, active: testRunning)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 24)
            }
            .frame(height: 130)

            HStack(spacing: 8) {
                Image(systemName: testHeardSound ? "checkmark.circle.fill" : (testRunning ? "ear" : "ear.badge.waveform"))
                    .foregroundStyle(testHeardSound ? Studio.green : Studio.inkSecondary)
                Text(micStatusText)
                    .font(StudioFont.cardBody)
                    .foregroundStyle(Studio.inkSecondary)
                Spacer()
                if !testRunning && !testHeardSound {
                    StudioButton(title: "Start mic check", icon: nil, filled: false) { startMicTest() }
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
                    .fill(Studio.green.opacity(0.18))
                    .frame(width: 96, height: 96)
                Image(systemName: "checkmark")
                    .font(.system(size: 44, weight: .heavy))
                    .foregroundStyle(Studio.green)
            }
            VStack(spacing: 8) {
                Text("You're ready")
                    .font(StudioFont.sans(30, .heavy))
                    .foregroundStyle(Studio.ink)
                Text(engineReady
                     ? "The voice engine is downloaded and loaded. Hold your push-to-talk key and start dictating."
                     : "Hold your push-to-talk key and start dictating. We're finishing the voice engine in the background.")
                    .font(StudioFont.subtitle)
                    .foregroundStyle(Studio.inkSecondary)
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
                    .font(StudioFont.sans(14, .semibold))
                    .foregroundStyle(Studio.ink)
                if let detail = engineStatusDetail {
                    Text(detail)
                        .font(StudioFont.monoSmall)
                        .foregroundStyle(Studio.inkSecondary)
                }
            }

            Spacer(minLength: 0)

            if engineFailed {
                StudioButton(title: "Retry", icon: nil, filled: true) { retryEngine() }
            } else if enginePreparing {
                Text("\(Int((state.download?.fractionCompleted ?? 0) * 100))%")
                    .font(StudioFont.sans(15, .bold))
                    .foregroundStyle(Studio.inkSecondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Studio.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(engineReady ? Studio.green.opacity(0.5) : Studio.cardBorder, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var statusIcon: some View {
        if engineReady {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Studio.green)
        } else if engineFailed {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Studio.red)
        } else {
            ProgressView().controlSize(.small).tint(Studio.red)
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
                StudioButton(title: "Back", icon: nil, filled: false) { goBack() }
            }
            Spacer()
            Text(footerHint)
                .font(StudioFont.monoSmall)
                .tracking(1)
                .foregroundStyle(Studio.inkTertiary)
            Spacer()
            StudioButton(title: primaryFooterLabel, icon: nil, filled: true) {
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
        if testRunning { return "Listening..." }
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

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(Studio.red)
                .frame(width: 6, height: 6)
                .padding(.top, 7)
            Text(text)
                .font(StudioFont.subtitle)
                .foregroundStyle(Studio.ink.opacity(0.92))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func permissionPage(
        icon: String,
        heading: String,
        body: String,
        granted: Bool,
        denied: Bool,
        working: Bool,
        primaryLabel: String,
        primaryAction: @escaping () -> Void,
        secondaryLabel: String? = nil,
        secondaryAction: (() -> Void)? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .center, spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(granted ? Studio.green.opacity(0.18) : Studio.red.opacity(0.12))
                        .frame(width: 56, height: 56)
                    Image(systemName: granted ? "checkmark" : icon)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(granted ? Studio.green : Studio.red)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(heading)
                        .font(StudioFont.sans(22, .bold))
                        .foregroundStyle(Studio.ink)
                    Text(granted ? "Granted. You're good to go." : "Not yet granted.")
                        .font(StudioFont.cardBody)
                        .foregroundStyle(granted ? Studio.green : Studio.inkSecondary)
                }
                Spacer()
            }

            Text(body)
                .font(StudioFont.subtitle)
                .foregroundStyle(Studio.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(3)

            HStack(spacing: 12) {
                if granted {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                        Text("Granted").font(StudioFont.sans(14, .semibold))
                    }
                    .foregroundStyle(Studio.green)
                } else if working {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small).tint(Studio.red)
                        Text("Waiting for your response...")
                            .font(StudioFont.cardBody)
                            .foregroundStyle(Studio.inkSecondary)
                    }
                } else {
                    StudioButton(title: primaryLabel, icon: nil, filled: true, action: primaryAction)
                    if let secondaryLabel, let secondaryAction {
                        StudioButton(title: secondaryLabel, icon: nil, filled: false, action: secondaryAction)
                    }
                }
                Spacer()
            }

            Spacer(minLength: 0)
        }
    }
}

private struct LevelMeter: View {
    let level: Float
    let active: Bool

    private let barCount = 32

    var body: some View {
        GeometryReader { geo in
            let spacing: CGFloat = 4
            let totalSpacing = spacing * CGFloat(barCount - 1)
            let barWidth = max(2, (geo.size.width - totalSpacing) / CGFloat(barCount))
            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<barCount, id: \.self) { index in
                    bar(index: index, width: barWidth, height: geo.size.height)
                }
            }
        }
    }

    private func bar(index: Int, width: CGFloat, height: CGFloat) -> some View {
        let center = Double(barCount - 1) / 2.0
        let distance = abs(Double(index) - center) / center
        let envelope = 1.0 - pow(distance, 2.0)
        let normalized = min(1.0, Double(level) * 6.0)
        let h = max(4, CGFloat(envelope * normalized) * height)
        return RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(active ? Studio.red : Studio.cardBorder)
            .frame(width: width, height: h)
            .animation(.easeOut(duration: 0.08), value: level)
    }
}
