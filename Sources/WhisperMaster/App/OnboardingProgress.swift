import Foundation

/// Per-account record of which onboarding steps a user has already been shown,
/// so the first-run wizard opens **once per user** and, when a new step is added
/// later, surfaces **only that new step** instead of the whole flow again.
///
/// Persisted in `UserDefaults` as a `userId → [stepID]` map (steps are keyed by
/// `OnboardingStep.id`, a stable string). Usage is per-account because the Clerk
/// gate lets several people sign into one Mac — the same rationale as `UsageStore`.
enum OnboardingProgress {
    private static let key = "WhisperMaster.onboardingSeenSteps.v1"

    private static func map() -> [String: [String]] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: [String]] ?? [:]
    }

    /// Whether this account has *any* onboarding record yet. Distinguishes a
    /// brand-new account from one that has completed onboarding, so the launch
    /// migration only seeds the seen-set the first time we ever see the account.
    static func hasRecord(userID: String) -> Bool {
        map()[userID] != nil
    }

    static func seenStepIDs(userID: String) -> Set<String> {
        Set(map()[userID] ?? [])
    }

    /// Union the given step IDs into the account's seen-set (idempotent).
    static func markSeen(_ stepIDs: [String], userID: String) {
        var current = map()
        let merged = Set(current[userID] ?? []).union(stepIDs)
        current[userID] = Array(merged)
        UserDefaults.standard.set(current, forKey: key)
    }

    /// The steps this account has not yet seen, in canonical flow order. Empty
    /// once the account is fully onboarded; exactly the freshly-added steps after
    /// a new case is appended to `OnboardingStep`.
    static func pendingSteps(userID: String) -> [OnboardingStep] {
        let seen = seenStepIDs(userID: userID)
        return OnboardingStep.allCases.filter { !seen.contains($0.id) }
    }
}
