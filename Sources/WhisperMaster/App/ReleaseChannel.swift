import Foundation

/// Which channel this **binary** was built for, read off its version string.
///
/// Deliberately distinct from `BetaAccess.allowedChannels`, which answers a
/// different question — *which appcast items may this user receive* — and is
/// driven by the Clerk `betaAccess` flag. Gating must key on what this binary
/// actually shipped with, or a stable app would light up surfaces its release
/// never included the moment someone flipped a server-side setting.
///
/// ⚠️ The signal is the **version**, not the bundle id. Stable and beta now ship
/// as one bundle (`app.whispermaster.mac`) so Sparkle can update between them,
/// so the id can no longer tell them apart; the `-beta.N` marker that
/// `Scripts/release.sh` already requires on every non-stable release can. Only
/// `dev` is still a side-by-side bundle, and it keeps its id as a second signal
/// because a local dev build may be built without a version marker at all.
enum ReleaseChannel: String {
    case stable
    case beta
    case dev

    /// The one bundle id a shipping build carries. Anything else — the `…mac.dev`
    /// side-by-side build, a bundle-less `swift build`, someone else's app — is
    /// treated as dev.
    static let shippingBundleID = "app.whispermaster.mac"

    /// Pure mapping, so the gate is unit-testable without a bundle.
    ///
    /// A bundle-less `swift build` CLI run and the headless `WM_SNAPSHOT`
    /// renderer both fall through to `.dev` on purpose: local development and
    /// the snapshot PNGs should always see every surface.
    static func channel(forVersion version: String?, bundleID id: String?) -> ReleaseChannel {
        guard id == shippingBundleID, let version else { return .dev }
        if version.contains("-dev.") { return .dev }
        if version.contains("-beta.") { return .beta }
        return .stable
    }

    static let current: ReleaseChannel = channel(
        forVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
        bundleID: Bundle.main.bundleIdentifier
    )
}

/// Which built surfaces this channel may open.
///
/// Connectors and Notes & Reminders are **open on every channel** as of
/// 2026-09-14: the staged rollout that held them to beta/dev is over, and
/// stable now gets the app beta was proving. The switch is kept rather than
/// deleted because it is the one place that decision is written down, and
/// because every call site still reads it — the closed path is what the Today
/// page's dictation-stats card and the plain onboarding promise exist for, so
/// re-closing a channel stays a one-line change rather than a rewrite.
///
/// This is one flag rather than two because the two features are entangled —
/// the Today agenda reads calendars through a *connector instance*, and the
/// voice "remind me…" path writes into the notes store. Shipping one without
/// the other would leave a half-wired surface.
enum FeatureFlags {
    /// True when Connectors, Notes & Reminders, and everything that feeds them
    /// are available in this build.
    static var connectorsAndNotesAvailable: Bool {
        connectorsAndNotesAvailable(on: ReleaseChannel.current)
    }

    /// Pure, so the gate is tested for every channel without a bundle — the same
    /// shape as `modelLabAvailable(on:)`. Takes the channel it no longer
    /// consults, because that is the parameter a re-close would key on.
    static func connectorsAndNotesAvailable(on channel: ReleaseChannel) -> Bool {
        true
    }

    /// True when the **Model Lab** is reachable: install several open-source
    /// models, bench them against the real suites, and point a shipped slot at
    /// one of them.
    ///
    /// Dev builds only, and not merely because it is unfinished. The page
    /// downloads gigabytes on request, holds a model resident for minutes at a
    /// time, and can change which model the app dictates with — none of which
    /// belongs in the hands of someone who installed a dictation app. `dev` also
    /// covers a bare `swift build` run and the headless snapshot renderer, which
    /// is what makes the page visible while it is being worked on.
    static var modelLabAvailable: Bool {
        modelLabAvailable(on: ReleaseChannel.current)
    }

    /// Pure, so the gate is tested for every channel without a bundle — the same
    /// shape as `SettingsSection.isAvailable(connectorsAndNotes:)`.
    static func modelLabAvailable(on channel: ReleaseChannel) -> Bool {
        channel == .dev
    }
}
