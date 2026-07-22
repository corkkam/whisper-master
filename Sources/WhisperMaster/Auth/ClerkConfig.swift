import ClerkKit
import Foundation

/// Resolves the Clerk publishable key and configures the shared Clerk instance
/// once at launch.
///
/// The publishable key is client-safe — it only identifies your Clerk frontend
/// API and grants no privileged access — so both keys are embedded here and the
/// right one is chosen per build. There are **two Clerk instances** under one
/// app (see the landing page `lib/clerk/beta.ts`):
///
///   • **Production** (`whisper.corkkam.com`, `pk_live_…`) — the real userbase.
///     Both the shipping *stable* build **and** the side-by-side *beta* build use
///     it: beta and stable users share one account and differ only by
///     `publicMetadata.betaAccess` (which picks the Sparkle channel — see
///     `BetaAccess`). So the beta *build* is a production-instance client.
///   • **Development** (`sweeping-humpback-68.clerk.accounts.dev`, `pk_test_…`) —
///     a separate test userbase for internal dev builds (`dev-install.sh`
///     rebrands the bundle id to `…mac.dev`).
///
/// Selection is therefore keyed on the **bundle identifier**, not the build
/// configuration: a `…mac.dev` build (or a bundle-less `swift build` CLI run)
/// talks to the dev instance; the production `…mac` id and any `…beta` id talk to
/// the live instance. A `CLERK_PUBLISHABLE_KEY` env var or a real `pk_…` value in
/// `Info.plist` (`ClerkPublishableKey`) overrides the compiled default, in that
/// order, for one-off dev/CI needs.
///
/// Sign-in gates the whole app (see `AuthGateWindow` / `AppDelegate`), so a
/// missing/placeholder key leaves the app locked with a clear "add your key"
/// message rather than crashing: we never hand a bogus key to `Clerk.configure`,
/// whose validation would `assertionFailure` in debug builds.
enum ClerkConfig {
    /// Production Clerk instance (whisper.corkkam.com) — stable + beta users.
    private static let liveKey = "pk_live_Y2xlcmsud2hpc3Blci5jb3Jra2FtLmNvbSQ"
    /// Development Clerk instance (sweeping-humpback-68) — internal dev builds.
    private static let devKey = "pk_test_c3dlZXBpbmctaHVtcGJhY2stNjguY2xlcmsuYWNjb3VudHMuZGV2JA"

    /// True for the production-instance clients: the shipping `…mac` bundle and
    /// the side-by-side `…beta` bundle. Anything else — the `…mac.dev` build or a
    /// bundle-less CLI run — is a dev-instance client. (See `BuildEnvironment`.)
    private static var usesLiveInstance: Bool { BuildEnvironment.isProduction }

    /// The compiled default key for this build, before any override.
    private static var defaultKey: String { usesLiveInstance ? liveKey : devKey }

    /// A candidate publishable key is usable only if it's a real Clerk key.
    private static func validated(_ raw: String?) -> String? {
        guard let key = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty,
              !key.contains("REPLACE"),   // shipped Info.plist placeholder
              key.hasPrefix("pk_")        // real keys are pk_test_… / pk_live_…
        else { return nil }
        return key
    }

    /// The resolved publishable key: env override → Info.plist → compiled default.
    static let publishableKey: String? = {
        validated(ProcessInfo.processInfo.environment["CLERK_PUBLISHABLE_KEY"])
            ?? validated(Bundle.main.object(forInfoDictionaryKey: "ClerkPublishableKey") as? String)
            ?? defaultKey
    }()

    /// True once a real publishable key is present (always true now that a
    /// compiled default exists, but kept as the gate other code checks).
    static var isConfigured: Bool { publishableKey != nil }

    /// Configure the shared Clerk instance exactly once, at app launch, before
    /// anything reads `Clerk.shared`. No-op (app stays gated) without a key.
    @MainActor
    static func configureIfPossible() {
        guard let key = publishableKey else {
            Log.auth.error(
                "Clerk publishable key missing — set ClerkPublishableKey in Info.plist or the CLERK_PUBLISHABLE_KEY env var. The app stays locked until it's provided.")
            return
        }
        let instance = usesLiveInstance ? "live" : "dev"
        Clerk.configure(publishableKey: key)
        Log.auth.notice("Clerk configured (\(instance, privacy: .public) instance); loading session…")
    }
}
