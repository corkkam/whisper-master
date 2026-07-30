import Foundation

/// The catalog: one `ConnectorDescriptor` per `ConnectorKind`.
///
/// Every kind here is connectable **today**, by hand. That's the deliberate shape
/// borrowed from openworker: a manual credential-paste path with a real `validate()`
/// always exists, so no connector is gated behind an OAuth verification queue we
/// don't control. One-click OAuth (`supportsManagedOAuth`) is an *extra* path for
/// the one provider family where a secret-free public client is actually possible.
///
/// Why so few managed-OAuth entries: Slack, Notion, Zoom, Asana and Linear all
/// require a `client_secret` at token exchange and offer no public PKCE client. A
/// desktop app can only satisfy that by shipping the secret (it isn't secret) or
/// running a broker (rejected — it would put connector tokens through our infra and
/// break the app's local-first promise). So they're manual-paste, and the user
/// creates their own app/token, which is also the most private arrangement.
enum ConnectorCatalog {
    static let all: [ConnectorDescriptor] = [
        // MARK: - System-backed (no account, no network, works today)

        // The three calendar kinds are NOT interchangeable labels over one query
        // any more: each instance binds to a specific set of EKCalendars, and the
        // kind pre-filters which EKSource type the picker offers.
        ConnectorDescriptor(
            kind: .appleCalendar,
            authKind: .none,
            capabilities: [.events],
            fields: [],
            instructions: [
                "Pick which of this Mac's calendars this connector should read.",
                "Nothing leaves your Mac — the calendar is read locally through macOS.",
            ],
            aliases: ["ical", "apple", "icloud", "calendar", "subscription", "ics"],
            supportsManagedOAuth: false),

        ConnectorDescriptor(
            kind: .googleCalendar,
            authKind: .none,
            capabilities: [.events],
            fields: [],
            instructions: [
                "Add your Google account in macOS Calendar first (System Settings ▸ Internet Accounts).",
                "Then pick which of its calendars this connector should read.",
            ],
            aliases: ["gcal", "google", "calendar", "meetings", "schedule"],
            // The one kind with a real one-click path: sign in and read the Calendar API
            // directly, as an alternative to the EventKit route above. Gated at runtime
            // on `GoogleOAuthConfig.isConfigured`, so an unconfigured build shows only
            // the EventKit option rather than a button that dead-ends.
            supportsManagedOAuth: true),

        ConnectorDescriptor(
            kind: .outlook,
            authKind: .none,
            capabilities: [.events],
            fields: [],
            instructions: [
                "Add your Exchange/Outlook account in macOS Calendar first.",
                "Then pick which of its calendars this connector should read.",
            ],
            aliases: ["exchange", "microsoft", "office", "calendar", "mail", "365"],
            supportsManagedOAuth: false),

        // MARK: - Manual credential paste

        ConnectorDescriptor(
            kind: .gmail,
            authKind: .staticSecret,
            capabilities: [.mail],
            fields: [
                CredentialField("access_token", "OAuth access token",
                                help: "A Google OAuth token carrying a Gmail read scope."),
                CredentialField("account", "Email address", isSecret: false,
                                help: "Which mailbox this token belongs to.",
                                placeholder: "you@gmail.com"),
            ],
            instructions: [
                "Gmail's read scope is a Google *restricted* scope, so one-click sign-in needs a CASA security assessment we haven't completed.",
                "Until then, paste a token you've minted yourself (OAuth Playground or your own Cloud project).",
            ],
            aliases: ["mail", "email", "google", "inbox"],
            supportsManagedOAuth: false),

        ConnectorDescriptor(
            kind: .slack,
            authKind: .staticSecret,
            capabilities: [.messages],
            fields: [
                CredentialField("bot_token", "Bot token",
                                help: "Starts with xoxb-. From your Slack app's OAuth & Permissions page.",
                                placeholder: "xoxb-…"),
            ],
            instructions: [
                "Create a Slack app at api.slack.com/apps for your workspace.",
                "Add the scopes you want to read (channels:history, channels:read, users:read), then install it.",
                "Copy the Bot User OAuth Token and paste it here.",
                "Slack's OAuth needs a client secret, so there's no one-click path — your own app keeps the token yours.",
            ],
            aliases: ["chat", "messages", "workspace", "dm", "mentions"],
            supportsManagedOAuth: false),

        ConnectorDescriptor(
            kind: .notion,
            authKind: .staticSecret,
            capabilities: [.tasks, .files],
            fields: [
                CredentialField("api_token", "Internal integration token",
                                help: "Starts with secret_ or ntn_.",
                                placeholder: "ntn_…"),
            ],
            instructions: [
                "Create an internal integration at notion.so/my-integrations.",
                "Share the pages or databases you want readable with that integration.",
                "Paste its token here.",
            ],
            aliases: ["notes", "docs", "wiki", "pages", "database"],
            supportsManagedOAuth: false),

        ConnectorDescriptor(
            kind: .linear,
            authKind: .staticSecret,
            capabilities: [.tasks],
            fields: [
                CredentialField("api_key", "Personal API key",
                                help: "Linear ▸ Settings ▸ Security & access ▸ Personal API keys.",
                                placeholder: "lin_api_…"),
            ],
            instructions: [
                "Open Linear ▸ Settings ▸ Security & access ▸ Personal API keys.",
                "Create a key and paste it here.",
            ],
            aliases: ["issues", "tickets", "tasks", "sprint", "backlog"],
            supportsManagedOAuth: false),

        ConnectorDescriptor(
            kind: .github,
            authKind: .staticSecret,
            capabilities: [.tasks],
            fields: [
                CredentialField("token", "Personal access token",
                                help: "A fine-grained token with read access to the repos you care about.",
                                placeholder: "github_pat_…"),
            ],
            instructions: [
                "Open GitHub ▸ Settings ▸ Developer settings ▸ Personal access tokens.",
                "Create a fine-grained token with read access to issues and pull requests.",
                "Paste it here.",
            ],
            aliases: ["git", "issues", "prs", "reviews", "code"],
            supportsManagedOAuth: false),

        ConnectorDescriptor(
            kind: .googleDrive,
            authKind: .staticSecret,
            capabilities: [.files],
            fields: [
                CredentialField("access_token", "OAuth access token",
                                help: "A Google OAuth token carrying a Drive read scope."),
                CredentialField("account", "Email address", isSecret: false,
                                help: "Which Google account this token belongs to.",
                                placeholder: "you@gmail.com"),
            ],
            instructions: [
                "Paste a Google OAuth token with drive.readonly (or drive.metadata.readonly).",
            ],
            aliases: ["drive", "files", "docs", "sheets", "google"],
            supportsManagedOAuth: false),

        ConnectorDescriptor(
            kind: .zoom,
            authKind: .mintedToken,
            capabilities: [.events],
            fields: [
                CredentialField("account_id", "Account ID", isSecret: false,
                                help: "From your Zoom server-to-server OAuth app."),
                CredentialField("client_id", "Client ID", isSecret: false),
                CredentialField("client_secret", "Client secret"),
            ],
            instructions: [
                "Create a Server-to-Server OAuth app at marketplace.zoom.us.",
                "Add the meeting:read scope and activate it.",
                "Paste the Account ID, Client ID and Client secret here — we mint a fresh short-lived token per request rather than storing one.",
            ],
            aliases: ["meetings", "video", "calls", "join link"],
            supportsManagedOAuth: false),

        ConnectorDescriptor(
            kind: .asana,
            authKind: .staticSecret,
            capabilities: [.tasks],
            fields: [
                CredentialField("api_token", "Personal access token",
                                help: "Asana ▸ Settings ▸ Apps ▸ Manage developer apps."),
            ],
            instructions: [
                "Open Asana ▸ Settings ▸ Apps ▸ Manage developer apps ▸ Personal access tokens.",
                "Create a token and paste it here.",
            ],
            aliases: ["tasks", "projects", "todo", "due"],
            supportsManagedOAuth: false),
    ]

    private static let byKind: [ConnectorKind: ConnectorDescriptor] =
        Dictionary(uniqueKeysWithValues: all.map { ($0.kind, $0) })

    /// The descriptor for a kind. Non-optional: every `ConnectorKind` case has a
    /// catalog entry, and a missing one is a programmer error caught in tests
    /// (`testEveryKindHasADescriptor`) rather than something callers unwrap.
    static func descriptor(for kind: ConnectorKind) -> ConnectorDescriptor {
        guard let found = byKind[kind] else {
            preconditionFailure("no descriptor for connector kind \(kind.rawValue)")
        }
        return found
    }

    /// Every kind that can be read for a given capability — the set fan-out draws
    /// from before filtering to enabled instances.
    static func kinds(providing capability: ConnectorCapability) -> [ConnectorKind] {
        all.filter { $0.capabilities.contains(capability) }.map(\.kind)
    }

    /// Catalog typeahead: match the display name, the blurb, or an alias.
    static func search(_ query: String) -> [ConnectorDescriptor] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter { descriptor in
            descriptor.kind.displayName.lowercased().contains(q)
                || descriptor.kind.blurb.lowercased().contains(q)
                || descriptor.aliases.contains { $0.contains(q) }
        }
    }
}
