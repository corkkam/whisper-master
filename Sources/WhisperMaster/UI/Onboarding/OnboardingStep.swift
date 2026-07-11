import Foundation

/// The ordered pages of the first-run wizard. `Int`-backed so navigation is just
/// `rawValue ± 1`, and the "N of M" footer derives from `allCases.count`.
///
/// The live mic check deliberately sits **right after** the microphone
/// permission — grant, then immediately hear it work — before the remaining
/// permissions. There's no on-device-model step here: the 1.8 GB "Smart
/// cleanup" download would stall the critical path, so it lives in Settings.
enum OnboardingStep: Int, CaseIterable {
    case welcome
    case microphone
    case micTest
    case accessibility
    case notifications
    case done

    /// Shown in the progress bar for the current step.
    var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .microphone: return "Microphone"
        case .micTest: return "Mic check"
        case .accessibility: return "Accessibility"
        case .notifications: return "Notifications"
        case .done: return "All set"
        }
    }
}
