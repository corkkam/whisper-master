import Foundation

/// The first-run wizard is a **single permissions screen** (mic + accessibility).
/// The voice engine downloads in the background at launch when missing — it is
/// not part of this flow. Kept as an enum so `OnboardingProgress` can still
/// track seen-step ids if we ever add another page.
enum OnboardingStep: Int, CaseIterable {
    case permissions

    /// Stable, order-independent identifier used to persist which steps a user
    /// has already been shown (see `OnboardingProgress`).
    var id: String {
        switch self {
        case .permissions: return "permissions"
        }
    }

    var title: String {
        switch self {
        case .permissions: return "Permissions"
        }
    }
}
