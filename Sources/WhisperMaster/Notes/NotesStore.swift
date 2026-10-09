import Foundation
import Observation

/// A saved voice note — a dictated snippet the user chose to keep, with an
/// optional title. Persisted locally (never leaves the Mac).
struct VoiceNote: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var body: String
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), title: String = "", body: String, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// A display title: the explicit one if set, else the first line of the body.
    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let firstLine = body.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? body
        let line = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        return line.isEmpty ? "Untitled note" : line
    }
}

/// A to-do / reminder item. Distinct from the app's notification "gentle
/// reminders" (`Reminders/`) — this is a user checklist item shown on Today and
/// in Notes & Reminders.
struct TodoReminder: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var dueAt: Date?
    var isCompleted: Bool
    var createdAt: Date

    init(id: UUID = UUID(), title: String, dueAt: Date? = nil, isCompleted: Bool = false, createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.dueAt = dueAt
        self.isCompleted = isCompleted
        self.createdAt = createdAt
    }
}

/// The store behind the Notes & Reminders screen and the Today agenda. Owns two
/// locally-persisted collections — dictated **voice notes** and **to-do
/// reminders** — with plain CRUD. `@Observable`, `@MainActor`; SwiftUI views
/// observe it directly.
@MainActor
@Observable
final class NotesStore {
    static let notesDefaultsKey = "WhisperMaster.voiceNotes.v1"
    static let remindersDefaultsKey = "WhisperMaster.todoReminders.v1"

    private(set) var notes: [VoiceNote] = []
    private(set) var reminders: [TodoReminder] = []

    init() {
        notes = Self.load([VoiceNote].self, key: Self.notesDefaultsKey) ?? []
        reminders = Self.load([TodoReminder].self, key: Self.remindersDefaultsKey) ?? []
    }

    // MARK: Voice notes

    @discardableResult
    func addNote(title: String = "", body: String) -> VoiceNote {
        let note = VoiceNote(title: title, body: body)
        notes.insert(note, at: 0)
        persistNotes()
        return note
    }

    func updateNote(_ id: UUID, title: String, body: String) {
        guard let idx = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[idx].title = title
        notes[idx].body = body
        notes[idx].updatedAt = Date()
        // Keep newest-edited first.
        let edited = notes.remove(at: idx)
        notes.insert(edited, at: 0)
        persistNotes()
    }

    func deleteNote(_ id: UUID) {
        notes.removeAll { $0.id == id }
        persistNotes()
    }

    /// Notes whose title or body match a search query (case-insensitive). Empty
    /// query returns everything.
    func notes(matching query: String) -> [VoiceNote] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return notes }
        return notes.filter {
            $0.title.lowercased().contains(q) || $0.body.lowercased().contains(q)
        }
    }

    // MARK: Reminders

    @discardableResult
    func addReminder(title: String, dueAt: Date? = nil) -> TodoReminder {
        let reminder = TodoReminder(title: title, dueAt: dueAt)
        reminders.append(reminder)
        persistReminders()
        return reminder
    }

    func completeReminder(_ id: UUID, completed: Bool = true) {
        guard let idx = reminders.firstIndex(where: { $0.id == id }) else { return }
        reminders[idx].isCompleted = completed
        persistReminders()
    }

    func toggleReminder(_ id: UUID) {
        guard let idx = reminders.firstIndex(where: { $0.id == id }) else { return }
        reminders[idx].isCompleted.toggle()
        persistReminders()
    }

    func deleteReminder(_ id: UUID) {
        reminders.removeAll { $0.id == id }
        persistReminders()
    }

    /// Incomplete reminders, soonest-due first (undated last), for the checklist.
    var visibleReminders: [TodoReminder] {
        reminders
            .filter { !$0.isCompleted }
            .sorted { lhs, rhs in
                switch (lhs.dueAt, rhs.dueAt) {
                case let (l?, r?): return l < r
                case (nil, _?): return false
                case (_?, nil): return true
                case (nil, nil): return lhs.createdAt < rhs.createdAt
                }
            }
    }

    /// Reminders due on or before the end of `asOf`'s day (plus any undated),
    /// still incomplete — what Today surfaces.
    func dueReminders(asOf date: Date) -> [TodoReminder] {
        let endOfDay = Calendar.current.startOfDay(for: date).addingTimeInterval(24 * 3600)
        return visibleReminders.filter { reminder in
            guard let due = reminder.dueAt else { return true }
            return due < endOfDay
        }
    }

    // MARK: Persistence

    private func persistNotes() { Self.save(notes, key: Self.notesDefaultsKey) }
    private func persistReminders() { Self.save(reminders, key: Self.remindersDefaultsKey) }

    private static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(T.self, from: data)
    }

    private static func save<T: Encodable>(_ value: T, key: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    /// Seed in-memory sample data for headless snapshots (never persisted).
    func seedSampleData() {
        notes = [
            VoiceNote(title: "Standup notes",
                      body: "Shipped the Organic re-skin behind a flag. Blocked on calendar TCC prompt copy. Next: wire the Today agenda.",
                      createdAt: Date(timeIntervalSinceNow: -1800), updatedAt: Date(timeIntervalSinceNow: -1800)),
            VoiceNote(body: "Idea: let a long-press on the notch pin the last transcript so it survives the next dictation.",
                      createdAt: Date(timeIntervalSinceNow: -9000), updatedAt: Date(timeIntervalSinceNow: -9000)),
        ]
        reminders = [
            TodoReminder(title: "Reply to the design feedback thread", dueAt: Date(timeIntervalSinceNow: 3600)),
            TodoReminder(title: "Bump FluidAudio + re-run the audio replay bench", dueAt: Date(timeIntervalSinceNow: 7200)),
            TodoReminder(title: "Draft the release note for the warm theme"),
            TodoReminder(title: "Book the notary round-trip time into the release plan", isCompleted: true),
        ]
    }
}
