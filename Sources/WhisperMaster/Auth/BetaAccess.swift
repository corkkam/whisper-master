import ClerkKit
import Foundation

/// Which update track a build belongs to.
///
/// Stable and beta are the **same installed app** — same bundle id, same name,
/// same appcast — told apart only by the `-beta.N` marker in the version and by
/// `<sparkle:channel>beta</sparkle:channel>` on the appcast item. `dev` is the
/// one channel still built as a side-by-side bundle with a feed of its own.
///
/// A single Clerk *production* instance serves stable and beta; those users
/// share one account and differ only by `publicMetadata.betaAccess`.
enum UpdateChannel: String, CaseIterable {
    case stable
    case beta
    case dev

    /// The Sparkle appcast this channel is served from, EdDSA-signed with the
    /// same key and hosted at the R2 root.
    ///
    /// Stable and beta deliberately return the **same** URL — they are one
    /// installed app reading one feed, and a beta item is told apart by its
    /// `<sparkle:channel>` tag, not by living in a separate file. Nothing routes
    /// on this any more (`SUFeedURL` in Info.plist is what Sparkle actually
    /// reads, and `Scripts/channel.sh` overrides it for `dev`); it stays as the
    /// compiled-in declaration that `DistributionHostTests` holds against
    /// `ModelInstaller.mirrorBaseURL`, so updates and model archives can never
    /// drift onto different buckets. Keep in lock-step with `CH_SU_FEED_URL`.
    var feedURLString: String {
        switch self {
        case .stable, .beta: return "https://dl.corkkam.com/appcast.xml"
        case .dev: return "https://dl.corkkam.com/appcast-dev.xml"
        }
    }

    /// How the build names itself beside the version, or `nil` when it should
    /// say nothing.
    ///
    /// Stable is unlabelled on purpose: the plain product name *is* the shipping
    /// build, so a "Stable" badge would put a word on the surface every ordinary
    /// user sees in order to tell them nothing. The label exists to mark a build
    /// as **not** the shipping one. `dev` reads "Nightly" rather than "Dev" —
    /// it names the cadence the build arrives on, which is what a tester needs
    /// to know, and it isn't jargon to someone outside the repo.
    var buildLabel: String? {
        switch self {
        case .stable: return nil
        case .beta: return "Beta"
        case .dev: return "Nightly"
        }
    }
}

enum BetaAccess {
    /// True when the signed-in Clerk user carries `publicMetadata.betaAccess == true`.
    /// False when signed out, unconfigured, or the flag is absent/false — so the
    /// app defaults to stable-only updates until a beta user is actually present.
    ///
    /// The landing page's `flagBetaUser` sets the flag on waitlist join. It is
    /// **only writable server-side** (Clerk secret key), so the app treats it as
    /// read-only: it decides which appcast items Sparkle will accept, nothing more.
    @MainActor
    static var isBetaUser: Bool {
        guard ClerkConfig.isConfigured, let user = Clerk.shared.user else { return false }
        return user.publicMetadata?["betaAccess"]?.boolValue == true
    }

    /// The Sparkle channels this user may receive, for `allowedChannelsForUpdater:`.
    ///
    /// ⚠️ An **empty** set is not "no updates" — it is "stable only". Sparkle
    /// always offers an item that carries no `<sparkle:channel>` and consults
    /// this set only for items that do (`SUAppcastDriver`, ~line 487). So a beta
    /// user sees beta *and* stable items and takes whichever has the higher
    /// `CFBundleVersion`; a stable user simply never sees the beta ones.
    ///
    /// That asymmetry is what makes the flag reversible with no reinstall. CI
    /// stamps `CFBundleVersion` with `date +%s`, so versions only ever increase
    /// in build order: flip the flag on and the next check finds the newer beta;
    /// flip it off and the beta item disappears from the candidate set, leaving
    /// the user on their current build until the next stable release — built
    /// later, so numbered higher — pulls them back onto the stable line. Nothing
    /// has to downgrade, which is fortunate, because Sparkle cannot.
    @MainActor
    static var allowedChannels: Set<String> {
        allowedChannels(isBetaUser: isBetaUser)
    }

    /// Pure half of the above, so the contract is unit-testable without Clerk.
    static func allowedChannels(isBetaUser: Bool) -> Set<String> {
        isBetaUser ? ["beta"] : []
    }
}
