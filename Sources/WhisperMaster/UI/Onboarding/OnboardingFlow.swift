import AppKit
import SwiftUI

/// Single-step first-run: grant Microphone + Accessibility on one screen.
/// The voice engine is prepared in the background at launch (download only if
/// missing) — it is not part of this wizard.
struct OnboardingView: View {
    let permissions: PermissionsManager
    let onClose: () -> Void
    let onComplete: () -> Void

    init(
        state: AppState? = nil,
        permissions: PermissionsManager,
        microphoneCapture: MicrophoneCaptureService? = nil,
        steps: [OnboardingStep] = OnboardingStep.allCases,
        retryEngine: (() -> Void)? = nil,
        onClose: @escaping () -> Void,
        onComplete: @escaping () -> Void,
        initialStep: OnboardingStep = .permissions
    ) {
        // `state` / `microphoneCapture` / `steps` / `retryEngine` / `initialStep`
        // kept on the initializer so existing call sites (AppDelegate, SnapshotMode)
        // compile without churn; the single-step UI only needs permissions +
        // completion handlers.
        _ = state
        _ = microphoneCapture
        _ = steps
        _ = retryEngine
        _ = initialStep
        self.permissions = permissions
        self.onClose = onClose
        self.onComplete = onComplete
    }

    @State private var micGranted = false
    @State private var micDenied = false
    @State private var requestingMic = false
    @State private var accessibilityGranted = false
    /// Prevents double-fire when both perms flip and the user also taps Done.
    @State private var didFinish = false

    var body: some View {
        ZStack {
            WarmBackground()

            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, 28)
                    .padding(.top, 18)
                    .padding(.bottom, 20)

                PermissionsPage(
                    micGranted: micGranted,
                    micDenied: micDenied,
                    requestingMic: requestingMic,
                    accessibilityGranted: accessibilityGranted,
                    onGrantMicrophone: { Task { await grantMicrophone() } },
                    onGrantAccessibility: {
                        // promptAccessibility() adds the app to the Accessibility
                        // list and shows the system prompt; open the pane so the
                        // toggle is one click away. Poll + didBecomeActive keep
                        // the row live after the user returns from Settings.
                        permissions.promptAccessibility()
                        permissions.openAccessibilitySettings()
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 32)

                footer
                    .padding(.horizontal, 32)
                    .padding(.vertical, 22)
            }
        }
        .frame(width: 640, height: 520)
        .onAppear(perform: refresh)
        .onReceive(Timer.publish(every: 0.75, on: .main, in: .common).autoconnect()) { _ in
            refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
        // Finish a beat after both are granted so the user sees the checkmarks.
        .onChange(of: bothGranted) { _, granted in
            if granted { finishAfterGrantBeat() }
        }
    }

    private var bothGranted: Bool {
        micGranted && accessibilityGranted
    }

    private var topBar: some View {
        HStack(spacing: 11) {
            BrandLogo(size: 30, cornerRadius: 8)
            Text("Whisper Master")
                .font(Typography.sans(14, .bold))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Button(action: { finish(fromClose: true) }) {
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

    private var footer: some View {
        VStack(spacing: 10) {
            HStack {
                Spacer()
                if bothGranted {
                    PrimaryButton(title: "Start dictating") { finish(fromClose: false) }
                } else {
                    SecondaryButton(title: "Skip for now") { finish(fromClose: false) }
                }
            }
            Text("You can reopen this anytime from the menu bar icon.")
                .font(Typography.caption)
                .foregroundStyle(Theme.textTertiary)
        }
    }

    // MARK: Finish

    private func finishAfterGrantBeat() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            if bothGranted { finish(fromClose: false) }
        }
    }

    private func finish(fromClose: Bool) {
        guard !didFinish else { return }
        didFinish = true
        if fromClose {
            onClose()
        } else {
            onComplete()
        }
    }

    // MARK: Permission state

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
}
