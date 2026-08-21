import Foundation

/// Per-instance configuration that is **not** a secret.
///
/// Typed rather than `[String: String]` on purpose: EventKit needs an *array* of
/// calendar identifiers, Slack a workspace id, Zoom an account id. A flat string map
/// forces JSON-encoded-inside-a-string for the array case, which rots the first time
/// anyone hand-edits the file. Each provider owns and decodes its own case.
///
/// Swift synthesises `Codable` for enums with associated values, so this persists
/// with no hand-written coding keys.
enum ConnectorConfig: Codable, Equatable, Sendable {
    /// EventKit: the calendars this instance is bound to, plus the account source
    /// they came from (shown as the instance's identity).
    ///
    /// **Empty `identifiers` means "every calendar"** — that's what the legacy
    /// migration produces, so a user upgrading sees exactly the behaviour they had
    /// before rather than a silently narrowed calendar.
    case calendars(identifiers: [String], sourceTitle: String)
    /// Google Calendar read through the **REST API** rather than EventKit. The same
    /// `googleCalendar` kind can have instances of both shapes at once — one reading
    /// what macOS already syncs, another reading the API directly — which is exactly
    /// why config is typed rather than a string map.
    case googleAPI(calendarIDs: [String])
    /// Connected through the app's own Google sign-in, with nothing else to configure
    /// (Gmail: the grant *is* the whole connection — there's one mailbox behind it).
    ///
    /// Carries no payload but is not `.empty`, because it is what distinguishes a
    /// refreshable grant from a pasted token on a kind whose descriptor says
    /// `.staticSecret` — see `ConnectorInstance.authKind`. Resolving one as a static
    /// secret would hand the provider a token nothing ever refreshes, and the
    /// connection would stop reading an hour after it was made.
    case googleOAuth
    /// Slack: the workspace this instance is bound to.
    case workspace(teamID: String)
    /// Zoom: the account whose token we mint per request.
    case account(accountID: String)
    /// Nothing to configure.
    case empty

    /// The EventKit calendars this config binds to, or nil if it isn't EventKit-backed.
    var calendarIdentifiers: [String]? {
        if case let .calendars(identifiers, _) = self { return identifiers }
        return nil
    }

    /// The Google API calendar ids, or nil if this isn't an API-backed config.
    var googleCalendarIDs: [String]? {
        if case let .googleAPI(ids) = self { return ids }
        return nil
    }

    /// Whether reads for this instance go over the network (so the caller must await).
    var isNetworkBacked: Bool {
        switch self {
        case .calendars, .empty: return false
        case .googleAPI, .googleOAuth, .workspace, .account: return true
        }
    }

    /// Whether this instance was connected by the app's own Google sign-in, and so
    /// holds a refreshable grant this app minted rather than a secret the user pasted.
    ///
    /// Both cases qualify: `.googleAPI` is the Calendar shape (it also names calendars),
    /// `.googleOAuth` the shape for a kind with nothing else to configure.
    var isManagedGoogleGrant: Bool {
        switch self {
        case .googleAPI, .googleOAuth: return true
        case .calendars, .workspace, .account, .empty: return false
        }
    }
}

/// A connector's failure state. Rendered on the instance row with a repair action —
/// **an instance never silently returns empty**, because "no events" and "we lost
/// access to your calendar" look identical to a user and mean opposite things.
enum ConnectorError: String, Codable, Equatable, Sendable {
    /// A calendar instance exists but macOS calendar access was never granted (or
    /// was revoked). Shared across every EventKit instance — it's one TCC grant.
    case needsCalendarAccess
    /// The bound calendars are gone. `EKCalendar.calendarIdentifier` is not stable
    /// across an account being removed and re-added, so this is an expected state,
    /// not corruption — the repair is to re-pick the calendars.
    case calendarMissing
    /// The stored credential was rejected by the provider.
    case credentialInvalid
    /// A refreshable grant expired and refresh failed (revoked, or scopes changed).
    case tokenExpired
    /// The provider is throttling us.
    case rateLimited
    /// We reached the network but the call didn't come back usable — a transport
    /// failure, or a status that isn't about the credential (a 4xx we mis-built, a
    /// 5xx on their side). Distinct from `credentialInvalid` because "reconnect"
    /// is the wrong advice here and re-authorising can't fix it.
    case unreachable

    /// One honest line for the instance row.
    var message: String {
        switch self {
        case .needsCalendarAccess: return "Calendar access isn't granted yet."
        case .calendarMissing: return "The calendars this was reading are no longer on this Mac."
        case .credentialInvalid: return "The saved credential was rejected."
        case .tokenExpired: return "Access expired and couldn't be renewed."
        case .rateLimited: return "Rate-limited. It'll recover on its own."
        case .unreachable: return "Couldn't read from this account just now."
        }
    }

    /// The repair affordance's title, or nil when there's nothing the user can do
    /// but wait.
    var repairTitle: String? {
        switch self {
        case .needsCalendarAccess: return "Allow"
        case .calendarMissing: return "Pick calendars"
        case .credentialInvalid, .tokenExpired: return "Reconnect"
        case .rateLimited, .unreachable: return nil
        }
    }
}

/// One named connection to one account.
///
/// This — not `ConnectorKind` — is the unit of connection. A kind is a catalog
/// entry; an instance is "Google Calendar Work", bound to specific calendars, with
/// its own credential and its own failure state. Many instances per kind is the
/// whole point.
///
/// **Secrets are never in this struct.** They live in the Keychain keyed by `id`
/// (see `ConnectorCredentials`), which is what makes the record safe to log, diff,
/// persist as plain JSON and render in the headless snapshot mode.
struct ConnectorInstance: Identifiable, Codable, Equatable, Sendable {
    /// Stable for the life of the connection; also the Keychain account key.
    let id: UUID
    /// The catalog entry this instantiates.
    let kind: ConnectorKind
    /// **User-editable.** Prefilled from `identity` at connect, renameable after.
    ///
    /// This is also the *spoken* handle ("what's on my work calendar"), which is why
    /// it's a mutable first-class field rather than something derived at render
    /// time — see `ConnectorLabelMatcher`.
    var label: String
    /// Derived at connect from the provider: an email, a workspace name, a calendar
    /// account title. Shown under the label so a renamed instance is still
    /// identifiable, and never itself editable.
    var identity: String
    var isEnabled: Bool
    var config: ConnectorConfig
    var connectedAt: Date
    /// Set by whatever last tried to read through this instance. Cleared on repair.
    var lastError: ConnectorError?

    init(id: UUID = UUID(),
         kind: ConnectorKind,
         label: String,
         identity: String,
         isEnabled: Bool = true,
         config: ConnectorConfig = .empty,
         connectedAt: Date = Date(),
         lastError: ConnectorError? = nil) {
        self.id = id
        self.kind = kind
        self.label = label
        self.identity = identity
        self.isEnabled = isEnabled
        self.config = config
        self.connectedAt = connectedAt
        self.lastError = lastError
    }

    var descriptor: ConnectorDescriptor { ConnectorCatalog.descriptor(for: kind) }

    /// How *this instance's* credential resolves — which is not always what the
    /// kind's descriptor says.
    ///
    /// `googleCalendar` is one kind with two shapes: an EventKit instance holds no
    /// credential at all (`authKind: .none`), while a signed-in API instance holds a
    /// refreshable OAuth grant. The config already decides which provider serves the
    /// instance, so it has to decide this too — resolving an API instance as `.none`
    /// hands the provider an **empty token**, `ConnectorHTTP` then omits the
    /// `Authorization` header entirely, and Google answers 403 "Method doesn't allow
    /// unregistered callers". That reads on the row as a rejected credential, when in
    /// fact the credential was never sent.
    ///
    /// `gmail` is the mirror-image case: its descriptor says `.staticSecret` (the
    /// pasted-token path, which is what an unverified build still offers), but an
    /// instance made by the Google sign-in holds a grant that must be refreshed. So a
    /// managed grant is decided *first* — deriving it from the descriptor alone gets
    /// one of the two shapes wrong whichever way the descriptor is written.
    var authKind: ConnectorAuthKind {
        if config.isManagedGoogleGrant { return .refreshableGrant }
        return config.isNetworkBacked && descriptor.authKind == .none
            ? .refreshableGrant
            : descriptor.authKind
    }

    var capabilities: Set<ConnectorCapability> { descriptor.capabilities }

    func provides(_ capability: ConnectorCapability) -> Bool {
        descriptor.capabilities.contains(capability)
    }

    /// Enabled *and* not in a failure state — the gate every read fans out through.
    var isReadable: Bool { isEnabled && lastError == nil }

    /// The label the user would recognise, falling back to the identity if they
    /// somehow cleared it.
    var displayLabel: String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? identity : trimmed
    }

    /// The suggested label for a fresh connection: the kind plus what it's an
    /// account of, e.g. "Google Calendar — sam@acme.com". The add sheet prefills
    /// this and the user usually shortens it to "Work".
    static func suggestedLabel(kind: ConnectorKind, identity: String) -> String {
        let id = identity.trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? kind.displayName : "\(kind.displayName) — \(id)"
    }
}
