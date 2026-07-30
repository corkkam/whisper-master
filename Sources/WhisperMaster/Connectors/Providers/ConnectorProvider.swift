import Foundation

/// The outcome of checking a credential at connect time.
///
/// Connect is a **real call**, not a format check — openworker's key discipline. The
/// returned `identity` is what the add sheet prefills the label from, so a successful
/// connect can always tell the user *which* account they just linked.
struct ValidationResult: Equatable, Sendable {
    let isValid: Bool
    /// Human-readable account identity: an email, a workspace name, a calendar
    /// account title. Never a secret — it's rendered in the UI.
    let identity: String
    /// Why it failed, shown verbatim in the add sheet.
    let failure: String?

    static func valid(identity: String) -> ValidationResult {
        ValidationResult(isValid: true, identity: identity, failure: nil)
    }

    static func invalid(_ failure: String) -> ValidationResult {
        ValidationResult(isValid: false, identity: "", failure: failure)
    }
}

/// One connector kind's implementation. A kind without a provider is **not
/// connectable** — the catalog shows it as "Coming soon" rather than offering a
/// connection that can't read anything, which is precisely the failure mode this
/// redesign exists to remove.
///
/// `@MainActor` on the protocol itself, not just on conformers: EventKit is
/// main-actor-bound and the store these feed is `@MainActor @Observable`, so a
/// provider that wasn't would only be able to hand work back across a hop. Network
/// providers still do their I/O off the main actor inside an `async` method.
@MainActor
protocol ConnectorProvider: Sendable {
    static var kind: ConnectorKind { get }
    /// Check the credential against the real provider and report the identity.
    /// System-backed providers (EventKit) ignore the credential entirely.
    func validate(_ credential: ConnectorCredential,
                  config: ConnectorConfig) async -> ValidationResult
}

/// What a read produced, plus the failure state to record on the instance.
///
/// The error is returned rather than thrown so a fan-out can partially succeed: one
/// broken instance must not take down the whole day summary, but it also must not
/// disappear silently — it gets recorded and rendered on its own row.
struct ProviderReadOutcome<Value: Sendable>: Sendable {
    let value: Value
    let error: ConnectorError?

    init(_ value: Value, error: ConnectorError? = nil) {
        self.value = value
        self.error = error
    }
}

/// A provider that can answer "what's on the calendar".
///
/// Capability protocols rather than one fat provider interface: fan-out asks for
/// everything that can serve `.events`, and a Slack provider has no business
/// declaring an events method it would have to stub.
///
/// Isolation isn't inherited from a refined protocol, so `@MainActor` is restated.
@MainActor
protocol EventReadingProvider: ConnectorProvider {
    func todaysEvents(for instance: ConnectorInstance, now: Date) -> ProviderReadOutcome<[DayEvent]>
}

/// Which kinds actually have an implementation behind them.
///
/// This is the honesty gate for the whole catalog. `ConnectorCatalog` describes every
/// kind we intend to support; this registry says which ones can be connected *today*.
/// The UI reads it so a kind can never present a Connect button that leads to an
/// instance which returns nothing forever.
@MainActor
enum ProviderRegistry {
    private static let eventKit = EventKitCalendarProvider()
    private static let googleCalendar = GoogleCalendarProvider()
    private static let slack = SlackProvider()
    private static let linear = LinearProvider()
    private static let github = GitHubProvider()
    private static let notion = NotionProvider()
    private static let asana = AsanaProvider()

    /// Providers keyed by kind.
    ///
    /// `googleCalendar` has **two** implementations and the instance's config decides:
    /// a `.calendars` config reads through EventKit, a `.googleAPI` config through the
    /// REST API. Use `provider(for instance:)` wherever an instance is in hand.
    static func provider(for kind: ConnectorKind) -> (any ConnectorProvider)? {
        switch kind {
        case .appleCalendar, .outlook: return eventKit
        case .googleCalendar: return eventKit
        case .slack: return slack
        case .linear: return linear
        case .github: return github
        case .notion: return notion
        case .asana: return asana
        // Gmail, Drive and Zoom are catalogued but have no read implementation yet, so
        // they stay unconnectable rather than offering a connection that reads nothing.
        case .gmail, .googleDrive, .zoom: return nil
        }
    }

    /// The provider for a specific instance, honouring its config. This is the one to
    /// use for reads; `provider(for kind:)` is for the pre-connection catalog.
    static func provider(for instance: ConnectorInstance) -> (any ConnectorProvider)? {
        if instance.kind == .googleCalendar, instance.config.googleCalendarIDs != nil {
            return GoogleOAuthConfig.isConfigured ? googleCalendar : nil
        }
        return provider(for: instance.kind)
    }

    static func hasProvider(for kind: ConnectorKind) -> Bool {
        provider(for: kind) != nil
    }

    static func eventProvider(for instance: ConnectorInstance) -> (any EventReadingProvider)? {
        provider(for: instance) as? any EventReadingProvider
    }

    static func itemProvider(for instance: ConnectorInstance) -> (any ItemReadingProvider)? {
        provider(for: instance) as? any ItemReadingProvider
    }

    /// The API-backed Google provider, when the OAuth client is configured. Nil keeps
    /// the one-click path out of the UI entirely rather than letting it fail mid-flow.
    static var googleCalendarAPI: GoogleCalendarProvider? {
        GoogleOAuthConfig.isConfigured ? googleCalendar : nil
    }

    /// Catalog entries the user can actually connect right now.
    static var connectableKinds: [ConnectorKind] {
        ConnectorKind.allCases.filter(hasProvider(for:))
    }
}
