import Foundation

/// Which channel this **binary** was built for, read off the bundle id that
/// `Scripts/channel.sh` re-badges into the staged app.
///
/// Deliberately distinct from `BetaAccess.currentChannel`, which answers a
/// different question — *which appcast should Sparkle poll* — and is driven by
/// the Clerk `betaAccess` flag. A stable build run by a beta user reports
/// `.beta` there, which is correct for feed selection and wrong for feature
/// gating: gating must key on what this binary actually shipped with, or a
/// stable app would light up surfaces its release never included.
///
/// Keep the ids in lock-step with `Scripts/channel.sh` → `CH_BUNDLE_ID`.
enum ReleaseChannel: String {
    case stable
    case beta
    case dev

    /// Pure mapping, so the gate is unit-testable without a bundle.
    ///
    /// A bundle-less `swift build` CLI run and the headless `WM_SNAPSHOT`
    /// renderer both fall through to `.dev` on purpose: local development and
    /// the snapshot PNGs should always see every surface.
    static func channel(forBundleID id: String?) -> ReleaseChannel {
        switch id {
        case "app.whispermaster.mac": return .stable
        case "app.whispermaster.mac.beta": return .beta
        default: return .dev
        }
    }

    static let current: ReleaseChannel = channel(forBundleID: Bundle.main.bundleIdentifier)
}

/// Surfaces that are built but not yet released on the stable channel.
///
/// Connectors and Notes & Reminders ship **dark on stable**: the sidebar still
/// lists both so the roadmap stays visible, but neither can be opened and each
/// reads "Coming soon". They're live on beta/dev, which is where they're being
/// proven before they reach the whole userbase.
///
/// This is one flag rather than two because the two features are entangled —
/// the Today agenda reads calendars through a *connector instance*, and the
/// voice "remind me…" path writes into the notes store. Shipping one without
/// the other would leave a half-wired surface.
enum FeatureFlags {
    /// True when Connectors, Notes & Reminders, and everything that feeds them
    /// are available in this build.
    static var connectorsAndNotesAvailable: Bool {
        ReleaseChannel.current != .stable
    }
}
