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
/// Kept small. The tool list is prompt text the on-device model has to hold in its
/// head alongside the connector tools. "Three" was a convention, not a measured limit:
/// the limit is now the whole prompt's tool count, `ToolPackRouter.limit`, from the
/// Phase 0 sweep, and these tools are never the ones it leaves out.
///
/// `all` is what every run offers. `readSelection` is offered only when the chord
/// captured a selection, so it is outside `all` and inside `names`, which is what
/// `CommandToolRouter` dispatches on.
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

    static let readSelection = ToolDescriptor(
        name: "read_selection",
        summary: "Read the text the user selected. Use this when they say \"this\" or ask about their selection.",
        access: .local,
        capability: nil,
        targetArg: nil,
        parameters: [])

    static let names: Set<String> = Set((all + [readSelection]).map(\.name))

    static func descriptor(named name: String) -> ToolDescriptor? {
        (all + [readSelection]).first { $0.name == name }
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
    /// What the user had selected when they held the chord, or nil.
    var selection: SelectionContext?
    /// The run's taint flag, shared with its `ToolRouter`. A selection is often
    /// someone else's words, so reading it gates a later write the way a connector
    /// read does.
    var taint = Taint()
    /// Raises the connector approval card. Asked only in a tainted run, before a note
    /// or a reminder is saved. Nil where nobody can answer a card: a tainted save then
    /// fails rather than goes through unasked.
    var requestApproval: ((PendingApproval) async -> ApprovalOutcome)?

    static let stoppedBeforeSave = "Stopped before it ran, so nothing was saved."

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
        case "create_note":   return await createNote(call)
        case "create_reminder": return await createReminder(call)
        case "list_reminders": return (listReminders(), .read)
        case "read_selection": return readSelection()
        default:
            return (.failure("No such tool: \(call.tool)."), nil)
        }
    }

    // MARK: - Writes

    private func createNote(_ call: ToolCall) async -> (ToolResult, Effect?) {
        let body = (call.arguments["body"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            return (.failure("create_note needs a non-empty body."), nil)
        }
        let title = (call.arguments["title"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var shown = ["body": body]
        if !title.isEmpty { shown["title"] = title }
        let authorization: ToolAuthorization?, waited: Int
        switch await approveAfterRead(call.tool, arguments: shown) {
        case .stop(let result): return (result, nil)
        case .go(let granted, let wait): authorization = granted; waited = wait
        }
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
        return (ToolResult(ok: true, text: "Saved the note.", instanceLabels: [],
                           authorization: authorization, approvalMilliseconds: waited),
                .noteCreated)
    }

    private func createReminder(_ call: ToolCall) async -> (ToolResult, Effect?) {
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
        let body = (call.arguments["body"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // The card shows the time the app resolved, never the model's phrase.
        var shown = ["title": title, "due": ConnectorHTTP.iso8601(from: due)]
        if !body.isEmpty { shown["body"] = body }
        let authorization: ToolAuthorization?, waited: Int
        switch await approveAfterRead(call.tool, arguments: shown) {
        case .stop(let result): return (result, nil)
        case .go(let granted, let wait): authorization = granted; waited = wait
        }
        notes.upsertReminder(ReminderItem(
            title: title,
            body: body,
            dueDate: due,
            alertStyle: alertStyle,
            soundName: soundName))
        Analytics.shared.send(.reminderCreated(source: .agent, repeating: false))
        let text = "Reminder set for \(Self.stamp.string(from: due))."
        return (ToolResult(ok: true, text: text, instanceLabels: [],
                           authorization: authorization, approvalMilliseconds: waited),
                .reminderCreated(due: due, wasTimeStated: stated != nil))
    }

    private enum Gate {
        /// Save. The authorization is nil when no card was needed.
        case go(ToolAuthorization?, waited: Int)
        case stop(ToolResult)
    }

    /// After a read, a note or a reminder raises the connector card, scoped to This Mac
    /// like a device tool. The text it saves may come from what the run read, and a
    /// reminder shows that text in the notch with a sound. No grant is looked up, the
    /// card offers no Always, and an Always answer runs once. With no read, no card.
    private func approveAfterRead(_ tool: String, arguments: [String: String]) async -> Gate {
        guard taint.isSet else { return .go(nil, waited: 0) }
        let approval = PendingApproval(
            tool: tool,
            instanceID: DeviceToolCatalog.thisMacID,
            instanceLabel: DeviceToolCatalog.thisMacLabel,
            target: DeviceToolCatalog.thisMacLabel,
            arguments: arguments,
            grantOffered: false,
            grantable: false)
        // The card wraps the text onto three lines at most. Text it would cut is
        // refused rather than half-shown, as a link is.
        guard approval.detail.count <= ApprovalCopy.maxWrappedDetail else {
            return .stop(.failure("This run read text from your accounts or your selection, so "
                + "\(tool) needs the approval card, and the card can show at most "
                + "\(ApprovalCopy.maxWrappedDetail) characters. Make it shorter."))
        }
        guard let requestApproval else {
            return .stop(.failure("This run read text from your accounts or your selection, and "
                + "no approval card can be shown here, so nothing was saved."))
        }
        // A stopped run raises no card.
        guard !Task.isCancelled else { return .stop(.failure(Self.stoppedBeforeSave)) }
        let askedAt = now()
        let outcome = await requestApproval(approval)
        let waited = Int(now().timeIntervalSince(askedAt) * 1000)
        switch outcome {
        case .denied:
            return .stop(ToolResult(ok: false, text: "The user declined that.", instanceLabels: [],
                                    authorization: .denied, approvalMilliseconds: waited))
        case .timedOut:
            return .stop(ToolResult(ok: false,
                                    text: "Nobody answered the approval card in time, so nothing was saved.",
                                    instanceLabels: [], authorization: .timedOut,
                                    approvalMilliseconds: waited))
        case .allowedOnce, .allowedAlways:
            break
        }
        // A cancel that arrived while the card waited stops the save.
        guard !Task.isCancelled else {
            return .stop(ToolResult(ok: false, text: Self.stoppedBeforeSave, instanceLabels: [],
                                    approvalMilliseconds: waited))
        }
        return .go(.allowedOnce, waited: waited)
    }

    // MARK: - Reads

    private func listReminders() -> ToolResult {
        let rows = notes.activeReminders
            .prefix(10)
            .map { "\($0.displayTitle) — \(Self.stamp.string(from: $0.dueDate))" }
        let text = rows.isEmpty ? "No reminders are set." : rows.joined(separator: "\n")
        return ToolResult(ok: true, text: text, instanceLabels: [])
    }

    /// Only a read that returned text taints the run, as with a connector read.
    private func readSelection() -> (ToolResult, Effect?) {
        guard let selection else { return (.failure("No text is selected."), nil) }
        taint.isSet = true
        return (ToolResult(ok: true, text: selection.toolText, instanceLabels: []), .read)
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
