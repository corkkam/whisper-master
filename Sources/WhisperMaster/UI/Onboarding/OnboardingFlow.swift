import AppKit
import SwiftUI

/// The first-run wizard container: brand chrome, the segmented progress bar, the
/// per-step content, and the footer. Owns step state, permission polling, and
/// navigation; the individual pages are dumb views fed from here.
struct OnboardingView: View {
    let state: AppState
    let permissions: PermissionsManager
    let microphoneCapture: MicrophoneCaptureService
    /// The ordered steps to present. The full wizard by default; a subset when
    /// only newly-added steps are being shown to an already-onboarded user.
    let steps: [OnboardingStep]
    let retryEngine: () -> Void
    let onClose: () -> Void
    let onComplete: () -> Void

    init(
        state: AppState,
        permissions: PermissionsManager,
        microphoneCapture: MicrophoneCaptureService,
        steps: [OnboardingStep] = OnboardingStep.allCases,
        retryEngine: @escaping () -> Void,
        onClose: @escaping () -> Void,
        onComplete: @escaping () -> Void,
        initialStep: OnboardingStep = .welcome
    ) {
        self.state = state
        self.permissions = permissions
        self.microphoneCapture = microphoneCapture
        // Never present an empty flow — fall back to the full wizard.
        let resolved = steps.isEmpty ? OnboardingStep.allCases : steps
        self.steps = resolved
        self.retryEngine = retryEngine
        self.onClose = onClose
        self.onComplete = onComplete
        _stepIndex = State(initialValue: resolved.firstIndex(of: initialStep) ?? 0)
    }

    /// Index into `steps`. `step` is derived from it, so navigation is `±1`
    /// within the presented subset rather than across `OnboardingStep.allCases`.
    @State private var stepIndex: Int
    private var step: OnboardingStep { steps[stepIndex] }
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
    /// Which way the last navigation moved, so the step transition slides in
    /// from the correct edge (forward = new page enters from the right).
    @State private var goingBack = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            WarmBackground()

            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, 28)
                    .padding(.top, 18)

                OnboardingProgressBar(steps: steps, step: step)
                    .padding(.horizontal, 32)
                    .padding(.top, 20)
                    .padding(.bottom, 24)

                stepContent
                    .id(step)
                    .transition(stepTransition)
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
        // Auto-advance a beat *after* a permission flips, so the user actually
        // sees the "Granted" confirmation before the page slides away.
        .onChange(of: micGranted) { _, granted in
            if granted { advanceAfterGrant(from: .microphone) }
        }
        .onChange(of: accessibilityGranted) { _, granted in
            if granted { advanceAfterGrant(from: .accessibility) }
        }
        .onChange(of: notifGranted) { _, granted in
            if granted { advanceAfterGrant(from: .notifications) }
        }
    }

    /// Asymmetric slide+fade between steps, or a plain crossfade under Reduce
    /// Motion. The slide direction follows `goingBack` so Back reverses it.
    private var stepTransition: AnyTransition {
        if reduceMotion { return .opacity }
        let insertEdge: Edge = goingBack ? .leading : .trailing
        let removeEdge: Edge = goingBack ? .trailing : .leading
        return .asymmetric(
            insertion: .move(edge: insertEdge).combined(with: .opacity),
            removal: .move(edge: removeEdge).combined(with: .opacity)
        )
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
            .accessibilityLabel("Close onboarding")
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
        case .micTest:
            MicTestPage(
                micGranted: micGranted,
                level: testLevel,
                running: testRunning,
                heardSound: testHeardSound,
                onStart: startMicTest,
                onStop: stopMicTest
            )
        case .accessibility:
            accessibilityPage
        case .notifications:
            notificationsPage
        case .done:
            DonePage(state: state, retryEngine: retryEngine)
        }
    }

    // MARK: Permission pages

    private var microphonePage: some View {
        OnboardingPermissionPage(
            kicker: "Permission",
            icon: "mic.fill",
            heading: "Let me hear you",
            bodyText: "This is the one permission Whisper Master can't work without — it listens only while you hold the record key, and every word is transcribed right here on your Mac. Nothing is uploaded.",
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
            heading: "Drop the words at your cursor",
            bodyText: "With Accessibility on, your transcription types itself straight into whatever app you're in. Skip it and Whisper Master will pop the text on your clipboard for a quick paste instead.",
            granted: accessibilityGranted,
            denied: false,
            working: false,
            // promptAccessibility() adds the app to the Accessibility list and
            // shows the system prompt (openAccessibilitySettings alone just opens
            // an empty pane); we then open the pane so the toggle is one click away.
            primaryLabel: "Allow Accessibility",
            primaryAction: {
                permissions.promptAccessibility()
                permissions.openAccessibilitySettings()
            }
        )
    }

    private var notificationsPage: some View {
        OnboardingPermissionPage(
            kicker: "Permission",
            icon: "bell.badge",
            heading: "A heads-up when there's an update",
            bodyText: "The only thing Whisper Master will ever ping you about is a fresh version being ready to install. No streaks, no nudges, no noise.",
            granted: notifGranted,
            denied: notifDenied,
            working: requestingNotif,
            primaryLabel: notifDenied ? "Open Notification Settings" : "Allow Notifications",
            primaryAction: { Task { await grantNotifications() } }
        )
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 10) {
            HStack {
                if stepIndex > 0 {
                    SecondaryButton(title: "Back") { goBack() }
                }
                Spacer()
                footerPrimary
            }
            // Surface the reopen path visibly, not just as the close button's
            // hover tooltip — the app has no window to return to otherwise.
            Text("You can reopen this anytime from the menu bar icon.")
                .font(Typography.caption)
                .foregroundStyle(Theme.textTertiary)
        }
    }

    /// The footer's trailing control. On an ungranted permission step it's a
    /// *de-emphasized* "Skip for now" so the accent "Allow …" in the content is
    /// the only prominent CTA — never two accent buttons on screen at once.
    @ViewBuilder
    private var footerPrimary: some View {
        if isPermissionStep, !currentPermissionGranted {
            SecondaryButton(title: "Skip for now") { advance() }
        } else {
            PrimaryButton(title: primaryFooterLabel) { primaryFooterAction() }
        }
    }

    private var isPermissionStep: Bool {
        step == .microphone || step == .accessibility || step == .notifications
    }

    private var currentPermissionGranted: Bool {
        switch step {
        case .microphone: return micGranted
        case .accessibility: return accessibilityGranted
        case .notifications: return notifGranted
        default: return false
        }
    }

    private var primaryFooterLabel: String {
        switch step {
        case .welcome: return "Get started"
        case .done: return "Start dictating"
        case .microphone, .accessibility, .notifications, .micTest:
            // "Continue" implies more ahead; on the last page of a partial flow
            // (just a newly-added step) it finishes, so label it plainly.
            return stepIndex == steps.count - 1 ? "Done" : "Continue"
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
        guard stepIndex + 1 < steps.count else {
            onComplete()
            return
        }
        goingBack = false
        withAnimation(Theme.Motion.respecting(reduceMotion, Theme.Motion.step)) { stepIndex += 1 }
    }

    private func goBack() {
        if step == .micTest { stopMicTest() }
        guard stepIndex > 0 else { return }
        goingBack = true
        withAnimation(Theme.Motion.respecting(reduceMotion, Theme.Motion.step)) { stepIndex -= 1 }
    }

    /// Advance ~0.5s after a permission is granted, but only if we're still on
    /// the step that just flipped (a manual Continue may have moved us already),
    /// so the user gets a beat to see the "Granted" confirmation first.
    private func advanceAfterGrant(from grantedStep: OnboardingStep) {
        guard step == grantedStep else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            if step == grantedStep { advance() }
        }
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
