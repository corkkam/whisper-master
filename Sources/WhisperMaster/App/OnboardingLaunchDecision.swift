import Foundation

/// Whether a signed-in launch shows onboarding: today's migration seed and
/// pending check from `proceedAfterAuthIfNeeded()`, as one pure decision.
///
/// Used from PR 4.
///
/// A nil user must be handled before resolve: today a nil user does not seed
/// and shows onboarding (AppDelegate proceedAfterAuthIfNeeded).
enum OnboardingLaunchDecision: Equatable {
    /// An account with no record that has already granted both permissions is
    /// plainly past onboarding: record it as seen and do not show it.
    case seedAsSeen
    case show
    case skip

    static func resolve(
        hasRecord: Bool,
        micGranted: Bool,
        accessibilityGranted: Bool,
        pending: Bool,
        signOutInFlight: Bool
    ) -> OnboardingLaunchDecision {
        // A sign-out still waiting on the network keeps the gate up, so nothing
        // behind it may open.
        if signOutInFlight { return .skip }
        if !hasRecord, micGranted, accessibilityGranted { return .seedAsSeen }
        return pending ? .show : .skip
    }
}
