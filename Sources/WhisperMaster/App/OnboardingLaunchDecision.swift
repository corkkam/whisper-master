import Foundation

/// Whether a signed-in launch shows onboarding: today's migration seed and
/// pending check from `proceedAfterAuthIfNeeded()`, as one pure decision.
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

    /// The `AppDelegate` entry, which reads the account's record. A nil user has
    /// no record to look up or seed, so it shows setup, as the launch always has.
    static func resolve(
        userID: String?,
        micGranted: Bool,
        accessibilityGranted: Bool,
        signOutInFlight: Bool
    ) -> OnboardingLaunchDecision {
        guard let userID else { return signOutInFlight ? .skip : .show }
        return resolve(
            hasRecord: OnboardingProgress.hasRecord(userID: userID),
            micGranted: micGranted,
            accessibilityGranted: accessibilityGranted,
            pending: !OnboardingProgress.pendingSteps(userID: userID).isEmpty,
            signOutInFlight: signOutInFlight)
    }
}

/// Holds the sign-in gate up while Clerk's `signOut()` is on the network: until
/// it returns, `Clerk.shared.user` stays set, and the next tick would otherwise
/// reveal the app again. `AppDelegate` ends the hold when the call returns, or
/// after `limit`, whichever is first, so a stalled network cannot hold the gate
/// with no end. Only the newest sign-out's end clears it.
struct SignOutHold {
    /// Above the 60 s request timeout of the session Clerk's client uses, so it
    /// ends only a call that hangs past that timeout; a slow call returns or
    /// fails first. In-memory only.
    static let limit: TimeInterval = 75

    private var issued = 0
    private var current: Int?

    var inFlight: Bool { current != nil }

    mutating func begin() -> Int {
        issued += 1
        current = issued
        return issued
    }

    /// Whether this ended the hold. A stale end (an older sign-out's timer)
    /// changes nothing.
    mutating func end(_ token: Int) -> Bool {
        guard current == token else { return false }
        current = nil
        return true
    }
}
