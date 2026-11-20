import Foundation

/// The first-run flow as it plays out **in the notch**: four short beats, one
/// ask each, so setup happens on the same surface dictation will live on rather
/// than in a window the user has to find and then dismiss.
///
/// Presentation only. The *persisted* record of "this account has onboarded"
/// stays with `OnboardingStep` / `OnboardingProgress`, so the per-account
/// migration there keeps working untouched.
enum NotchOnboardingStep: Int, CaseIterable, Identifiable {
    /// Microphone grant, then a live mic check driven by the orb.
    case microphone
    /// Accessibility grant — what lets the transcript land at the cursor.
    case accessibility
    /// Register as a login item, so the app is there after a restart. Asked
    /// **here** rather than left buried in Settings: a dictation app the user has
    /// to remember to launch is one they stop reaching for, and the shortcut
    /// silently doing nothing after a reboot reads as the app being broken.
    case openAtLogin
    /// The shortcut, and the hand-off into real dictation.
    case ready

    var id: Int { rawValue }

    /// The next beat, or `nil` on the last one (which finishes the flow).
    var next: NotchOnboardingStep? { NotchOnboardingStep(rawValue: rawValue + 1) }

    /// The beat Back returns to, or `nil` on the first one.
    var previous: NotchOnboardingStep? { NotchOnboardingStep(rawValue: rawValue - 1) }

    /// The step's name as the user reads it, in VoiceOver labels and the step
    /// progress. Presentation only: the case names, raw values and persisted ids
    /// stay as they were. "Typing" rather than "Accessibility", because the beat
    /// is about what the grant lets the app do, not the name of the pane.
    var title: String {
        switch self {
        case .microphone: return "Microphone"
        case .accessibility: return "Typing"
        case .openAtLogin: return "Start with your Mac"
        case .ready: return "Ready"
        }
    }
}
