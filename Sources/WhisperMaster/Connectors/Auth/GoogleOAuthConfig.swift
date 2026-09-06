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

    /// Whether the **Gmail** one-click path is switched on in this build.
    ///
    /// Separate from `isConfigured` because the blocker is not the client id: Gmail's
    /// read scope is a Google *restricted* scope, so until this client clears brand
    /// verification **and** a CASA security assessment, only accounts listed as test
    /// users on the Cloud project can grant it — everyone else is stopped at an
    /// "app not verified" wall *after* being sent to the browser, which is a worse
    /// dead end than never offering the button.
    ///
    /// So the flow ships built but dark: off unless a build (or a dev shell) says
    /// otherwise, and the Gmail card keeps offering the manual-token path meanwhile.
    /// Flip `GoogleGmailOAuthEnabled` in `Info.plist` on the day verification lands —
    /// no other code changes.
    static var isGmailOAuthEnabled: Bool {
        if let env = ProcessInfo.processInfo.environment["GOOGLE_GMAIL_OAUTH"] {
            return isAffirmative(env)
        }
        if let plist = Bundle.main.object(forInfoDictionaryKey: "GoogleGmailOAuthEnabled") {
            if let flag = plist as? Bool { return flag }
            if let text = plist as? String { return isAffirmative(text) }
        }
        return false
    }

    /// Both halves must hold before the Gmail sign-in is offered anywhere.
    static var isGmailOAuthAvailable: Bool { isConfigured && isGmailOAuthEnabled }

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
    /// Gmail read is *restricted* and additionally needs a CASA assessment, which is
    /// why the Gmail flow is built but gated on `isGmailOAuthEnabled` and the manual
    /// paste path stays.
    enum Scope {
        /// **Required to list the account's calendars.** `calendarList.list` accepts
        /// only `calendar`, `calendar.readonly`, or the `calendar.calendarlist*`
        /// scopes — `calendar.events` is *not* among them, so a grant carrying events
        /// alone signs in fine and then 403s on the picker, which read as "this
        /// account has no calendars we can read". Ask for both.
        static let calendarReadonly = "https://www.googleapis.com/auth/calendar.readonly"
        /// Read + write events — only requested when the user connects for writing.
        static let calendarEvents = "https://www.googleapis.com/auth/calendar.events"
        /// Identifies the account so the instance can be labelled and deduped.
        static let userinfoEmail = "https://www.googleapis.com/auth/userinfo.email"

        /// What the sign-in flow asks for: list the calendars, read + write their
        /// events, and learn the account email to label the instance.
        static let calendarConnect = [calendarReadonly, calendarEvents, userinfoEmail]

        /// Read the mailbox. **Restricted** — see `isGmailOAuthEnabled`. Deliberately
        /// `gmail.readonly` and nothing wider: every Gmail scope that can read a message
        /// is restricted anyway, so a narrower one buys no easier review, and this app
        /// never sends mail.
        static let gmailReadonly = "https://www.googleapis.com/auth/gmail.readonly"

        /// What the Gmail sign-in asks for: read the mail, and learn the address so the
        /// instance can be labelled and deduped.
        static let gmailConnect = [gmailReadonly, userinfoEmail]
    }

    private static func isAffirmative(_ value: String) -> Bool {
        ["1", "true", "yes", "on"].contains(
            value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    private static func isPlaceholder(_ value: String) -> Bool {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.isEmpty { return true }
        let lower = v.lowercased()
        return lower.contains("your_") || lower.contains("placeholder") || lower.hasPrefix("<")
    }
}
