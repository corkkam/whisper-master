import Observation
import SwiftUI

/// The catalog of things Whisper Master can (or one day will) connect to. Only
/// **calendar** is wired to a real backend (EventKit); the rest are honest
/// placeholders — the UI shows them as "Connect" and, once toggled on, "Needs
/// setup", so nothing pretends to work that doesn't.
enum ConnectorKind: String, CaseIterable, Identifiable {
    case calendar
    case reminders
    case notes
    case slack
    case email
    case notion

    var id: String { rawValue }

    var title: String {
        switch self {
        case .calendar: return "Calendar"
        case .reminders: return "Reminders"
        case .notes: return "Notes"
        case .slack: return "Slack"
        case .email: return "Email"
        case .notion: return "Notion"
        }
    }

    var subtitle: String {
        switch self {
        case .calendar: return "Show today's events on your agenda."
        case .reminders: return "Sync to-dos with Apple Reminders."
        case .notes: return "Send dictated notes to Apple Notes."
        case .slack: return "Dictate straight into a channel or DM."
        case .email: return "Draft mail with your voice."
        case .notion: return "Drop transcripts into a database."
        }
    }

    var iconSystemName: String {
        switch self {
        case .calendar: return "calendar"
        case .reminders: return "checklist"
        case .notes: return "note.text"
        case .slack: return "number"
        case .email: return "envelope"
        case .notion: return "doc.richtext"
        }
    }

    var tint: Color {
        switch self {
        case .calendar: return Theme.accent
        case .reminders: return Theme.accent2
        case .notes: return Theme.Accent.n600
        case .slack: return Theme.Accent2.n600
        case .email: return Theme.Accent.n400
        case .notion: return Theme.Neutral.n700
        }
    }

    /// Only the calendar connector talks to a real system today. The others are
    /// visible-but-unconfigured (they need a backend that doesn't exist yet).
    var isReal: Bool { self == .calendar }
}

/// Per-connector state for the Connectors screen. `calendar` is driven by the
/// real EventKit authorization; every other kind is a locally-persisted "the
/// user asked to connect this" flag that still surfaces as "Needs setup".
@MainActor
@Observable
final class ConnectorStore {
    static let enabledDefaultsKey = "WhisperMaster.enabledConnectors.v1"

    let calendar: CalendarConnector
    /// Raw values of non-calendar connectors the user has switched on.
    private(set) var enabled: Set<String>

    init() {
        self.calendar = CalendarConnector()
        let stored = UserDefaults.standard.stringArray(forKey: Self.enabledDefaultsKey) ?? []
        enabled = Set(stored)
    }

    /// A connector counts as "connected" when calendar access is granted, or a
    /// placeholder connector has been switched on by the user.
    func isConnected(_ kind: ConnectorKind) -> Bool {
        switch kind {
        case .calendar: return calendar.hasAccess
        default: return enabled.contains(kind.rawValue)
        }
    }

    /// Whether a connected connector still needs configuration to actually work.
    /// Calendar is fully functional once granted; placeholders never are (no
    /// backend), so they always read "Needs setup".
    func needsSetup(_ kind: ConnectorKind) -> Bool {
        switch kind {
        case .calendar: return false
        default: return isConnected(kind)
        }
    }

    var connected: [ConnectorKind] { ConnectorKind.allCases.filter { isConnected($0) } }
    var available: [ConnectorKind] { ConnectorKind.allCases.filter { !isConnected($0) } }

    /// Begin connecting. For calendar this prompts EventKit; for placeholders it
    /// records the intent (surfaced as "Needs setup").
    func connect(_ kind: ConnectorKind) async {
        switch kind {
        case .calendar:
            _ = await calendar.requestAccess()
        default:
            enabled.insert(kind.rawValue)
            persist()
        }
    }

    func disconnect(_ kind: ConnectorKind) {
        guard kind != .calendar else { return }   // calendar access is revoked in System Settings
        enabled.remove(kind.rawValue)
        persist()
    }

    func refresh() { calendar.refreshAuthorization() }

    private func persist() {
        UserDefaults.standard.set(Array(enabled), forKey: Self.enabledDefaultsKey)
    }
}
