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

    /// Human verb for a tool name, so the card reads as a sentence rather than an
    /// identifier.
    static func verb(for tool: String) -> String {
        switch tool {
        case "send_message": return "Post to"
        case "create_calendar_event": return "Add an event to"
        case "open_app", "open_url": return "Open"
        case "create_note": return "Save a note on"
        case "create_reminder": return "Set a reminder on"
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

    /// Tools whose payload is text to be saved: a note and a reminder. Their card
    /// shows the whole text in a scroll area (`NotchApprovalBanner`), so nothing the
    /// user approves is cut and no length is refused.
    static func scrollsDetail(tool: String) -> Bool {
        tool == "create_note" || tool == "create_reminder"
    }

    /// Lines a scrolling payload shows before it scrolls. Kept small so the band stays
    /// a band: `NotchApprovalBanner.maxThickness` is charged for this many.
    static let maxVisibleScrollLines = 4

    /// Lines the text takes on the wide card, with each line break kept. An estimate,
    /// rounded against the text; a wrong one makes the area scroll, never cut.
    static func estimatedLines(_ detail: String) -> Int {
        detail.components(separatedBy: .newlines).reduce(0) { total, paragraph in
            total + max(1, (paragraph.count + linkCharactersPerLine - 1) / linkCharactersPerLine)
        }
    }

    /// Lines the payload may take: one, except a link, which wraps onto three rather
    /// than being cut because the end of a link is where a planted address hides, and
    /// a note or a reminder, which shows up to `maxVisibleScrollLines` and scrolls.
    static func detailLines(tool: String, detail: String) -> Int {
        if scrollsDetail(tool: tool) {
            return min(maxVisibleScrollLines, max(1, estimatedLines(detail)))
        }
        guard tool == "open_url" else { return 1 }
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

        case "send_message":
            // The channel is the target, so it's in the headline.
            remaining.removeValue(forKey: "channel")
            if let text = remaining.removeValue(forKey: "text"), !text.isEmpty {
                parts.append(quoted(text))
            }

        case "open_app":
            remaining.removeValue(forKey: "app")
            parts.append(openAppDetail)

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
