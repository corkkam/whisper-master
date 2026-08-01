import Foundation

/// Which kind of thing a spoken command is asking to create.
enum VoiceCommandKind: String, Equatable, Sendable {
    case note
    case reminder
}

/// The result of the cheap deterministic gate: a finished transcript that *looks*
/// like a "remind me…" / "add a note…" command, with the trigger phrase stripped.
struct DetectedCommand: Equatable, Sendable {
    let kind: VoiceCommandKind
    /// The transcript with the leading trigger phrase (and any ": / -" connector)
    /// removed — the raw content the command is about.
    let payload: String
}

/// A cheap, pure keyword gate over a finished transcript. It answers one question
/// — *which kind of thing is this command, and what are its words?* — without
/// touching any model, so a capture still files correctly when the on-device model
/// isn't loaded. Deliberately conservative: it only fires on a leading trigger
/// phrase, never mid-sentence.
///
/// It runs **only on a capture the user armed with the command chord** (fn +
/// control). An ordinary dictation is never inspected for triggers, so a sentence
/// that merely opens with "remind me to…" is typed like any other words.
enum CommandDetector {
    // Ordered loosely; `detect` sorts each list longest-first so the fullest
    // trigger wins ("remind me to" beats "remind me", leaving no dangling "to").
    private static let reminderTriggers = [
        "remind me to", "remind me that", "remind me",
        "set a reminder to", "set a reminder", "set reminder to", "set reminder",
        "add a reminder to", "add a reminder", "add reminder to", "add reminder",
        "create a reminder to", "create a reminder",
        "make a reminder to", "make a reminder",
        "reminder to",
    ]
    private static let noteTriggers = [
        "add a note that", "add a note to", "add a note saying", "add a note",
        "make a note that", "make a note to", "make a note saying", "make a note",
        "take a note that", "take a note",
        "new note that", "new note",
        "create a note that", "create a note",
        "save a note that", "save a note",
        "add note that", "add note",
        "note to self that", "note to self",
        "note that",
    ]

    /// Returns a `DetectedCommand` when the transcript opens with a recognized
    /// trigger phrase, else `nil`. Reminders are checked before notes so a phrase
    /// that could read as either ("remind me…") lands as a reminder.
    static func detect(_ text: String) -> DetectedCommand? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        if let cmd = match(trimmed, lower, triggers: reminderTriggers, kind: .reminder) { return cmd }
        if let cmd = match(trimmed, lower, triggers: noteTriggers, kind: .note) { return cmd }
        return nil
    }

    private static func match(
        _ original: String, _ lower: String, triggers: [String], kind: VoiceCommandKind
    ) -> DetectedCommand? {
        for trigger in triggers.sorted(by: { $0.count > $1.count }) {
            if lower == trigger || lower.hasPrefix(trigger + " ") {
                let start = original.index(original.startIndex, offsetBy: trigger.count)
                let rest = String(original[start...])
                let payload = stripLeadingConnector(rest.trimmingCharacters(in: .whitespacesAndNewlines))
                return DetectedCommand(kind: kind, payload: payload)
            }
        }
        return nil
    }

    /// Drop a leading ":" / "-" / "," a user might pause into ("note: buy milk").
    private static func stripLeadingConnector(_ text: String) -> String {
        var t = text
        while let first = t.first, first == ":" || first == "-" || first == "," {
            t.removeFirst()
            t = t.trimmingCharacters(in: .whitespaces)
        }
        return t
    }
}

/// The decision-maker's verdict on a finished transcript: what to do with it, and
/// the cleaned pieces to do it with. Produced either by the on-device qwen model
/// (via `IntentClassifier.parse`) or, when the model isn't loaded, by mapping a
/// `DetectedCommand`.
struct ClassifiedIntent: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case note
        case reminder
        /// Not actually a command — treat as ordinary dictation and paste it.
        case dictation
    }

    let kind: Kind
    let title: String
    let body: String
    /// A natural-language time expression the speaker gave ("tomorrow morning"),
    /// or `nil` when none was stated — in which case the app asks.
    let timePhrase: String?

    init(kind: Kind, title: String, body: String = "", timePhrase: String? = nil) {
        self.kind = kind
        self.title = title
        self.body = body
        self.timePhrase = timePhrase
    }

    /// Deterministic mapping used when the model isn't available: a detected
    /// command becomes an intent with the payload as its content and no time
    /// (so a reminder always asks "when?").
    init(_ detected: DetectedCommand) {
        switch detected.kind {
        case .note:
            self.init(kind: .note, title: "", body: detected.payload)
        case .reminder:
            self.init(kind: .reminder, title: detected.payload)
        }
    }

    /// The deterministic reading of a capture the user **explicitly armed** by
    /// holding the command chord (fn + control).
    ///
    /// Since the key press already said "this is a command", this never returns
    /// `.dictation`: a recognized trigger phrase picks the kind, and a capture with
    /// no trigger at all becomes a **note** — the kind that needs nothing but
    /// words, where a reminder would have to invent a time. So "take a note buy
    /// milk" and a bare "buy milk" both land, and neither gets typed into whatever
    /// the user happened to be looking at.
    static func armedCapture(of text: String) -> ClassifiedIntent {
        if let detected = CommandDetector.detect(text) {
            return ClassifiedIntent(detected)
        }
        return ClassifiedIntent(kind: .note, title: "", body: text)
    }
}

/// Parses the on-device model's JSON verdict into a `ClassifiedIntent`. Pure and
/// tolerant — it recovers the object even when the model wraps it in prose or code
/// fences, and treats a missing/empty/"none"/"null" time as "no time stated".
enum IntentClassifier {
    static func parse(_ raw: String) -> ClassifiedIntent? {
        guard let slice = extractJSONObject(raw),
              let data = slice.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let kindRaw = (obj["kind"] as? String)?.lowercased(),
              let kind = ClassifiedIntent.Kind(rawValue: kindRaw)
        else { return nil }

        let title = ((obj["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let body = ((obj["body"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        var timePhrase: String?
        if let t = (obj["time"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !t.isEmpty, !["null", "none", "n/a"].contains(t.lowercased()) {
            timePhrase = t
        }
        return ClassifiedIntent(kind: kind, title: title, body: body, timePhrase: timePhrase)
    }

    /// The smallest `{ … }` span from the first `{` to the last `}` — strips any
    /// ```json fences or stray preamble the model might emit around the object.
    private static func extractJSONObject(_ raw: String) -> String? {
        guard let start = raw.firstIndex(of: "{"),
              let end = raw.lastIndex(of: "}"),
              start < end
        else { return nil }
        return String(raw[start...end])
    }
}

/// A reminder awaiting its "when?" — surfaced in the notch as a quick-time prompt
/// after a spoken reminder command that didn't state a time. Transient (never
/// persisted); the banner turns it into a real `ReminderItem` once the user picks.
struct PendingReminderPrompt: Equatable, Sendable {
    let id: UUID
    var title: String
    var body: String

    init(id: UUID = UUID(), title: String, body: String = "") {
        self.id = id
        self.title = title
        self.body = body
    }

    var displayTitle: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "Reminder" : t
    }
}
