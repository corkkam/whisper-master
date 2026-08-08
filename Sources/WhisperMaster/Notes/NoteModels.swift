import AppKit
import Foundation

/// How a reminder announces itself when it comes due.
enum ReminderAlertStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    /// A one-shot notch band carrying the chosen sound. (It used to be a system
    /// notification; the raw value is unchanged so stored reminders still decode.)
    case notification
    /// A looping sound plus a focused alert window that keeps ringing until the
    /// user acts (Snooze / Done).
    case alarm

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .notification: return "Notch banner"
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

/// Which editor a "new…" request wants opened. Set on `AppState` by a surface
/// that can't compose text itself — the notch quick-actions panel is a
/// non-activating panel on the bezel, so typing has to happen in the real window —
/// and consumed by `NotesSettingsView`, which owns the editor sheets.
enum NotesComposerRequest: String, Identifiable, Equatable, Sendable {
    case note
    case reminder

    var id: String { rawValue }
}

/// The voice recording behind a spoken note: the WAV file it was captured to, and
/// how long it runs.
///
/// Only the **file name** is stored, never a path — the notes JSON syncs across
/// Macs and an absolute path from another machine would be meaningless (and a
/// stored path is a stored trust boundary). `NoteAudioStore` resolves it against
/// the local audio directory, so a note pulled from another Mac simply reports no
/// playable audio rather than pointing somewhere wrong.
struct NoteAudio: Codable, Equatable, Sendable {
    /// Bare file name, e.g. `<uuid>.wav`.
    var fileName: String
    var durationMs: Int

    var duration: TimeInterval { Double(durationMs) / 1000 }
}

/// A freeform note. `updatedAt` drives last-writer-wins sync; `deletedAt` is a
/// soft-delete tombstone so a delete propagates across Macs instead of a pulled
/// remote copy resurrecting it.
///
/// **Decoding is hand-written and must stay that way.** Notes are already on disk
/// (and in the sync dashboard) from before pinning, transcripts and audio existed,
/// and the synthesized `Codable` conformance treats a missing non-optional key as
/// a *decode error* — so adding `isPinned` alone would have made every stored note
/// undecodable and silently emptied the store (`loadFromDisk` swallows the throw).
/// Every field added from here on gets `decodeIfPresent` with a default.
struct Note: Identifiable, Codable, Equatable, Sendable {
    /// How many sticky tints the palette offers. Lives here rather than in `Theme`
    /// so the *stored* colour survives a palette reshuffle in the UI layer, and so
    /// the model stays free of any UI import.
    static let paletteSize = 5

    let id: UUID
    var title: String
    var body: String
    let createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?
    /// Pinned notes ride at the front of the canvas and appear on the notch band.
    var isPinned: Bool
    /// What the user actually *said*, verbatim, when the note was created by voice.
    /// Kept beside `body` rather than replacing it: the assistant rewrites a spoken
    /// sentence into a title plus a tidied body, and the original wording is the
    /// only record of what was really said. Nil for a typed note.
    var transcript: String?
    /// The recording of that dictation, if one was captured.
    var audio: NoteAudio?
    /// Which sticky tint this note wears. Stored, not derived at render time —
    /// `UUID.hashValue` is seeded per process, so a hash-derived colour would
    /// change on every launch and the canvas would never look the same twice.
    var colorIndex: Int

    init(
        id: UUID = UUID(),
        title: String = "",
        body: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil,
        isPinned: Bool = false,
        transcript: String? = nil,
        audio: NoteAudio? = nil,
        colorIndex: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.isPinned = isPinned
        self.transcript = transcript
        self.audio = audio
        self.colorIndex = colorIndex ?? Self.defaultColorIndex(for: id)
    }

    /// A stable tint for an id — the first byte of the UUID, which (unlike
    /// `hashValue`) is the same in every process and on every Mac, so a note keeps
    /// its colour across launches and across a sync.
    static func defaultColorIndex(for id: UUID) -> Int {
        Int(id.uuid.0) % paletteSize
    }

    enum CodingKeys: String, CodingKey {
        case id, title, body, createdAt, updatedAt, deletedAt
        case isPinned, transcript, audio, colorIndex
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        body = try c.decode(String.self, forKey: .body)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
        isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        transcript = try c.decodeIfPresent(String.self, forKey: .transcript)
        audio = try c.decodeIfPresent(NoteAudio.self, forKey: .audio)
        colorIndex = try c.decodeIfPresent(Int.self, forKey: .colorIndex)
            ?? Self.defaultColorIndex(for: id)
    }

    var isDeleted: Bool { deletedAt != nil }

    /// Whether this note carries a playable recording.
    var hasAudio: Bool { audio != nil }

    /// The verbatim transcript, but only when it says something the body doesn't —
    /// the assistant often leaves the body identical to what was said, and showing
    /// the same sentence twice under a "what you said" label reads as a bug.
    var distinctTranscript: String? {
        guard let transcript else { return nil }
        let spoken = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else { return nil }
        return spoken.caseInsensitiveCompare(
            body.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame ? nil : spoken
    }

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
///
/// Unlike `Note`, this keeps the **synthesized** `Codable` conformance — which is
/// only safe because every field added since the first release is an `Optional`
/// (`completedAt`), and the synthesized decoder uses `decodeIfPresent` for those.
/// Adding a non-optional field here would make every stored reminder undecodable
/// exactly the way it would for `Note`; if one is ever needed, hand-write the
/// conformance first.
struct ReminderItem: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var title: String
    var body: String
    var dueDate: Date
    var alertStyle: ReminderAlertStyle
    var soundName: String
    var repeatRule: ReminderRepeat
    var isCompleted: Bool
    /// When this reminder was ticked off, which is what orders the archive —
    /// "what did I just finish" is a recency question, and `dueDate` answers a
    /// different one (a task finished today can have been due last week).
    ///
    /// Optional rather than defaulted because it is genuinely unknown for
    /// reminders completed before this field existed; `NotesStore` falls back to
    /// `updatedAt` for those rather than sinking them to the bottom forever.
    var completedAt: Date?
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
        completedAt: Date? = nil,
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
        self.completedAt = completedAt
        self.firedAt = firedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    var isDeleted: Bool { deletedAt != nil }

    /// Whether ticking this off will archive it. A repeating reminder never
    /// completes — `NotesStore.completeReminder` rolls it to its next occurrence —
    /// so the UI has to promise the right outcome *before* the tap rather than
    /// explain the surprise after it.
    var isRepeating: Bool { repeatRule != .none }

    /// When this was finished, for archive ordering. Falls back to `updatedAt` for
    /// rows completed before `completedAt` was stored — the completion *was* the
    /// last write for those, so it's the closest true answer available.
    var archivedAt: Date { completedAt ?? updatedAt }

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
