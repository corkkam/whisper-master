import AppKit
import AVFoundation
import SwiftUI

@MainActor
final class OnboardingWindow {
    private let window: NSWindow

    init(
        permissions: PermissionsManager,
        microphoneCapture: MicrophoneCaptureService,
        onComplete: @escaping () -> Void
    ) {
        let root = OnboardingView(
            permissions: permissions,
            microphoneCapture: microphoneCapture,
            onComplete: onComplete
        )
        let host = NSHostingController(rootView: root)
        window = NSWindow(contentViewController: host)
        window.title = "Welcome to Whisper Master"
        window.styleMask = [.titled, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.setContentSize(NSSize(width: 620, height: 540))
        window.center()
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.hidesOnDeactivate = false
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor(srgbRed: 0.09, green: 0.085, blue: 0.082, alpha: 1)
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
    let permissions: PermissionsManager
    let microphoneCapture: MicrophoneCaptureService
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
            Palette.background.ignoresSafeArea()

            VStack(spacing: 0) {
                stepHeader
                    .padding(.horizontal, 32)
                    .padding(.top, 28)
                    .padding(.bottom, 24)

                stepContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 32)

                footer
                    .padding(.horizontal, 32)
                    .padding(.vertical, 22)
            }
        }
        .frame(width: 620, height: 540)
        .onAppear(perform: refresh)
        .onReceive(Timer.publish(every: 0.75, on: .main, in: .common).autoconnect()) { _ in
            refresh()
        }
        .onChange(of: micGranted) { _, granted in
            if granted, step == .microphone {
                advance()
            }
        }
        .onChange(of: accessibilityGranted) { _, granted in
            if granted, step == .accessibility {
                advance()
            }
        }
    }

    private var stepHeader: some View {
        HStack(spacing: 10) {
            ForEach(OnboardingStep.allCases, id: \.rawValue) { stepValue in
                stepDot(for: stepValue)
                if stepValue != OnboardingStep.allCases.last {
                    Rectangle()
                        .fill(stepValue.rawValue < step.rawValue ? Palette.accent : Palette.stroke)
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
                .fill(isCurrent ? Palette.accent : (isComplete ? Palette.accent : Palette.surface))
                .frame(width: 22, height: 22)
                .overlay(
                    Circle().strokeBorder(isCurrent ? Color.white.opacity(0.25) : Palette.stroke, lineWidth: 1)
                )
            if isComplete {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(.black.opacity(0.85))
            } else if isCurrent {
                Circle()
                    .fill(.black.opacity(0.85))
                    .frame(width: 6, height: 6)
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
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 18) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Palette.accentSoft)
                        .frame(width: 78, height: 78)
                    Image(systemName: "waveform")
                        .font(.system(size: 36, weight: .bold))
                        .foregroundStyle(Palette.accent)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Whisper Master")
                        .font(Typography.display)
                        .foregroundStyle(Palette.textPrimary)
                    Text("Local-first dictation for macOS")
                        .font(Typography.body)
                        .foregroundStyle(Palette.textSecondary)
                }
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 12) {
                bullet("Speak, and your words land at the cursor — anywhere on your Mac.")
                bullet("All transcription runs on-device. Nothing leaves this machine.")
                bullet("Two quick permissions, a 5-second mic check, and you're done.")
            }
            .padding(.top, 8)

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
                    .font(Typography.title)
                    .foregroundStyle(Palette.textPrimary)
                Text(testHeardSound
                     ? "Heard you loud and clear. Looking good."
                     : "Speak a sentence — try \"Hello Whisper, can you hear me?\". The bars should move.")
                    .font(Typography.body)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Palette.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(testHeardSound ? Palette.success.opacity(0.5) : Palette.stroke, lineWidth: 1)
                    )

                LevelMeter(level: testLevel, active: testRunning)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 24)
            }
            .frame(height: 130)

            HStack(spacing: 8) {
                Image(systemName: testHeardSound ? "checkmark.circle.fill" : (testRunning ? "ear" : "ear.badge.waveform"))
                    .foregroundStyle(testHeardSound ? Palette.success : Palette.textSecondary)
                Text(micStatusText)
                    .font(Typography.body)
                    .foregroundStyle(Palette.textSecondary)
                Spacer()
                if !testRunning && !testHeardSound {
                    Button("Start mic check") { startMicTest() }
                        .controlSize(.regular)
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
                    .fill(Palette.success.opacity(0.18))
                    .frame(width: 96, height: 96)
                Image(systemName: "checkmark")
                    .font(.system(size: 44, weight: .heavy))
                    .foregroundStyle(Palette.success)
            }
            VStack(spacing: 8) {
                Text("You're ready")
                    .font(Typography.display)
                    .foregroundStyle(Palette.textPrimary)
                Text("Hold your push-to-talk key and start dictating. The voice engine will download in the background on first use.")
                    .font(Typography.body)
                    .foregroundStyle(Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            Spacer()
        }
    }

    private var footer: some View {
        HStack {
            if step != .welcome {
                Button("Back") { goBack() }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)
            }
            Spacer()
            Text(footerHint)
                .font(Typography.caption)
                .foregroundStyle(Palette.textTertiary)
            Spacer()
            Button(primaryFooterLabel) { primaryFooterAction() }
                .keyboardShortcut(.return)
                .controlSize(.large)
                .disabled(!primaryFooterEnabled)
        }
    }

    private var footerHint: String {
        switch step {
        case .welcome: return "Step 1 of \(OnboardingStep.allCases.count)"
        case .microphone: return "Step 2 of \(OnboardingStep.allCases.count)"
        case .accessibility: return "Step 3 of \(OnboardingStep.allCases.count)"
        case .micTest: return "Step 4 of \(OnboardingStep.allCases.count)"
        case .done: return "All done"
        }
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
        if step == .microphone, !micGranted {
            // user is choosing to skip without granting — keep them honest, jump to next anyway
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
        withAnimation(.easeInOut(duration: 0.18)) {
            step = next
        }
    }

    private func goBack() {
        if step == .micTest { stopMicTest() }
        guard let prev = OnboardingStep(rawValue: step.rawValue - 1) else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            step = prev
        }
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
                        if level > 0.02 {
                            testHeardSound = true
                        }
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
                .fill(Palette.accent)
                .frame(width: 6, height: 6)
                .padding(.top, 6)
            Text(text)
                .font(Typography.body)
                .foregroundStyle(Palette.textPrimary.opacity(0.92))
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
                        .fill(granted ? Palette.success.opacity(0.18) : Palette.accentSoft)
                        .frame(width: 56, height: 56)
                    Image(systemName: granted ? "checkmark" : icon)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(granted ? Palette.success : Palette.accent)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(heading)
                        .font(Typography.title)
                        .foregroundStyle(Palette.textPrimary)
                    Text(granted ? "Granted. You're good to go." : "Not yet granted.")
                        .font(Typography.body)
                        .foregroundStyle(granted ? Palette.success : Palette.textSecondary)
                }
                Spacer()
            }

            Text(body)
                .font(Typography.bodyRegular)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(3)

            HStack(spacing: 12) {
                if granted {
                    Label("Granted", systemImage: "checkmark.circle.fill")
                        .font(Typography.body)
                        .foregroundStyle(Palette.success)
                } else if working {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small).tint(Palette.accent)
                        Text("Waiting for your response...")
                            .font(Typography.body)
                            .foregroundStyle(Palette.textSecondary)
                    }
                } else {
                    Button(primaryLabel, action: primaryAction)
                        .controlSize(.large)
                    if let secondaryLabel, let secondaryAction {
                        Button(secondaryLabel, action: secondaryAction)
                            .buttonStyle(.borderless)
                            .foregroundStyle(Palette.textSecondary)
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
            .fill(active ? Palette.accent : Palette.stroke)
            .frame(width: width, height: h)
            .animation(.easeOut(duration: 0.08), value: level)
    }
}
