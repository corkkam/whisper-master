import ClerkKit
import Foundation

/// Reads the beta-access flag off the signed-in Clerk user and maps it to a
/// Sparkle update channel.
///
/// The landing page's `flagBetaUser` sets `publicMetadata.betaAccess = true` on
/// waitlist join. The flag is **only writable server-side** (Clerk secret key),
/// so the app treats it as read-only: it decides which appcast Sparkle polls,
/// nothing more. Flipping a user beta→stable server-side (`setBetaAccess(id,false)`)
/// rolls them onto the stable feed on the next check — same account, no reinstall.
///
/// A single Clerk *production* instance serves both channels; beta and stable
/// users share one account and differ only by this flag.
enum UpdateChannel: String {
    case stable
    case beta
    case dev

    /// The Sparkle appcast this channel polls. All are EdDSA-signed with the
    /// same key, hosted at the R2 root (see CLAUDE.md → Distribution). Keep these
    /// in lock-step with CH_SU_FEED_URL in Scripts/channel.sh.
    var feedURLString: String {
        switch self {
        case .stable: return "https://dl.corkkam.com/appcast.xml"
        case .beta: return "https://dl.corkkam.com/appcast-beta.xml"
        case .dev: return "https://dl.corkkam.com/appcast-dev.xml"
        }
    }
}

enum BetaAccess {
    /// Bundle id of the development build (see Scripts/channel.sh → dev).
    private static let devBundleID = "app.whispermaster.mac.dev"

    /// True when the signed-in Clerk user carries `publicMetadata.betaAccess == true`.
    /// False when signed out, unconfigured, or the flag is absent/false — so the
    /// app defaults to the stable channel until a beta user is actually present.
    @MainActor
    static var isBetaUser: Bool {
        guard ClerkConfig.isConfigured, let user = Clerk.shared.user else { return false }
        return user.publicMetadata?["betaAccess"]?.boolValue == true
    }

    /// The update channel to poll right now.
    ///
    /// A **dev** build is pinned to the dev feed by its bundle id: the dev
    /// channel is gated by branch/environment separation (only dev testers run
    /// it), not by the Clerk `betaAccess` flag, so it must never be re-routed to
    /// stable/beta. Stable/beta builds resolve dynamically from the flag, so a
    /// server-side `betaAccess` flip rolls a user between those two feeds with no
    /// reinstall.
    @MainActor
    static var currentChannel: UpdateChannel {
        if Bundle.main.bundleIdentifier == devBundleID { return .dev }
        return isBetaUser ? .beta : .stable
    }
}
