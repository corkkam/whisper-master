import Foundation

/// How a connector authenticates / where its data actually comes from.
enum ConnectorAuth: Equatable, Sendable {
    /// Read through a macOS system framework the user has already granted (e.g.
    /// EventKit for calendars). No OAuth, no secrets — works locally. The macOS
    /// Calendar app already aggregates iCloud, Google, Exchange/Outlook and any
    /// `.ics` subscription, so a "Google Calendar" or "Outlook" calendar the user
    /// added there is readable this way with zero cloud round-trip.
    case system
    /// Needs an OAuth app registered with the provider (client id/secret) plus a
    /// user sign-in. **Not functional until credentials are configured** (see
    /// `OAuthConnectorConfig`) — the UI shows a "needs setup" state until then.
    case oauth
}

/// Coarse grouping used to lay the Connectors list out in sections.
enum ConnectorCategory: String, CaseIterable, Sendable {
    case calendar
    case mail
    case messaging
    case productivity

    var title: String {
        switch self {
        case .calendar: return "Calendars"
        case .mail: return "Mail"
        case .messaging: return "Messaging"
        case .productivity: return "Productivity"
        }
    }
}

/// The catalog of connectors the app knows about. The five the product leads
/// with — Gmail, Google Calendar, Outlook, Slack, iCal — are `isFeatured`; the
/// rest are the "popular connectors" surfaced below them.
///
/// The `rawValue` is the stable persistence key (do not rename cases without a
/// migration — it's what `ConnectorStore` writes to `UserDefaults`).
enum ConnectorKind: String, CaseIterable, Identifiable, Codable, Sendable {
    // Featured (the ones the product names up front)
    case gmail
    case googleCalendar
    case outlook
    case slack
    case appleCalendar          // "iCal" / Apple Calendar + `.ics` subscriptions

    // Popular
    case notion
    case linear
    case googleDrive
    case github
    case zoom
    case asana

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gmail: return "Gmail"
        case .googleCalendar: return "Google Calendar"
        case .outlook: return "Outlook"
        case .slack: return "Slack"
        case .appleCalendar: return "iCal"
        case .notion: return "Notion"
        case .linear: return "Linear"
        case .googleDrive: return "Google Drive"
        case .github: return "GitHub"
        case .zoom: return "Zoom"
        case .asana: return "Asana"
        }
    }

    /// One-line description shown under the name in Settings.
    var blurb: String {
        switch self {
        case .gmail: return "Unread and important mail in your day summary."
        case .googleCalendar: return "Today’s events. Read live from macOS Calendar."
        case .outlook: return "Calendar and mail. Calendar reads via macOS Calendar."
        case .slack: return "Mentions and unreads across your workspaces."
        case .appleCalendar: return "Apple Calendar and any .ics subscription on this Mac."
        case .notion: return "Pages and tasks assigned to you."
        case .linear: return "Issues assigned to you and due today."
        case .googleDrive: return "Recent and shared files."
        case .github: return "Review requests and assigned issues."
        case .zoom: return "Upcoming meetings and join links."
        case .asana: return "Tasks due today."
        }
    }

    /// SF Symbol stand-in (no bundled brand marks yet — symbols keep it native).
    var icon: String {
        switch self {
        case .gmail: return "envelope"
        case .googleCalendar: return "calendar"
        case .outlook: return "envelope.badge"
        case .slack: return "number.square"
        case .appleCalendar: return "calendar.badge.clock"
        case .notion: return "doc.text"
        case .linear: return "line.3.horizontal.decrease.circle"
        case .googleDrive: return "externaldrive"
        case .github: return "chevron.left.forwardslash.chevron.right"
        case .zoom: return "video"
        case .asana: return "checklist"
        }
    }

    var auth: ConnectorAuth {
        switch self {
        // Calendars come through EventKit (macOS Calendar aggregates the account
        // calendars), so they need no OAuth of our own.
        case .appleCalendar, .googleCalendar, .outlook: return .system
        default: return .oauth
        }
    }

    var category: ConnectorCategory {
        switch self {
        case .appleCalendar, .googleCalendar: return .calendar
        case .gmail: return .mail
        case .outlook: return .mail          // Outlook straddles mail + calendar
        case .slack: return .messaging
        case .notion, .linear, .googleDrive, .github, .zoom, .asana: return .productivity
        }
    }

    /// Whether this connector's data can flow into a day summary through EventKit
    /// (all the calendar-bearing ones). Used by `DaySummaryService`.
    var feedsCalendar: Bool {
        switch self {
        case .appleCalendar, .googleCalendar, .outlook: return true
        default: return false
        }
    }

    /// The five the product leads with, in the order they should appear.
    static let featured: [ConnectorKind] = [.gmail, .googleCalendar, .outlook, .slack, .appleCalendar]

    var isFeatured: Bool { Self.featured.contains(self) }

    /// The "popular connectors" shown below the featured ones.
    static let popular: [ConnectorKind] = allCases.filter { !$0.isFeatured }
}
