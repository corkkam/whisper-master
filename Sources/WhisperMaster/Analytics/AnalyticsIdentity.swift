import Foundation

/// Anonymous, stable per-install identity for analytics, plus app-version
/// change detection for the `update_installed` signal.
///
/// Mirrors `LocalPeer`: a random UUID generated once and persisted — never
/// derived from the hostname, serial, or owner's name. It's used as PostHog's
/// `distinct_id`, so unique-user and retention counts work while the id itself
/// carries nothing reversible to a person.
enum AnalyticsIdentity {
    private static let idKey = "WhisperMaster.analyticsId.v1"
    private static let lastVersionKey = "WhisperMaster.analyticsLastVersion.v1"

    /// Random UUID, generated on first use and reused forever. Kept separate
    /// from the mesh peer id so mesh churn never affects user counts.
    static var installID: String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: idKey) { return existing }
        let fresh = UUID().uuidString
        defaults.set(fresh, forKey: idKey)
        return fresh
    }

    /// The app's current marketing version (e.g. "1.0.0").
    static var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
    }

    /// Records the current version as "seen" and returns the previously-seen
    /// version *only if it changed* — i.e. the app was updated since the last
    /// launch. Returns `nil` on a fresh install (no prior version) or an
    /// unchanged version.
    ///
    /// Always commits the current version, even when analytics is off, so
    /// opting in later never retroactively reports a stale update.
    static func consumeVersionChange() -> String? {
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: lastVersionKey)
        let current = currentVersion
        if previous != current {
            defaults.set(current, forKey: lastVersionKey)
        }
        guard let previous, previous != current else { return nil }
        return previous
    }
}
