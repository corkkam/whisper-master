import Foundation

/// The first-run flow as it plays out **in the notch**: three short beats, one
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
    /// The shortcut, and the hand-off into real dictation.
    case ready

    var id: Int { rawValue }

    /// The next beat, or `nil` on the last one (which finishes the flow).
    var next: NotchOnboardingStep? { NotchOnboardingStep(rawValue: rawValue + 1) }

    /// Short name for the step, used as the VoiceOver context for the band (the
    /// visible copy is written per-state by the view, since it changes as each
    /// permission flips).
    var title: String {
        switch self {
        case .microphone: return "Microphone"
        case .accessibility: return "Accessibility"
        case .ready: return "Ready"
        }
    }
}
