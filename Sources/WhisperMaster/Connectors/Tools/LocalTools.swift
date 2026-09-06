import Foundation

/// The tools that act on this Mac rather than on a connector: the user's own notes
/// and reminders.
///
/// These are what make the command chord (fn + control) an *agent* rather than a
/// classifier. Before them the chord ran a keyword gate that could only ever produce
/// a note or a reminder; with them the same reasoning model that answers a connector
/// question can also decide that what it heard was a reminder, and file it — through
/// exactly the same validated-call path a connector tool goes through, so a malformed
/// call is rejected here for the same reasons it is there.
///
/// Kept to three. The tool list is prompt text a 4-bit 3B model has to hold in its
/// head alongside the connector tools, and every extra line is one more thing for it
/// to pick wrong.
enum LocalToolCatalog {
    static let all: [ToolDescriptor] = [
        ToolDescriptor(
            name: "create_note",
            summary: "Save a note. Use this when the user is recording a thought with no time attached.",
            access: .local,
            capability: nil,
            targetArg: nil,
            parameters: [
                ToolParameter("body", isRequired: true,
                              description: "The note's content, in the user's own words."),
                ToolParameter("title", isRequired: false,
                              description: "A short title. Omit if the body says it all."),
            ]),

        ToolDescriptor(
            name: "create_reminder",
            summary: "Set a reminder. Use this whenever the user wants to be reminded, or names a time.",
            access: .local,
            capability: nil,
            targetArg: nil,
            parameters: [
                ToolParameter("title", isRequired: true,
                              description: "What to be reminded about."),
                ToolParameter("when", isRequired: false,
                              description: "When, in the user's own words: \"tomorrow morning\", \"in 20 minutes\"."),
                ToolParameter("body", isRequired: false,
                              description: "Any extra detail."),
            ]),

        ToolDescriptor(
            name: "list_reminders",
            summary: "List the user's upcoming reminders.",
            access: .local,
            capability: nil,
            targetArg: nil,
            parameters: []),
    ]

    static let names: Set<String> = Set(all.map(\.name))

    static func descriptor(named name: String) -> ToolDescriptor? {
        all.first { $0.name == name }
    }
}

/// Runs a `LocalToolCatalog` call against the notes store.
///
/// Reports back in the same shape a connector tool does (`ToolResult`), so the loop
/// reads a local result and a remote one identically — and, crucially, so a local
/// call that couldn't do anything says so to the model rather than silently
/// succeeding.
///
/// `instanceLabels` stays **empty**: it feeds the notch's "From …" provenance line,
/// and naming the user's own notes as a source there would read as an integration
/// they don't have.
@MainActor
struct LocalToolRunner {
    /// What the user actually said, and how it sounded — carried so a note the agent
    /// files keeps its provenance.
    ///
    /// The model's `body` argument is a *rewrite* of the capture ("in the user's own
    /// words" is an instruction a 3B follows loosely), so without this a spoken note
    /// would be stored as the model's paraphrase with no record of the original. The
    /// audio closure is `takeAudio`-shaped rather than a value because the recording
    /// is consumed on first use: one capture yields one recording, attached to
    /// whichever note it produced.
    struct VoiceContext {
        /// The verbatim transcript of the capture.
        var transcript: String
        /// Hand over this capture's recording for `noteID`, or nil if there isn't
        /// one. Called at most once.
        var takeAudio: (UUID) -> NoteAudio?

        init(transcript: String, takeAudio: @escaping (UUID) -> NoteAudio?) {
            self.transcript = transcript
            self.takeAudio = takeAudio
        }
    }

    let notes: NotesStore
    /// Alert style and sound a spoken reminder inherits — the user's defaults, the
    /// same ones the manual "Add reminder" uses.
    var alertStyle: ReminderAlertStyle = .notification
    var soundName: String = ReminderSound.defaultName
    var now: () -> Date = Date.init
    /// Nil when the runner isn't serving a voice capture (tests, and any future
    /// non-spoken caller) — the note is then filed with no transcript or audio.
    var voice: VoiceContext?

    /// What a call actually did, for the confirmation the notch shows afterwards.
    /// The answer text comes from the model; this is the app's own record of the
    /// side effect, which is what the caller trusts.
    enum Effect: Equatable, Sendable {
        case noteCreated
        case reminderCreated(due: Date, wasTimeStated: Bool)
        case read
    }

    func run(_ call: ToolCall) async -> (result: ToolResult, effect: Effect?) {
        switch call.tool {
        case "create_note":   return createNote(call)
        case "create_reminder": return createReminder(call)
        case "list_reminders": return (listReminders(), .read)
        default:
            return (.failure("No such tool: \(call.tool)."), nil)
        }
    }

    // MARK: - Writes

    private func createNote(_ call: ToolCall) -> (ToolResult, Effect?) {
        let body = (call.arguments["body"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            return (.failure("create_note needs a non-empty body."), nil)
        }
        let title = (call.arguments["title"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let id = UUID()
        let audio = voice?.takeAudio(id)
        notes.upsertNote(Note(
            id: id,
            title: title,
            body: body,
            transcript: voice?.transcript,
            audio: audio))
        // The agent path is the common one whenever the 3B is loaded, so counting
        // it apart from the deterministic gate is what shows how much of the
        // notes feature actually depends on the model being resident.
        Analytics.shared.send(.noteCreated(source: .agent, hasAudio: audio != nil))
        return (ToolResult(ok: true, text: "Saved the note.", instanceLabels: []), .noteCreated)
    }

    private func createReminder(_ call: ToolCall) -> (ToolResult, Effect?) {
        let title = (call.arguments["title"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            return (.failure("create_reminder needs a non-empty title."), nil)
        }
        let moment = now()
        // The model hands back the *phrase* the user spoke, never a timestamp: a 3B
        // asked for ISO-8601 invents plausible, wrong dates. `RelativeTimeParser` is
        // the deterministic reader, and an unparseable phrase falls back to the same
        // hour-out default the keyword path uses rather than guessing.
        let stated = call.arguments["when"].flatMap { RelativeTimeParser.parse($0, now: moment) }
        let due = stated ?? Self.defaultDue(now: moment)
        notes.upsertReminder(ReminderItem(
            title: title,
            body: (call.arguments["body"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            dueDate: due,
            alertStyle: alertStyle,
            soundName: soundName))
        Analytics.shared.send(.reminderCreated(source: .agent, repeating: false))
        let text = "Reminder set for \(Self.stamp.string(from: due))."
        return (ToolResult(ok: true, text: text, instanceLabels: []),
                .reminderCreated(due: due, wasTimeStated: stated != nil))
    }

    // MARK: - Reads

    private func listReminders() -> ToolResult {
        let rows = notes.activeReminders
            .prefix(10)
            .map { "\($0.displayTitle) — \(Self.stamp.string(from: $0.dueDate))" }
        let text = rows.isEmpty ? "No reminders are set." : rows.joined(separator: "\n")
        return ToolResult(ok: true, text: text, instanceLabels: [])
    }

    /// Due time for a reminder whose "when" wasn't stated (or couldn't be parsed):
    /// one hour out — the same default the manual "Add reminder" uses.
    static func defaultDue(now: Date) -> Date {
        Calendar.current.date(byAdding: .hour, value: 1, to: now) ?? now.addingTimeInterval(3600)
    }

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d MMM, h:mm a"
        return formatter
    }()
}
