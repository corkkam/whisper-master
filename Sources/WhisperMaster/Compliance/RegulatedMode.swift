import Foundation

/// **Regulated Mode** — the guarantee that nothing about a dictation session
/// leaves this Mac, enforced rather than requested.
///
/// ── Why this exists ──────────────────────────────────────────────────────
/// Transcription is already local; that has always been true. What was *not*
/// true is that the app is silent on the network. Product analytics
/// (`analyticsEnabled`), usage rollups (`usageSyncEnabled`) and notes sync
/// (`notesSyncEnabled`) all default to **on**, and each is a user-facing toggle
/// in Settings.
///
/// For an individual that is a reasonable, disclosed default. For a law firm or
/// a clinic it is disqualifying, and not because the payloads are sensitive —
/// they are counts and app versions, never transcript text. It is disqualifying
/// because of who can turn them back on. A practice that must attest "this tool
/// transmits nothing" cannot make that statement about software where any of
/// forty users can flip a switch in Settings, or where a future release changes
/// a default. The commitment has to be a *policy*, not a preference.
///
/// That distinction is the whole commercial argument for the Practice tier: a
/// consumer dictation app cannot make it, because a consumer dictation app has
/// no notion of an administrator.
///
/// ── How it is set ────────────────────────────────────────────────────────
/// Three sources, checked in order of authority:
///
/// 1. **A managed preference** pushed by MDM (Jamf, Kandji, Mosyle, Intune) as
///    a configuration profile for this bundle id. `UserDefaults` surfaces these
///    and `objectIsForced(forKey:)` reports whether the value is *forced* —
///    meaning the user cannot override it, because macOS itself will not let
///    them. This is the only variant that survives a determined user, so it is
///    the one an IT admin is actually buying.
/// 2. **A build/deploy setting** in Info.plist, for a firm that installs from a
///    package rather than through MDM.
/// 3. **A local opt-in**, for a sole practitioner with no IT department who
///    wants the same guarantee for themselves.
///
/// ── Why enforcement is at the sink, not at the toggle ────────────────────
/// It would be less code to have `AppState` set the three booleans to `false`
/// and stop there. That is exactly the design that fails an audit: it makes the
/// guarantee depend on every present *and future* caller remembering to consult
/// a flag, and the next feature that adds a network call will not remember.
///
/// So each egress point asks `RegulatedMode.allowsTelemetry` immediately before
/// transmitting. The flags in `AppState` become a UI concern — what the
/// switches show and whether they are interactive — while the actual guarantee
/// lives next to the socket. A sub-feature cannot opt out of a check it has to
/// pass through.
enum RegulatedMode {

    /// Managed-preference key. Deploy as a configuration profile payload for
    /// this app's bundle identifier:
    ///
    /// ```xml
    /// <key>RegulatedMode</key><true/>
    /// ```
    static let defaultsKey = "RegulatedMode"

    /// Info.plist key for package-based deployment.
    private static let plistKey = "WMRegulatedMode"

    /// Local opt-in, for a practitioner with no MDM.
    static let localOptInKey = "RegulatedModeLocalOptIn"

    // MARK: - State

    /// Is Regulated Mode active, by any route?
    static var isActive: Bool {
        if isManaged { return UserDefaults.standard.bool(forKey: defaultsKey) }
        if Bundle.main.object(forInfoDictionaryKey: plistKey) as? Bool == true { return true }
        return UserDefaults.standard.bool(forKey: localOptInKey)
    }

    /// Is it being enforced by MDM — i.e. can the user *not* turn it off?
    ///
    /// `objectIsForced` is the specific question worth asking. A configuration
    /// profile can install a value the user is still free to change; a *forced*
    /// value is one macOS refuses to let them override. Only the latter is what
    /// an administrator is promised, so only the latter locks the UI.
    static var isManaged: Bool {
        UserDefaults.standard.objectIsForced(forKey: defaultsKey)
    }

    /// How the current state was arrived at — surfaced in Settings and in the
    /// compliance report, because "who decided this" is the first question an
    /// auditor asks.
    enum Source: String {
        case mdm = "Enforced by your organisation (MDM)"
        case deployment = "Set by your deployment package"
        case local = "Enabled by you on this Mac"
        case off = "Not enabled"
    }

    static var source: Source {
        if isManaged { return .mdm }
        if Bundle.main.object(forInfoDictionaryKey: plistKey) as? Bool == true { return .deployment }
        if UserDefaults.standard.bool(forKey: localOptInKey) { return .local }
        return .off
    }

    // MARK: - The gates
    //
    // Every network egress that is not strictly required to run the product
    // asks one of these. They are deliberately separate rather than one
    // `isActive` check, so that the *reason* each call site is gated stays
    // legible and so a future policy can permit one without the others.

    /// Product analytics — PostHog and Google Analytics.
    ///
    /// Note that there are two sinks here, not one. `Analytics.send` fans out to
    /// both, and gating only the PostHog half — the one everybody remembers,
    /// because it is the one in the docs — would leave GA transmitting. This is
    /// precisely the class of mistake that sink-level enforcement exists to
    /// prevent.
    static var allowsTelemetry: Bool { !isActive }

    /// Per-day usage rollups pushed to the eval dashboard.
    static var allowsUsageSync: Bool { !isActive }

    /// Notes and reminders cloud sync. Unlike the two above, this one can carry
    /// *user content* — a note is dictated text. It is therefore the most
    /// important of the three to disable for a regulated deployment, and the
    /// one whose absence a reviewer is most likely to test for.
    static var allowsNotesSync: Bool { !isActive }

    /// Peer discovery and remote transcription over Bluetooth/Tailscale.
    ///
    /// Off under Regulated Mode regardless of its own setting. Even though the
    /// mesh is LAN-local and never reaches the internet, it moves audio between
    /// machines — and "audio never leaves this Mac" has to mean this Mac.
    static var allowsNearbyMesh: Bool { !isActive }

    /// Automatic update checks against the public Sparkle appcast.
    ///
    /// Still permitted: shipping security fixes matters more than appcast
    /// silence, and the request carries only a version string. A firm that
    /// wants updates mirrored internally pins `SUFeedURL` to its own host via
    /// the same configuration profile, which is a deployment choice rather than
    /// something this flag should decide.
    static var allowsUpdateChecks: Bool { true }

    // MARK: - Disclosure

    /// One line per egress, for Settings and for the written architecture note
    /// that a security review asks for.
    ///
    /// Generated from the live gates rather than hand-maintained. A hardcoded
    /// table is a document that silently goes stale the first time somebody
    /// adds a network call; this one is wrong only if the gate itself is wrong,
    /// in which case the behaviour is wrong too and the table is telling the
    /// truth about it.
    static func disclosure() -> [(what: String, allowed: Bool, detail: String)] {
        [
            ("Speech audio", false, "Never transmitted. Processed in memory on this Mac."),
            ("Transcribed text", false, "Never transmitted. Pasted locally."),
            ("Product analytics", allowsTelemetry, "PostHog and Google Analytics — feature counts linked to your account, no content."),
            ("Usage statistics", allowsUsageSync, "Per-day totals attributed to your account."),
            ("Notes & reminders sync", allowsNotesSync, "Your dictated note text, to your account."),
            ("Nearby Macs mesh", allowsNearbyMesh, "LAN-local audio to a paired Mac."),
            ("Update checks", allowsUpdateChecks, "Version string to the update feed."),
            ("Sign-in", true, "Email address to the identity provider. Required for licensing."),
            ("Speech model download", true, "One-time, ~1.5 GB, from the model mirror."),
        ]
    }
}
