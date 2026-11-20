import Foundation

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

/// The catalog **keys** the app knows about. The five the product leads with —
/// Gmail, Google Calendar, Outlook, Slack, iCal — are `isFeatured`; the rest are
/// the "popular connectors" surfaced below them.
///
/// A kind is a catalog entry, **not** a connection: the unit of connection is
/// `ConnectorInstance`, and there can be many per kind ("Google Calendar Personal",
/// "Google Calendar Work"). Everything about *how* a kind connects — auth method,
/// credential fields, capabilities — lives in its `ConnectorDescriptor`, so this
/// enum stays presentation metadata.
///
/// The `rawValue` is the stable persistence key (do not rename cases without a
/// migration — it's what `ConnectorInstance` encodes and what the legacy
/// `UserDefaults` migration reads).
enum ConnectorKind: String, CaseIterable, Identifiable, Codable, Sendable {
    // Featured (the ones the product names up front)
    case gmail
    case googleCalendar
    case outlook
    case slack
    case appleCalendar          // "iCal" / Apple Calendar + `.ics` subscriptions

    // Popular
    case teams
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
        case .teams: return "Microsoft Teams"
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
        case .gmail: return "Unread and recent mail, by a token you paste."
        case .googleCalendar: return "Today’s events. Read live from macOS Calendar or Google sign-in."
        case .outlook: return "Mail and calendar with Microsoft sign-in, or the calendar from macOS Calendar."
        case .slack: return "Recent messages across the channels your token can see."
        case .teams: return "Recent chats, read and answered with Microsoft sign-in."
        case .appleCalendar: return "Apple Calendar and any .ics subscription on this Mac."
        case .notion: return "Pages and databases shared with your integration."
        case .linear: return "Open issues assigned to you."
        case .googleDrive: return "Recent Drive files, by a token you paste."
        case .github: return "Open issues and PRs assigned to you."
        case .zoom: return "Today’s meetings from a server-to-server Zoom app."
        case .asana: return "Open tasks assigned to you."
        }
    }

    /// SF Symbol stand-in (no bundled brand marks yet — symbols keep it native).
    var icon: String {
        switch self {
        case .gmail: return "envelope"
        case .googleCalendar: return "calendar"
        case .outlook: return "envelope.badge"
        case .slack: return "number.square"
        case .teams: return "bubble.left.and.bubble.right"
        case .appleCalendar: return "calendar.badge.clock"
        case .notion: return "doc.text"
        case .linear: return "line.3.horizontal.decrease.circle"
        case .googleDrive: return "externaldrive"
        case .github: return "chevron.left.forwardslash.chevron.right"
        case .zoom: return "video"
        case .asana: return "checklist"
        }
    }

    var category: ConnectorCategory {
        switch self {
        case .appleCalendar, .googleCalendar: return .calendar
        case .gmail: return .mail
        case .outlook: return .mail          // Outlook straddles mail + calendar
        case .slack, .teams: return .messaging
        case .notion, .linear, .googleDrive, .github, .zoom, .asana: return .productivity
        }
    }

    /// The five the product leads with, in the order they should appear.
    static let featured: [ConnectorKind] = [.gmail, .googleCalendar, .outlook, .slack, .appleCalendar]

    var isFeatured: Bool { Self.featured.contains(self) }

    /// The "popular connectors" shown below the featured ones.
    static let popular: [ConnectorKind] = allCases.filter { !$0.isFeatured }
}
