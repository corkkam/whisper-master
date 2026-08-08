import Foundation

/// Per-install identity for analytics, plus app-version change detection for the
/// `update_installed` signal.
///
/// Mirrors `LocalPeer`: a random UUID generated once and persisted — never
/// derived from the hostname, serial, or owner's name.
///
/// **This is the pre-sign-in identity, not the whole story.** It is what PostHog
/// and GA see until Clerk resolves a session, at which point `Analytics.identify`
/// switches PostHog's `distinct_id` to the **Clerk user id** and attaches the
/// account's email — see `AnalyticsAccount`. The install id stays GA's
/// `client_id` for the life of the install (GA's `client_id` is a device key, not
/// a person key; the person rides in `user_id` beside it), and it remains the
/// distinct id for anyone who has not signed in.
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

/// The signed-in Clerk account, as analytics sees it.
///
/// **This is deliberately identifying**, which is a reversal of the install-id
/// design above and the reason the Settings copy no longer says "anonymous". The
/// question it exists to answer — *which customer uses which features* — cannot be
/// answered by a per-install UUID: one person on two Macs is two users, and a
/// named account is what turns a usage report into something you can act on for a
/// specific seat.
///
/// Two rules keep it from spreading further than that:
/// - **Only what Clerk already holds.** The id, the primary email, and the display
///   name. Nothing derived from the user's content, and nothing from the Mac.
/// - **It never reaches an event's parameters.** It is set once on the *person*
///   (PostHog) and as `user_id` (GA). `AnalyticsEvent.parameters` stays
///   content-free and account-free, so a single event body is still not
///   attributable on its own.
struct AnalyticsAccount: Equatable {
    /// The Clerk user id (`user_2…`). Becomes PostHog's `distinct_id` and GA's
    /// `user_id`.
    let id: String
    /// Primary email, when Clerk has one. Optional because an OAuth account can
    /// resolve before its email does.
    let email: String?
    /// Display name, when set. Purely a convenience for reading PostHog.
    let name: String?

    /// Person properties for PostHog. `channel` and `appVersion` are repeated here
    /// (they are already super properties on every *event*) because PostHog's
    /// unique-user, cohort, and retention maths runs off the **person** profile —
    /// a property that exists only on events cannot define a cohort. That is the
    /// same reasoning `Analytics.initializeSDKIfNeeded` records for `channel`.
    var personProperties: [String: String] {
        var properties = [
            "clerkUserId": id,
            "channel": ReleaseChannel.current.rawValue,
            "appVersion": AnalyticsIdentity.currentVersion,
        ]
        if let email, !email.isEmpty { properties["email"] = email }
        if let name, !name.isEmpty { properties["name"] = name }
        return properties
    }
}
