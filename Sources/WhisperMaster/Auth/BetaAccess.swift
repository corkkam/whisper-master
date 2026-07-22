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

    /// The Sparkle appcast this channel polls. Both are EdDSA-signed with the
    /// same key, hosted at the R2 root (see CLAUDE.md → Distribution).
    var feedURLString: String {
        switch self {
        case .stable: return "https://model.scoopscore.in/appcast.xml"
        case .beta: return "https://model.scoopscore.in/appcast-beta.xml"
        }
    }
}

enum BetaAccess {
    /// True when the signed-in Clerk user carries `publicMetadata.betaAccess == true`.
    /// False when signed out, unconfigured, or the flag is absent/false — so the
    /// app defaults to the stable channel until a beta user is actually present.
    @MainActor
    static var isBetaUser: Bool {
        guard ClerkConfig.isConfigured, let user = Clerk.shared.user else { return false }
        return user.publicMetadata?["betaAccess"]?.boolValue == true
    }

    /// The update channel to poll right now, derived from the live Clerk session.
    @MainActor
    static var currentChannel: UpdateChannel { isBetaUser ? .beta : .stable }
}
