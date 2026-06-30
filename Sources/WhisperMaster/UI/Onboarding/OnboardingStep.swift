import Foundation

/// The ordered pages of the first-run wizard. `Int`-backed so navigation is just
/// `rawValue ± 1`, and the "N of M" footer derives from `allCases.count`.
enum OnboardingStep: Int, CaseIterable {
    case welcome
    case microphone
    case accessibility
    case notifications
    case micTest
    case done

    /// Shown in the progress bar for the current step.
    var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .microphone: return "Microphone"
        case .accessibility: return "Accessibility"
        case .notifications: return "Notifications"
        case .micTest: return "Mic check"
        case .done: return "All set"
        }
    }
}
