import Foundation

/// Which backend environment this build talks to, derived from the bundle id.
///
/// The production Clerk instance serves the real userbase — both the shipping
/// `app.whispermaster.mac` build and the side-by-side beta build (`…beta`).
/// Internal dev builds (`dev-install.sh` rebrands to `…mac.dev`) and bundle-less
/// `swift build` CLI runs talk to the development Clerk instance instead, so dev
/// work never touches production accounts.
///
/// `ClerkConfig` uses this predicate to pick which publishable key to use.
enum BuildEnvironment {
    /// True for the production-instance clients: `…mac` and any `…beta` bundle.
    static var isProduction: Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        return id == "app.whispermaster.mac" || id.hasSuffix(".beta")
    }
}
