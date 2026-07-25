import Foundation

/// Per-account record of which onboarding steps a user has already been shown,
/// so the first-run wizard opens **once per user**.
///
/// Persisted in `UserDefaults` as a `userId → [stepID]` map (steps are keyed by
/// `OnboardingStep.id`, a stable string). Usage is per-account because the Clerk
/// gate lets several people sign into one Mac — the same rationale as `UsageStore`.
enum OnboardingProgress {
    private static let key = "WhisperMaster.onboardingSeenSteps.v1"

    /// Legacy step ids from earlier multi-step wizards. Any of these patterns
    /// means the account already finished onboarding and should not be re-shown
    /// the single permissions screen.
    private static let legacyPermissionStepIDs: Set<String> = [
        "microphone",
        "accessibility",
    ]

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

    /// Whether this account has already completed onboarding (current or legacy).
    static func isComplete(userID: String) -> Bool {
        let seen = seenStepIDs(userID: userID)
        if seen.contains(OnboardingStep.permissions.id) { return true }
        // Old split mic + accessibility pages.
        if legacyPermissionStepIDs.isSubset(of: seen) { return true }
        // Finished any earlier multi-step wizard (ended on "All set").
        if seen.contains("done") { return true }
        return false
    }

    /// Steps still to present. Empty once onboarded; otherwise the single
    /// permissions screen.
    static func pendingSteps(userID: String) -> [OnboardingStep] {
        isComplete(userID: userID) ? [] : OnboardingStep.allCases
    }
}
