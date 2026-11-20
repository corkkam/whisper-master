import Foundation

/// The Microsoft identity platform client Outlook and Teams sign in with.
///
/// **Must be registered as a public client** ("Mobile and desktop applications" in
/// Entra ID ▸ App registrations ▸ Authentication, with "Allow public client flows"
/// on). Microsoft issues no secret to a public client and accepts the authorization
/// code + PKCE flow from it, which is the same honest posture `GoogleOAuthConfig`
/// describes: no secret travels inside the binary, and no broker sees the tokens.
///
/// Read from `Info.plist` `MicrosoftOAuthClientID` with an env override for dev, the
/// same pattern as Google. **Until a real id is set this stays dormant**:
/// `isConfigured` is false, `ProviderRegistry` withholds Teams and the Graph half of
/// Outlook, and Outlook stays the macOS Calendar connector it always was.
enum MicrosoftOAuthConfig {
    /// Which accounts the sign-in accepts. The `{tenant}` segment of both endpoints.
    enum Tenant: String, Sendable {
        /// Work, school **and** personal accounts — Outlook mail and calendar work
        /// for all three.
        case common
        /// Work and school only. Teams chats are not in Graph for a personal
        /// Microsoft account, so letting one sign in would only produce a connection
        /// that fails its first read; refusing it in Microsoft's own account picker
        /// is the honest place to say no.
        case organizations
    }

    static func authorizationEndpoint(_ tenant: Tenant) -> URL {
        URL(string: "https://login.microsoftonline.com/\(tenant.rawValue)/oauth2/v2.0/authorize")!
    }

    static func tokenEndpoint(_ tenant: Tenant) -> URL {
        URL(string: "https://login.microsoftonline.com/\(tenant.rawValue)/oauth2/v2.0/token")!
    }

    /// Application (client) id, or nil when unset/placeholder.
    static var clientID: String? {
        if let env = ProcessInfo.processInfo.environment["MICROSOFT_OAUTH_CLIENT_ID"],
           !isPlaceholder(env) { return env }
        if let plist = Bundle.main.object(forInfoDictionaryKey: "MicrosoftOAuthClientID") as? String,
           !isPlaceholder(plist) { return plist }
        return nil
    }

    static var isConfigured: Bool { clientID != nil }

    /// The redirect scheme: `msauth.app.whispermaster.mac`, on **every** channel.
    ///
    /// The `msauth.<bundle id>` shape is what Entra's own macOS redirect helper
    /// produces. It is pinned to the stable bundle id rather than read from
    /// `Bundle.main`, because `bundle.sh` re-badges the dev build's id *after* the
    /// plist is compiled — a derived scheme would then differ from the one
    /// `CFBundleURLTypes` declares, and the registration would need a second URI.
    /// The Google scheme is shared across channels the same way. Must match
    /// `Resources/Info.plist` `CFBundleURLTypes` and the registration's redirect URI;
    /// a mismatch fails in the browser with `AADSTS50011`, not here.
    static let redirectScheme = "msauth.app.whispermaster.mac"

    static var redirectURI: String { "\(redirectScheme)://auth" }

    /// Delegated Graph scopes. **None of these needs an administrator's consent**,
    /// which is the line every scope here was chosen against: a scope that does
    /// (`ChannelMessage.Read.All`, for one) stops most work accounts at a "Need admin
    /// approval" wall after the browser has already opened.
    enum Scope {
        /// A refresh token. Without it the connection dies an hour after it was made.
        static let offlineAccess = "offline_access"
        /// `/me`, so the instance can be labelled and deduped by address.
        static let userRead = "User.Read"
        static let mailRead = "Mail.Read"
        /// Read **and** write: "put it in my calendar" is a tool the assistant offers.
        static let calendarsReadWrite = "Calendars.ReadWrite"
        /// 1:1 and group chats, with their last-message preview.
        static let chatRead = "Chat.Read"
        static let chatMessageSend = "ChatMessage.Send"

        /// What the Outlook sign-in asks for: mail, calendar, and who you are.
        static let outlookConnect = [offlineAccess, userRead, mailRead, calendarsReadWrite]

        /// What the Teams sign-in asks for: read and post in chats, and who you are.
        /// Channels are deliberately absent — reading a channel's messages needs
        /// `ChannelMessage.Read.All`, which is admin-consent only.
        static let teamsConnect = [offlineAccess, userRead, chatRead, chatMessageSend]
    }

    /// What signing in for `kind` asks for, and which accounts it accepts. Shared by
    /// the connect step and the "Sign in again" repair, so a healed grant can do
    /// everything the original could.
    static func signIn(for kind: ConnectorKind) -> (scopes: [String], tenant: Tenant)? {
        switch kind {
        case .outlook: return (Scope.outlookConnect, .common)
        case .teams: return (Scope.teamsConnect, .organizations)
        default: return nil
        }
    }

    /// Reserved credential keys a Microsoft grant carries beside the tokens, so a
    /// refresh can be sent to the right endpoint without an instance in hand — the
    /// connect-time `validate` only has the credential bytes.
    enum CredentialKey {
        /// `"microsoft"` on a Microsoft grant. Absent means Google, which is what every
        /// grant stored before this existed is.
        static let issuer = "oauth_issuer"
        static let tenant = "oauth_tenant"
        /// The scopes the sign-in **asked for**, space-separated. A refresh re-asks
        /// for exactly these; the `scope` Microsoft echoes back omits
        /// `offline_access`, and re-requesting from it would drop the refresh token
        /// on the next rotation.
        static let requestedScope = "oauth_requested_scope"
        static let microsoftIssuer = "microsoft"
    }

    private static func isPlaceholder(_ value: String) -> Bool {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.isEmpty { return true }
        let lower = v.lowercased()
        return lower.contains("your_") || lower.contains("placeholder") || lower.hasPrefix("<")
            || lower.hasPrefix("$(")
    }
}

extension ConnectorCredential {
    /// Whether this grant was issued by Microsoft, and so refreshes there.
    var isMicrosoftGrant: Bool {
        self[MicrosoftOAuthConfig.CredentialKey.issuer] == MicrosoftOAuthConfig.CredentialKey.microsoftIssuer
    }
}
