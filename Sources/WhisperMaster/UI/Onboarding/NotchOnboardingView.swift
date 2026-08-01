import SwiftUI

/// First-run setup, in the notch.
///
/// One black `NotchShape` molded to the physical notch, dropping into a band that
/// holds a single ask at a time: a step counter, the orb, one headline, one
/// sub-line and one button. Setup therefore happens on exactly the surface
/// dictation will live on — the user learns where to look while they're granting.
///
/// The orb is the flow's only moving part (there is no waveform here): it
/// **thinks** while an ask is outstanding, **works** while a system prompt is up,
/// and **listens** — driven by the real mic level — the moment it can hear, which
/// is what turns the microphone step into proof rather than a claim.
struct NotchOnboardingView: View {
    let model: NotchOnboardingModel
    /// Read-only, for the shortcut name and the voice-engine progress line.
    let state: AppState
    var geometry: NotchGeometry = .none
    var layout: NotchOnboardingLayout = NotchOnboardingLayout()
    /// Opens the Settings window — the gear in the top row.
    var onOpenSettings: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isSnapshot) private var isSnapshot

    /// Drives the one-shot drop out of the notch on first appearance.
    @State private var opened = false

    /// Reduce Motion and the headless renderer both want the band already down.
    private var isOpen: Bool { opened || reduceMotion || isSnapshot }

    /// The hero orb. Big enough for the `large` preset's dot field to read as a
    /// sphere rather than a speckle.
    private var orbSize: CGFloat { 62 }

    var body: some View {
        let shape = NotchShape(
            topConcaveRadius: layout.topConcaveRadius,
            bottomCornerRadius: layout.bottomCornerRadius
        )

        VStack(spacing: 0) {
            // Camera dead-zone — nothing renders behind the physical notch, and
            // clicks up there fall through to the menu bar.
            Color.clear
                .frame(height: geometry.notchHeight)
                .allowsHitTesting(false)

            band
                .frame(height: layout.thickness)
        }
        .frame(
            width: layout.surfaceWidth(for: geometry),
            height: isOpen ? geometry.notchHeight + layout.thickness : 0,
            alignment: .top
        )
        .background { shape.fill(Theme.Notch.surface) }
        .clipShape(shape)
        // The band is always ink, whatever the app's appearance is set to, so the
        // button ladder inside it has to read from `Theme.Notch` rather than the
        // mode-dependent tokens. Declared once here for the whole subtree.
        .onDarkSurface()
        .opacity(isOpen ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            model.refresh()
            guard !isOpen else { return }
            // Drop out of the notch once, the way the dictation surface does.
            withAnimation(Theme.Motion.appear) { opened = true }
        }
        // Each beat replaces the copy in place; the band itself doesn't resize.
        .animation(Theme.Motion.respecting(reduceMotion, Theme.Motion.step), value: model.step)
        // The permission poll deliberately lives in `NotchOnboardingWindow`, not
        // here: a `Timer.publish` created in this body would be re-subscribed on
        // every body pass, and the mic check re-evaluates it ~20×/s, so the tick
        // would be starved exactly when the flow depends on it.
    }

    // MARK: - Band

    private var band: some View {
        VStack(spacing: 0) {
            topBar
            StepDots(steps: NotchOnboardingStep.allCases.count, current: model.step.rawValue)
                .padding(.top, 2)

            Spacer(minLength: Theme.Space.sm)

            OrbView(level: model.level, mode: orbMode, diameter: orbSize, preset: .large)

            VStack(spacing: 3) {
                Text(headline)
                    .font(Typography.sans(19, .bold))
                    .foregroundStyle(Theme.Notch.text)
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle)
                    .font(Typography.sans(13))
                    .foregroundStyle(Theme.Notch.textSecondary)
            }
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .padding(.top, Theme.Space.md)
            .padding(.horizontal, Theme.Space.lg)

            actions
                .padding(.top, Theme.Space.lg)

            Spacer(minLength: 0)
        }
        .padding(.top, Theme.Space.md)
        .padding(.bottom, Theme.Space.lg)
        .padding(.horizontal, Theme.Space.xl)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Setup — \(model.step.title)")
    }

    private var topBar: some View {
        HStack(spacing: Theme.Space.md) {
            Spacer()
            NotchIconButton(icon: "gearshape.fill", label: "Open Settings", action: onOpenSettings)
            NotchIconButton(icon: "xmark", label: "Close setup", action: model.dismiss)
        }
    }

    // MARK: - Copy
    //
    // Written as the app speaking, one line each: the band has room for a
    // sentence, not a paragraph, and the state it describes changes under it.

    private var headline: String {
        switch model.step {
        case .microphone:
            if model.heardVoice { return "I can hear you." }
            if model.micGranted { return "Say something." }
            if model.micDenied { return "I still can't hear you." }
            return "This lets me hear your voice."
        case .accessibility:
            return model.accessibilityGranted
                ? "I can type for you now."
                : "This lets me type for you."
        case .openAtLogin:
            if model.launchAtLoginEnabled { return "I'll be here when you get back." }
            if model.launchAtLoginNeedsApproval { return "One switch left, in System Settings." }
            return "Should I start with your Mac?"
        case .ready:
            return "Hold \(shortcutName) and talk."
        }
    }

    private var subtitle: String {
        switch model.step {
        case .microphone:
            if model.heardVoice { return "Loud and clear. Nothing leaves this Mac." }
            if model.micGranted { return "The orb moves with your voice." }
            if model.micDenied { return "Turn the microphone back on in System Settings." }
            return "Only while you're holding the shortcut."
        case .accessibility:
            if model.accessibilityGranted { return "Your words land right at the cursor." }
            return "Skip it and I'll put the text on your clipboard instead."
        case .openAtLogin:
            // Enabled first: a failure the user then fixed in System Settings must not
            // leave a stale error line sitting under a success headline.
            if model.launchAtLoginEnabled { return "Your shortcut works straight after a restart." }
            if let error = model.launchAtLoginError { return error }
            if model.launchAtLoginNeedsApproval {
                return "Turn Whisper Master on under Login Items."
            }
            return "Otherwise the shortcut does nothing until you open me."
        case .ready:
            return engineLine
        }
    }

    /// The voice engine may still be downloading in the background at this point,
    /// so the last beat tells the truth about it instead of claiming "all set".
    private var engineLine: String {
        if state.preparedEngine == state.selectedEngine {
            return "I'll type what you say, wherever you are."
        }
        if let download = state.download {
            return "Still fetching my voice engine — \(Int(download.fractionCompleted * 100))%."
        }
        return "I'm finishing my voice engine in the background."
    }

    private var shortcutName: String { state.hotkey.sentenceName }

    /// What the orb is depicting: thinking while an ask is outstanding, working
    /// while the system prompt is up, listening once it can hear.
    private var orbMode: OrbView.Mode {
        switch model.step {
        case .microphone:
            if model.requestingMic { return .working }
            return model.micGranted ? .listening : .thinking
        case .accessibility:
            return model.accessibilityGranted ? .listening : .thinking
        case .openAtLogin:
            return model.launchAtLoginEnabled ? .listening : .thinking
        case .ready:
            return .listening
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private var actions: some View {
        switch model.step {
        case .microphone:
            micActions
        case .accessibility:
            if model.accessibilityGranted {
                GrantedBadge()
            } else {
                HStack(spacing: Theme.Space.sm) {
                    NotchPillButton(title: "Grant Accessibility", action: model.grantAccessibility)
                    NotchPillButton(title: "Not now", kind: .ghost, action: model.advance)
                }
            }
        case .openAtLogin:
            loginActions
        case .ready:
            NotchPillButton(title: "Start dictating", action: model.finish)
        }
    }

    /// The login-item beat. Three outcomes, not two: on, held for approval (the
    /// state that looks on and isn't — so it gets its own ask), or not registered.
    @ViewBuilder
    private var loginActions: some View {
        if model.launchAtLoginEnabled {
            GrantedBadge()
        } else if model.launchAtLoginNeedsApproval {
            HStack(spacing: Theme.Space.sm) {
                NotchPillButton(title: "Open Login Items", action: model.openLoginItemsSettings)
                NotchPillButton(title: "Not now", kind: .ghost, action: model.advance)
            }
        } else {
            HStack(spacing: Theme.Space.sm) {
                NotchPillButton(title: "Open at login", action: model.enableLaunchAtLogin)
                NotchPillButton(title: "Not now", kind: .ghost, action: model.advance)
            }
        }
    }

    @ViewBuilder
    private var micActions: some View {
        if model.requestingMic {
            HStack(spacing: Theme.Space.sm) {
                ProgressView()
                    .controlSize(.small)
                    .tint(Theme.Notch.text)
                Text("Waiting for your answer…")
                    .font(Typography.notchBody)
                    .foregroundStyle(Theme.Notch.textSecondary)
            }
        } else if model.heardVoice {
            GrantedBadge()
        } else if model.micGranted {
            // Granted but nothing heard yet: the flow is waiting on a sentence,
            // so leave a way past for anyone who'd rather not speak.
            NotchPillButton(title: "Continue", kind: .ghost, action: model.advance)
        } else {
            HStack(spacing: Theme.Space.sm) {
                NotchPillButton(title: model.micDenied ? "Open System Settings" : "Grant Microphone") {
                    Task { await model.grantMicrophone() }
                }
                if model.micDenied {
                    NotchPillButton(title: "Skip for now", kind: .ghost, action: model.advance)
                }
            }
        }
    }
}

// MARK: - Pieces

/// The step counter: one capsule per beat, the current one in ember. Read as a
/// single "Step 2 of 3" rather than three anonymous shapes.
private struct StepDots: View {
    let steps: Int
    let current: Int

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<steps, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(fill(index))
                    .frame(width: 30, height: 3)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(current + 1) of \(steps)")
    }

    private func fill(_ index: Int) -> Color {
        if index == current { return Theme.Notch.accent }
        if index < current { return Theme.Notch.textTertiary }
        return Theme.Notch.hairline
    }
}

/// A capsule action on the notch surface — the band's two rungs of the shared
/// button ladder (`UI/Components/ButtonStyles.swift`). `primary` is the same ember
/// pill the rest of the app uses for its one real action; `ghost` (an outlined
/// rung here, so its bounds read on black before hover) is the way past it.
///
/// The band's `.onDarkSurface()` is what makes the ladder pick `Theme.Notch`
/// tokens, so this looks right even with the app in light mode.
private struct NotchPillButton: View {
    enum Kind { case primary, ghost }

    let title: String
    var kind: Kind = .primary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Typography.sans(14, .semibold))
                // The band's buttons are a touch wider than the app's default.
                .padding(.horizontal, 2)
        }
        .modifier(NotchPillRung(kind: kind))
    }
}

/// Picks the rung. A `ViewBuilder` branch would give the two kinds different
/// view identities and lose the press state mid-interaction.
private struct NotchPillRung: ViewModifier {
    let kind: NotchPillButton.Kind

    func body(content: Content) -> some View {
        switch kind {
        case .primary: content.primaryButton()
        case .ghost: content.outlinedButton()
        }
    }
}

/// The small circular gear / close controls in the band's top row.
private struct NotchIconButton: View {
    let icon: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
        }
        .iconButton(size: 24, tooltip: label)
        .accessibilityLabel(label)
    }
}

/// The confirmation beat shown in place of the button once an ask is satisfied —
/// the flow auto-advances a moment later.
private struct GrantedBadge: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var landed = false

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .symbolEffect(.bounce, value: landed)
            Text("Granted")
                .font(Typography.sans(14, .semibold))
        }
        .foregroundStyle(Theme.Notch.success)
        .onAppear {
            guard !reduceMotion else { return }
            landed = true
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Granted")
    }
}
