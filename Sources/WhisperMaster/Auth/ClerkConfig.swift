import ClerkKit
import Foundation

/// Resolves the Clerk publishable key and configures the shared Clerk instance
/// once at launch.
///
/// The publishable key is client-safe — it only identifies your Clerk frontend
/// API and grants no privileged access — so it lives in `Info.plist` under
/// `ClerkPublishableKey`; a `CLERK_PUBLISHABLE_KEY` environment variable
/// overrides it for local dev without editing the plist.
///
/// Sign-in gates the whole app (see `AuthGateWindow` / `AppDelegate`), so a
/// missing or placeholder key leaves the app locked with a clear "add your key"
/// message rather than crashing: we never hand a bogus key to `Clerk.configure`,
/// whose validation would `assertionFailure` in debug builds.
enum ClerkConfig {
    /// The resolved publishable key, or `nil` when it hasn't been filled in.
    static let publishableKey: String? = {
        let raw = ProcessInfo.processInfo.environment["CLERK_PUBLISHABLE_KEY"]
            ?? (Bundle.main.object(forInfoDictionaryKey: "ClerkPublishableKey") as? String)
        guard let key = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty,
              !key.contains("REPLACE"),   // the shipped Info.plist placeholder
              key.hasPrefix("pk_")        // real keys are pk_test_… / pk_live_…
        else { return nil }
        return key
    }()

    /// True once a real publishable key is present.
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
        Clerk.configure(publishableKey: key)
        Log.auth.notice("Clerk configured; loading session…")
    }
}
