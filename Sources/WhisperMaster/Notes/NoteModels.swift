import AppKit
import Foundation

/// How a reminder announces itself when it comes due.
enum ReminderAlertStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    /// A one-shot system notification banner carrying the chosen sound.
    case notification
    /// A looping sound plus a focused alert window that keeps ringing until the
    /// user acts (Snooze / Done).
    case alarm

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .notification: return "Notification"
        case .alarm: return "Loud alarm"
        }
    }
}

/// How often a reminder repeats. `nextDue(after:)` rolls a fired reminder to its
/// next occurrence (or nil for a one-off).
enum ReminderRepeat: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case daily
    case weekly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "Does not repeat"
        case .daily: return "Every day"
        case .weekly: return "Every week"
        }
    }

    /// The next fire date strictly after `date`, or nil for a non-repeating
    /// reminder. Uses the user's current calendar so DST shifts are honored.
    func nextDue(after date: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .none:
            return nil
        case .daily:
            return calendar.date(byAdding: .day, value: 1, to: date)
        case .weekly:
            return calendar.date(byAdding: .weekOfYear, value: 1, to: date)
        }
    }
}

/// Curated set of built-in macOS system sounds offered for reminder alerts. No
/// bundled assets — every name resolves via `NSSound(named:)`, and playback is
/// nil-safe (a missing sound simply does nothing), so the list can't crash.
enum ReminderSound {
    /// (systemName, human label) pairs, in menu order.
    static let options: [(name: String, label: String)] = [
        ("Glass", "Glass"),
        ("Ping", "Ping"),
        ("Sosumi", "Sosumi"),
        ("Submarine", "Submarine"),
        ("Funk", "Funk"),
        ("Basso", "Basso"),
        ("Hero", "Hero"),
        ("Blow", "Blow"),
    ]

    /// The default sound used when none is set / a stored name no longer resolves.
    static let defaultName = "Glass"

    static var names: [String] { options.map(\.name) }

    /// A safe sound name: the input if it's one we offer, else the default.
    static func resolved(_ name: String) -> String {
        names.contains(name) ? name : defaultName
    }

    static func label(for name: String) -> String {
        options.first(where: { $0.name == name })?.label ?? name
    }
}

/// A freeform note. `updatedAt` drives last-writer-wins sync; `deletedAt` is a
/// soft-delete tombstone so a delete propagates across Macs instead of a pulled
/// remote copy resurrecting it.
struct Note: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var title: String
    var body: String
    let createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    init(
        id: UUID = UUID(),
        title: String = "",
        body: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    var isDeleted: Bool { deletedAt != nil }

    /// A one-line label for lists — the title, or the first line of the body.
    var displayTitle: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        let firstLine = body.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Untitled note" : trimmed
    }
}

/// A time-based reminder. Named `ReminderItem` (never bare `Reminder`) to stay
/// clear of the unrelated gentle notch-nudge system in `Reminders/`.
struct ReminderItem: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var title: String
    var body: String
    var dueDate: Date
    var alertStyle: ReminderAlertStyle
    var soundName: String
    var repeatRule: ReminderRepeat
    var isCompleted: Bool
    /// When this reminder last fired, so the poll loop fires each occurrence once.
    var firedAt: Date?
    let createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    init(
        id: UUID = UUID(),
        title: String = "",
        body: String = "",
        dueDate: Date = Date(),
        alertStyle: ReminderAlertStyle = .notification,
        soundName: String = ReminderSound.defaultName,
        repeatRule: ReminderRepeat = .none,
        isCompleted: Bool = false,
        firedAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.dueDate = dueDate
        self.alertStyle = alertStyle
        self.soundName = ReminderSound.resolved(soundName)
        self.repeatRule = repeatRule
        self.isCompleted = isCompleted
        self.firedAt = firedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    var isDeleted: Bool { deletedAt != nil }

    var displayTitle: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "Reminder" : t
    }

    /// Due, not yet fired for the current occurrence, still live. The poll loop
    /// uses this (via `NotesStore.dueReminders`) to decide when to alert.
    func isDue(asOf now: Date) -> Bool {
        guard !isCompleted, deletedAt == nil else { return false }
        guard dueDate <= now else { return false }
        // Fired already for this occurrence → don't re-alert. (Repeats advance
        // `dueDate` past `firedAt` when rolled forward, so this stays correct.)
        if let firedAt, firedAt >= dueDate { return false }
        return true
    }
}
