import Foundation

/// How one instance of a connector proves who it is.
///
/// This is the hinge the credential layer turns on: each case gets its own
/// `CredentialStrategy`, because "refresh a Google grant", "mint a Zoom token" and
/// "there is no credential at all" are genuinely different operations. Collapsing
/// them into "a token" is what forces empty-blob placeholders for EventKit and
/// pretend-refreshes for static tokens.
enum ConnectorAuthKind: String, Codable, Sendable {
    /// No credential whatsoever — the data comes through a macOS framework the
    /// user has already granted (EventKit). A first-class case, *not* an empty
    /// secret: `ConnectorCredentials` stores nothing for these instances.
    case none
    /// A static secret the user pastes (personal access token, bot token, internal
    /// integration token). Validated once at connect; there is nothing to refresh.
    case staticSecret
    /// An OAuth grant we can refresh on-device: access token + refresh token +
    /// expiry + scopes. Google only — see `supportsManagedOAuth`.
    case refreshableGrant
    /// Client credentials that *mint* a short-lived token on demand. We store the
    /// material, never a token (Zoom server-to-server: 1 hour expiry).
    case mintedToken
}

/// What an instance can actually be read for. Fan-out keys off **capability, not
/// kind** — `DaySummaryService` asks for every enabled instance providing
/// `.events` and merges, which is what makes two separately-named calendars show
/// up distinctly in one answer.
enum ConnectorCapability: String, Codable, Sendable, CaseIterable {
    case events
    case mail
    case messages
    case tasks
    case files
}

/// One credential input rendered by the add sheet. Mirrors openworker's `Field`:
/// the descriptor declares the form, so adding a connector is data rather than UI
/// code.
struct CredentialField: Identifiable, Hashable, Sendable {
    let key: String
    let label: String
    let isSecret: Bool
    let isRequired: Bool
    let help: String
    let placeholder: String

    init(_ key: String,
         _ label: String,
         isSecret: Bool = true,
         isRequired: Bool = true,
         help: String = "",
         placeholder: String = "") {
        self.key = key
        self.label = label
        self.isSecret = isSecret
        self.isRequired = isRequired
        self.help = help
        self.placeholder = placeholder
    }

    var id: String { key }
}

/// The data description of a connector kind — auth method, the fields the user
/// fills, what it can be read for, and how to explain it. Adding a connector is
/// (mostly) a new entry in `ConnectorCatalog`, not new UI.
///
/// Deliberately *not* a protocol: descriptors are inert data so the catalog can be
/// enumerated, searched and snapshot-rendered without touching a network or a
/// provider.
struct ConnectorDescriptor: Identifiable, Sendable {
    let kind: ConnectorKind
    let authKind: ConnectorAuthKind
    let capabilities: Set<ConnectorCapability>
    /// The credential form. Empty for `.none` auth (EventKit).
    let fields: [CredentialField]
    /// Step-by-step setup copy, shown above the form in the add sheet.
    let instructions: [String]
    /// Extra search terms for the catalog typeahead — capability words the title
    /// doesn't carry (so "mail" surfaces Outlook, not just Gmail).
    let aliases: [String]
    /// Whether one-click OAuth is genuinely available for this provider.
    ///
    /// **False for every provider that requires a `client_secret` at token
    /// exchange** — Slack, Notion, Zoom, Asana and Linear all do, and none of them
    /// support public PKCE clients. Since the app ships no broker to hold a secret,
    /// those are manual-paste only. Flipping this to `true` is a lie the add sheet
    /// would then tell the user.
    ///
    /// **Independent of `authKind`, not derived from it.** `googleCalendar` genuinely has
    /// *two* paths — read the calendars macOS already syncs (`authKind == .none`, no
    /// credential at all) *or* sign in and read the API directly (a refreshable grant).
    /// One `authKind` can't express both, so `authKind` describes the credential-free /
    /// manual path and this flag says whether a one-click path also exists.
    let supportsManagedOAuth: Bool

    var id: ConnectorKind { kind }

    /// Whether this connector reads through a macOS framework rather than the
    /// network — the "works today, no account needed" set.
    var isSystemBacked: Bool { authKind == .none }

    /// Whether the user can connect this at all right now. Everything with a
    /// credential form can be connected by hand; `.none` needs only a TCC grant.
    var isConnectable: Bool { authKind == .none || !fields.isEmpty }
}
