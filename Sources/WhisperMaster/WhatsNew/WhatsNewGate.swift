import Foundation

/// Decides whether a launch has earned the "What's New" window.
///
/// Pure and clock-free — the only inputs are the running version and the one
/// this machine last saw — so every branch below is covered by
/// `WhatsNewGateTests` rather than by installing builds.
enum WhatsNewGate {
    enum Decision: Equatable {
        /// Nothing recorded yet. **A fresh install is not an upgrade**: record
        /// the running version and show nothing, so a first-time user meets the
        /// notch onboarding instead of a release note about a release they were
        /// never here for.
        case firstInstall
        /// A genuine upgrade — the surface is warranted, if the manifest has a
        /// note to show.
        case show
        /// Same version (a relaunch) or older (a downgrade / a rolled-back
        /// install). Neither is news.
        case upToDate
    }

    static func decide(currentVersion: String, lastSeenVersion: String?) -> Decision {
        // An unreadable running version ("—" from a bundle-less run) is not
        // something to record or announce.
        guard let current = SemanticVersion(currentVersion) else { return .upToDate }
        // An unreadable stored value is treated as unset: re-record and stay
        // quiet, which is the same safe answer as a fresh install.
        guard let lastSeen = lastSeenVersion.flatMap(SemanticVersion.init) else { return .firstInstall }
        return current > lastSeen ? .show : .upToDate
    }
}

/// Where "the last release note this machine saw" lives.
///
/// **App scope, not per-Clerk-user.** The window is about the build sitting on
/// this Mac, so a shared machine shows a given release note once, not once per
/// person who signs in (which is the opposite of `UsageStore`'s per-account
/// file, and deliberately so).
struct WhatsNewStore: Sendable {
    static let defaultsKey = "WhisperMaster.lastSeenWhatsNewVersion.v1"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var lastSeenVersion: String? {
        defaults.string(forKey: Self.defaultsKey)
    }

    /// Recorded when the window is actually put on screen (or when a first
    /// install is being quietly caught up), never when a fetch merely succeeded —
    /// an offline launch must not burn the release.
    func markSeen(_ version: String) {
        defaults.set(version, forKey: Self.defaultsKey)
    }
}
