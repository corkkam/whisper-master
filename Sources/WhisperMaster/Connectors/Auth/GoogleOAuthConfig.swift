import Foundation

/// The Google OAuth client this app authenticates with.
///
/// **Must be an iOS-type client**, not a Desktop-type one. Google issues no client
/// secret for iOS clients, which is the only way a shipping desktop binary can run
/// PKCE honestly — a Desktop client's secret would have to travel inside the app,
/// where it isn't secret, and a broker to hold it was rejected (it would put
/// connector tokens through our infra and break the local-first promise).
///
/// Read from `Info.plist` `GoogleOAuthClientID` with an env override for dev,
/// mirroring how `ClerkConfig` and `AnalyticsConfig` read their keys. **Until a real
/// id is set this stays dormant** — `isConfigured` is false, `ProviderRegistry`
/// withholds the Google providers, and the catalog shows those kinds as not yet
/// available. Nothing pretends to work.
enum GoogleOAuthConfig {
    static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!

    /// Client id, or nil when unset/placeholder.
    static var clientID: String? {
        if let env = ProcessInfo.processInfo.environment["GOOGLE_OAUTH_CLIENT_ID"],
           !isPlaceholder(env) { return env }
        if let plist = Bundle.main.object(forInfoDictionaryKey: "GoogleOAuthClientID") as? String,
           !isPlaceholder(plist) { return plist }
        return nil
    }

    static var isConfigured: Bool { clientID != nil }

    /// The redirect URI for an iOS-type client: the **reversed** client id as a custom
    /// scheme. `140047576864-abc.apps.googleusercontent.com` →
    /// `com.googleusercontent.apps.140047576864-abc:/oauth2redirect`.
    ///
    /// The scheme half must also be declared in `Info.plist` `CFBundleURLTypes`, or
    /// macOS won't hand the callback back to us and the sign-in window will hang on
    /// the redirect — a silent failure with no error to read, which is why the
    /// derivation is a pure function with a test rather than inline string surgery.
    static func redirectScheme(forClientID clientID: String) -> String {
        let base = clientID.replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
        return "com.googleusercontent.apps.\(base)"
    }

    static var redirectScheme: String? {
        clientID.map(redirectScheme(forClientID:))
    }

    static var redirectURI: String? {
        redirectScheme.map { "\($0):/oauth2redirect" }
    }

    /// Read-only scopes. Calendar read is a *sensitive* scope (brand verification);
    /// Gmail read is *restricted* and needs a CASA assessment, which is why Gmail
    /// ships behind manual token paste rather than this flow.
    enum Scope {
        static let calendarReadonly = "https://www.googleapis.com/auth/calendar.readonly"
        /// Read + write events — only requested when the user connects for writing.
        static let calendarEvents = "https://www.googleapis.com/auth/calendar.events"
        /// Identifies the account so the instance can be labelled and deduped.
        static let userinfoEmail = "https://www.googleapis.com/auth/userinfo.email"
    }

    private static func isPlaceholder(_ value: String) -> Bool {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.isEmpty { return true }
        let lower = v.lowercased()
        return lower.contains("your_") || lower.contains("placeholder") || lower.hasPrefix("<")
    }
}
