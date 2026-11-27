import Foundation

/// The words on the approval card.
///
/// The card used to render the tool's arguments exactly as the router had stamped
/// them — `end: 2026-08-08T09:30:00+05:30 · start: 2026-08-08T09:00:00+05:30 ·
/// title: Work · when: tomorrow at nine` — which is the payload, but not in a form
/// anyone can consent to at a glance on a notch-width row. Three of those four
/// fields are the *same* fact (a phrase, a resolved instant, and that instant plus
/// the duration), so the line spent its whole width restating one time in three
/// notations and then ran off both edges of the band.
///
/// So the payload is **presented**, not abbreviated: this renders the arguments a
/// tool is known to take into one short human line, and appends any argument it
/// doesn't recognise verbatim. That last rule is what keeps
/// `PendingApproval.arguments`' promise — a card that hides part of what will run
/// isn't consent to the action that runs — while a new argument on an existing tool
/// degrades to the old raw form rather than disappearing.
///
/// Pure and clock-injected, so `ApprovalCopyTests` can pin "Today" without waiting
/// for a particular date.
enum ApprovalCopy {
    /// The card's extra line in a run that read connector or selection text. The
    /// model still proposes writes built from what it read (an injected "I quit"
    /// message), and the card is then the only gate, so it asks for a real look
    /// rather than a habitual Once.
    static let readWarning = "I wrote this after reading text from your accounts. Check it first."

    /// The same line when the run's only read was the selection the chord captured,
    /// so the card does not claim an account was read.
    static let selectionReadWarning = "I wrote this after reading your selection. Check it first."

    /// Human verb for a tool name, so the card reads as a sentence rather than an
    /// identifier.
    static func verb(for tool: String) -> String {
        switch tool {
        case "send_message": return "Post to"
        case "create_calendar_event": return "Add an event to"
        case "update_calendar_event": return "Change"
        case "delete_calendar_event": return "Delete"
        case "open_app", "open_url", "open_file": return "Open"
        case "create_note": return "Save a note on"
        case "create_reminder": return "Set a reminder on"
        case "reply_message": return "Reply in"
        case "send_mail": return "Send mail from"
        case "reply_mail": return "Reply by mail from"
        // The target is the server's own tool name: "Run get_forecast on Weather".
        case _ where MCPToolMapping.isMCPTool(tool): return "Run"
        default: return "Run \(tool) on"
        }
    }

    /// The payload line of an `open_app` card. The app is the target, so it is in
    /// the headline; this says what a yes does.
    static let openAppDetail = "It comes to the front, or starts if it isn't running."

    /// Characters of a link one caption line holds on the wide card, rounded down so
    /// a reserved line is never short. `DeviceToolCatalog.maxURLLength` is three of
    /// these, which is the most the card reserves.
    static let linkCharactersPerLine = 50

    /// Tools whose payload is free text: a note, a reminder, a thread reply, a mail,
    /// a task handed to Claude Code and the arguments of an MCP call. Their card shows
    /// the whole text in a scroll area (`NotchApprovalBanner`), so nothing the user
    /// approves is cut and no length is refused.
    static func scrollsDetail(tool: String) -> Bool {
        MCPToolMapping.isMCPTool(tool)
            || ["create_note", "create_reminder", "reply_message", "send_mail", "reply_mail",
                DelegateToolCatalog.delegateTask.name].contains(tool)
    }

    /// Lines a scrolling payload shows before it scrolls. Kept small so the band stays
    /// a band: `NotchApprovalBanner.maxThickness` is charged for this many.
    static let maxVisibleScrollLines = 4

    /// Lines the text takes on the wide card, with each line break kept. An estimate,
    /// rounded against the text. It sets only the height of the scroll area: the
    /// card's fade is measured (`NotchApprovalBanner`), and a wrong estimate scrolls,
    /// never cuts.
    static func estimatedLines(_ detail: String) -> Int {
        detail.components(separatedBy: .newlines).reduce(0) { total, paragraph in
            let width = paragraph.reduce(0) { $0 + columns($1) }
            return total + max(1, (width + linkCharactersPerLine - 1) / linkCharactersPerLine)
        }
    }

    /// Columns a character takes in the estimate: two for an emoji and for an East
    /// Asian wide or full-width character, one for any other. A CJK note counted as
    /// one per character got a scroll area half its height.
    static func columns(_ character: Character) -> Int {
        let scalars = character.unicodeScalars
        if scalars.contains(where: { $0.value == 0xFE0F || $0.properties.isEmojiPresentation }) {
            return 2
        }
        guard let value = scalars.first?.value else { return 1 }
        return wideRanges.contains { $0.contains(value) } ? 2 : 1
    }

    private static let wideRanges: [ClosedRange<UInt32>] = [
        0x1100...0x115F,   // Hangul Jamo
        0x2E80...0xA4CF,   // CJK radicals through Yi
        0xAC00...0xD7A3,   // Hangul syllables
        0xF900...0xFAFF,   // CJK compatibility ideographs
        0xFE30...0xFE4F,   // CJK compatibility forms
        0xFF00...0xFF60,   // full-width forms
        0xFFE0...0xFFE6,   // full-width signs
        0x20000...0x3FFFD, // CJK extensions B and later
    ]

    /// Lines the payload may take: one, except a link, which wraps onto three rather
    /// than being cut because the end of a link is where a planted address hides (a
    /// calendar edit wraps the same way, so "This occurrence only" is never cut), and
    /// a note or a reminder, which shows up to `maxVisibleScrollLines` and scrolls.
    static func detailLines(tool: String, detail: String) -> Int {
        if scrollsDetail(tool: tool) {
            return min(maxVisibleScrollLines, max(1, estimatedLines(detail)))
        }
        guard tool == "open_url" || CalendarTools.editNames.contains(tool) else { return 1 }
        let lines = (detail.count + linkCharactersPerLine - 1) / linkCharactersPerLine
        return min(3, max(1, lines))
    }

    /// One line: what is about to happen, and where.
    ///
    /// **The target and the connection are only two things when they differ.**
    /// `create_calendar_event` scopes its grant to the connection itself
    /// (`targetArg` is the `connector` argument), so the old unconditional
    /// "<target> on <label>" rendered every calendar write as "Add an event to
    /// Personal on Personal" — a headline that reads like a bug and spends the
    /// band's width saying one name twice.
    static func headline(tool: String, target: String, instanceLabel: String) -> String {
        // A link's headline names the host, the part that decides, cut at its front so
        // the domain stays visible; the whole link is the payload line under it.
        // `open_url` refuses a host whose domain does not fit, so the fallback is
        // only for a card raised some other way.
        if tool == "open_url" {
            let host = URL(string: target)?.host() ?? target
            return DeviceToolCatalog.linkHeadline(host: host) ?? "Open \(host) in your browser"
        }
        // The event's title is the target; its connection is the calendar label.
        if CalendarTools.editNames.contains(tool) {
            return "\(verb(for: tool)) \(quoted(target)) on \(instanceLabel)"
        }
        // The task is the target and the payload line; the headline is where it goes.
        if tool == DelegateToolCatalog.delegateTask.name { return "Send to \(instanceLabel)" }
        // The server's tool name has no length limit, and a long one pushed the
        // server's label off the line: cut in the middle, so the label stays.
        if MCPToolMapping.isMCPTool(tool) {
            let name = FileToolCatalog.displayName(target, limit: MCPToolMapping.maxCardNameLength)
            return "Run \(name) on \(instanceLabel)"
        }
        // The recipients are whole in the scroll area. This one line cut a long address
        // or list at its tail, so it names the account the mail leaves from.
        if tool == "send_mail" || tool == "reply_mail" { return "\(verb(for: tool)) \(instanceLabel)" }
        let scope = target.compare(instanceLabel, options: .caseInsensitive) == .orderedSame
            ? instanceLabel
            : "\(target) on \(instanceLabel)"
        return "\(verb(for: tool)) \(scope)"
    }

    /// The payload, in the user's words rather than the router's. The target is left
    /// out — it's already in the headline, and it's the part that decides whether
    /// this is the right thing to approve.
    static func detail(tool: String,
                       arguments: [String: String],
                       calendar: Calendar = .current,
                       now: Date = Date()) -> String {
        // Every argument goes to the server, one named `connector` too.
        if MCPToolMapping.isMCPTool(tool) { return MCPToolMapping.cardDetail(arguments) }
        // Consumed as they're rendered; whatever is left over is unrecognised and
        // gets shown raw below.
        var remaining = arguments
        remaining[ToolDescriptor.instanceArgument] = nil
        var parts: [String] = []

        switch tool {
        case "create_calendar_event":
            if let title = remaining.removeValue(forKey: "title"), !title.isEmpty {
                parts.append(quoted(title))
            }
            let start = ConnectorHTTP.parseISO8601(remaining.removeValue(forKey: "start"))
            let end = ConnectorHTTP.parseISO8601(remaining.removeValue(forKey: "end"))
            let phrase = remaining.removeValue(forKey: "when")
            if let start {
                // The range already says how long it runs, so the duration isn't a
                // third way of saying the same thing.
                if end != nil { remaining.removeValue(forKey: "duration_minutes") }
                parts.append(when(start: start, end: end, calendar: calendar, now: now))
            } else if let phrase, !phrase.isEmpty {
                // Times not stamped yet (or unparseable) — the user's own words are
                // the honest thing to show, never a guessed date.
                parts.append(phrase)
            }

        case "update_calendar_event", "delete_calendar_event":
            // The title is in the headline; the ids are the router's, not the user's.
            for key in [CalendarTools.eventArgument, CalendarEdit.Key.id, CalendarEdit.Key.calendar] {
                remaining[key] = nil
            }
            let allDay = remaining.removeValue(forKey: CalendarEdit.Key.allDay) != nil
            if let from = ConnectorHTTP.parseISO8601(remaining.removeValue(forKey: CalendarEdit.Key.start)) {
                let fromEnd = ConnectorHTTP.parseISO8601(remaining.removeValue(forKey: CalendarEdit.Key.end))
                var line = allDay
                    ? "\(dayWord(for: from, calendar: calendar, now: now)) all day"
                    : when(start: from, end: fromEnd, calendar: calendar, now: now)
                if let to = ConnectorHTTP.parseISO8601(remaining.removeValue(forKey: "start")) {
                    let toEnd = ConnectorHTTP.parseISO8601(remaining.removeValue(forKey: "end"))
                    line += " \u{2192} " + when(start: to, end: toEnd, calendar: calendar, now: now)
                }
                parts.append(line)
            }
            if let title = remaining.removeValue(forKey: "title"), !title.isEmpty {
                parts.append("Rename to \(quoted(title))")
            }
            if remaining.removeValue(forKey: CalendarEdit.Key.recurring) != nil {
                parts.append("This occurrence only, not the series")
            }

        case "send_message":
            // The channel is the target, so it's in the headline.
            remaining.removeValue(forKey: "channel")
            if let text = remaining.removeValue(forKey: "text"), !text.isEmpty {
                parts.append(quoted(text))
            }

        case "reply_message":
            // The channel is in the headline. The ids say which thread, and "to" names
            // whose message it answers, so the person is on the card too.
            for key in ["channel", "channel_id", "thread_ts"] { remaining.removeValue(forKey: key) }
            if let to = remaining.removeValue(forKey: "to"), !to.isEmpty { parts.append("to \(to)") }
            if let text = remaining.removeValue(forKey: "text"), !text.isEmpty {
                parts.append(quoted(text))
            }

        case "send_mail", "reply_mail":
            // The recipients are the target, and they are here, whole, not in the
            // headline, whose one line cut a long address or list at its tail. The ids
            // place a reply in its thread. The subject and the whole body are what is sent.
            for key in ["thread_id", "in_reply_to", "references"] { remaining.removeValue(forKey: key) }
            if let to = remaining.removeValue(forKey: "to"), !to.isEmpty { parts.append("To: \(to)") }
            if let subject = remaining.removeValue(forKey: "subject"), !subject.isEmpty {
                parts.append("Subject: \(subject)")
            }
            if let body = remaining.removeValue(forKey: "body"), !body.isEmpty {
                parts.append(quoted(body))
            }

        case "open_app":
            remaining.removeValue(forKey: "app")
            parts.append(openAppDetail)

        case "open_file":
            // The file's name is the target, so it is in the headline: the folder is
            // what tells two files of one name apart.
            remaining.removeValue(forKey: "file")
            if let folder = remaining.removeValue(forKey: "folder"), !folder.isEmpty {
                parts.append("In the \(quoted(folder)) folder.")
            }

        case "open_url":
            // Unquoted and whole: the address is the consent.
            if let url = remaining.removeValue(forKey: "url"), !url.isEmpty {
                parts.append(url)
            }

        case "create_note", "create_reminder":
            if let title = remaining.removeValue(forKey: "title"), !title.isEmpty {
                parts.append(quoted(title))
            }
            // The time the app resolved, never the model's phrase.
            if let due = ConnectorHTTP.parseISO8601(remaining["due"]) {
                remaining.removeValue(forKey: "due")
                parts.append(when(start: due, end: nil, calendar: calendar, now: now))
            }
            if let body = remaining.removeValue(forKey: "body"), !body.isEmpty {
                parts.append(quoted(body))
            }

        case DelegateToolCatalog.delegateTask.name:
            // Whole, in the scroll area: the task is what leaves this Mac.
            if let task = remaining.removeValue(forKey: "task"), !task.isEmpty {
                parts.append(quoted(task))
            }

        default:
            break
        }

        parts += remaining
            .sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value)" }

        return parts.isEmpty ? "Approve this action?" : parts.joined(separator: "  ·  ")
    }

    // MARK: - Times

    /// "Today 9:00 – 9:30 AM" / "Tomorrow 3:00 PM" / "Mon 11 Aug 9:00 – 9:30 AM".
    private static func when(start: Date, end: Date?, calendar: Calendar, now: Date) -> String {
        let clock: String
        if let end, end > start, calendar.isDate(end, inSameDayAs: start) {
            clock = intervalFormatter(calendar).string(from: start, to: end)
        } else {
            // An event running past midnight would have the interval formatter
            // re-state both dates, which is longer than the day word it sits after.
            clock = timeFormatter(calendar).string(from: start)
        }
        return "\(dayWord(for: start, calendar: calendar, now: now)) \(clock)"
    }

    private static func dayWord(for date: Date, calendar: Calendar, now: Date) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow) { return "Tomorrow" }
        let formatter = DateFormatter()
        apply(calendar, to: formatter)
        formatter.setLocalizedDateFormatFromTemplate("EEE d MMM")
        return formatter.string(from: date)
    }

    private static func timeFormatter(_ calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        apply(calendar, to: formatter)
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }

    private static func intervalFormatter(_ calendar: Calendar) -> DateIntervalFormatter {
        let formatter = DateIntervalFormatter()
        formatter.calendar = calendar
        formatter.locale = calendar.locale ?? .current
        formatter.timeZone = calendar.timeZone
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }

    private static func apply(_ calendar: Calendar, to formatter: DateFormatter) {
        formatter.calendar = calendar
        formatter.locale = calendar.locale ?? .current
        formatter.timeZone = calendar.timeZone
    }

    private static func quoted(_ text: String) -> String { "\u{201C}\(text)\u{201D}" }
}
