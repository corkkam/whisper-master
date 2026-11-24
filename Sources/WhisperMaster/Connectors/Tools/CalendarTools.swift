import Foundation

/// `find_free_slots`, `update_calendar_event` and `delete_calendar_event`: the
/// calendar tools past list and create.
///
/// The model names an event by its title and its day, never by a provider id. The
/// router reads that day and resolves the title to exactly one event before the
/// approval card (`ToolRouter.editEvent`); none or several fail closed and list the
/// day's events, so the model can ask or call again.
enum CalendarTools {
    static let findFreeSlots = ToolDescriptor(
        name: "find_free_slots",
        summary: "Find free time on a day. Omit connector to check every calendar.",
        access: .read,
        capability: .events,
        targetArg: nil,
        parameters: [
            ToolParameter("day",
                          description: "Which day, in the user's own words (\"tomorrow\", \"friday\"). Omit for today."),
            ToolParameter("duration_minutes", type: .integer,
                          description: "How long the free time must be, in minutes. Defaults to 30."),
            ToolParameter("between",
                          description: "Hours to search, like \"9am to 6pm\". Defaults to 9am to 6pm."),
        ])

    static let updateEvent = ToolDescriptor(
        name: "update_calendar_event",
        summary: "Move, reschedule or rename one calendar event. Give when, title or both.",
        access: .write,
        capability: .events,
        targetArg: eventArgument,
        parameters: [
            eventParameter,
            dayParameter,
            ToolParameter("when",
                          description: "The new start time in the user's own words (\"tomorrow at 3\")."),
            ToolParameter("title", description: "The new title."),
        ])

    static let deleteEvent = ToolDescriptor(
        name: "delete_calendar_event",
        summary: "Delete or cancel one calendar event.",
        access: .write,
        capability: .events,
        targetArg: eventArgument,
        parameters: [eventParameter, dayParameter])

    static let all = [findFreeSlots, updateEvent, deleteEvent]
    static let editNames: Set<String> = [updateEvent.name, deleteEvent.name]

    static let eventArgument = "event"
    private static let eventParameter = ToolParameter(
        eventArgument, isRequired: true, description: "The event's title, as the user said it.")
    private static let dayParameter = ToolParameter(
        "day", description: "The day the event is on, in the user's own words. Omit for today.")

    /// Whether a standing grant may cover the tool. Not an edit: "always let it move
    /// or delete Standup" would bind to a title anybody's invitation can carry.
    static func grantable(_ tool: String) -> Bool {
        !editNames.contains(tool)
    }

    /// Whether `instance` is offered for `tool`. An edit needs a provider that can
    /// change an event; every other tool keeps the registry's own rule.
    @MainActor
    static func canServe(_ tool: String, _ instance: ConnectorInstance) -> Bool {
        !editNames.contains(tool) || ProviderRegistry.provider(for: instance) is any CalendarEditingProvider
    }
}

/// The titles a spoken name matches. Pure, so the resolution rules are pinned.
enum CalendarEventMatcher {
    /// Words a person adds around a title ("the standup meeting").
    private static let filler: Set<String> = ["the", "my", "a", "an", "event", "meeting"]

    /// Indexes into `titles` that `spoken` names. An exact title wins over a partial
    /// one, so "Standup" picks "Standup" and not also "Standup prep". A partial match
    /// needs every word the user said (less filler) in the title.
    static func matches(_ spoken: String, titles: [String]) -> [Int] {
        let said = ConnectorLabelMatcher.tokens(spoken)
        guard !said.isEmpty else { return [] }
        let exact = titles.indices.filter { ConnectorLabelMatcher.tokens(titles[$0]) == said }
        if !exact.isEmpty { return exact }
        let words = Set(said).subtracting(filler)
        guard !words.isEmpty else { return [] }
        return titles.indices.filter { words.isSubset(of: ConnectorLabelMatcher.tokens(titles[$0])) }
    }
}

/// One change to one resolved event, carried from the router to the provider in the
/// write's arguments. The model cannot set these keys: the parser refuses any
/// argument a descriptor does not declare.
struct CalendarEdit: Equatable, Sendable {
    enum Change: Equatable, Sendable {
        case update(title: String?, start: Date?, end: Date?)
        case delete
    }

    let eventID: String
    let calendarID: String?
    /// The event's title before the change, for the receipt.
    let title: String
    /// The occurrence's start before the change. EventKit finds the occurrence by it.
    let start: Date
    let isRecurring: Bool
    let change: Change

    /// The keys the router stamps. `ApprovalCopy` reads them for the card.
    enum Key {
        static let id = "event_id"
        static let calendar = "event_calendar"
        static let start = "event_start"
        static let end = "event_end"
        static let allDay = "event_all_day"
        static let recurring = "event_recurring"
    }

    /// The write's arguments: the event as the card shows it, plus the new title and
    /// times (`title`, `start`, `end`) for an update.
    static func arguments(for event: DayEvent, title: String?, start: Date?, end: Date?) -> [String: String] {
        var arguments = [
            CalendarTools.eventArgument: event.title,
            Key.id: event.id,
            Key.start: ConnectorHTTP.iso8601(from: event.start),
            Key.end: ConnectorHTTP.iso8601(from: event.end),
        ]
        arguments[Key.calendar] = event.calendarID
        if event.isAllDay { arguments[Key.allDay] = "true" }
        if event.isRecurring { arguments[Key.recurring] = "true" }
        arguments["title"] = title
        if let start, let end {
            arguments["start"] = ConnectorHTTP.iso8601(from: start)
            arguments["end"] = ConnectorHTTP.iso8601(from: end)
        }
        return arguments
    }

    init?(tool: String, arguments: [String: String]) {
        guard CalendarTools.editNames.contains(tool),
              let eventID = arguments[Key.id],
              let start = ConnectorHTTP.parseISO8601(arguments[Key.start])
        else { return nil }
        self.eventID = eventID
        self.calendarID = arguments[Key.calendar]
        self.title = arguments[CalendarTools.eventArgument] ?? ""
        self.start = start
        self.isRecurring = arguments[Key.recurring] != nil
        self.change = tool == CalendarTools.deleteEvent.name
            ? .delete
            : .update(title: arguments["title"],
                      start: ConnectorHTTP.parseISO8601(arguments["start"]),
                      end: ConnectorHTTP.parseISO8601(arguments["end"]))
    }

    /// What the band says after the provider took the change.
    func receipt(on label: String) -> String {
        let only = isRecurring ? " This occurrence only." : ""
        switch change {
        case .delete:
            return "Deleted \(Self.quoted(title)) at \(Self.time.string(from: start)) from \(label).\(only)"
        case .update(let newTitle, let newStart, _):
            var parts: [String] = []
            if let newTitle { parts.append("renamed it \(Self.quoted(newTitle))") }
            if let newStart { parts.append("moved it to \(Self.time.string(from: newStart))") }
            return "Changed \(Self.quoted(title)) on \(label): \(parts.joined(separator: " and ")).\(only)"
        }
    }

    private static func quoted(_ text: String) -> String { "\u{201C}\(text)\u{201D}" }

    private static var time: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a 'on' EEEE d MMMM"
        return formatter
    }
}

// MARK: - The router's branches

extension ToolRouter {
    /// `find_free_slots`: the events of the day, read like `list_calendar_events`,
    /// merged over every calendar unless one is named, because a free slot must be
    /// free on all of them.
    func freeSlots(_ call: ToolCall,
                   from instances: [ConnectorInstance],
                   scopedTo: String?) async -> ToolResult {
        let day = resolveDay(call.arguments["day"])
        let minutes = max(call.arguments["duration_minutes"].flatMap(Int.init) ?? 30, 1)
        guard let window = FreeSlotFinder.window(on: day.date, between: call.arguments["between"]) else {
            return .failure("Couldn't read \u{201C}\(call.arguments["between"] ?? "")\u{201D} as hours. "
                + "Say it like \u{201C}9am to 6pm\u{201D}.")
        }
        let summary = await DaySummaryService.buildAsync(
            store: store, instances: instances, scopedTo: scopedTo, now: day.date)
        let slots = FreeSlotFinder.slots(in: window, events: summary.events, minutes: minutes,
                                         notBefore: now())
        let hours = "between \(Self.time.string(from: window.start)) and \(Self.time.string(from: window.end))"
        var lines = slots.isEmpty
            ? ["No free time of \(minutes) minutes \(day.label) \(hours)."]
            : ["Free for \(minutes) minutes or more \(day.label), \(hours):"]
                + slots.map { "\(Self.time.string(from: $0.start)) \u{2013} \(Self.time.string(from: $0.end))" }
        if summary.events.contains(where: \.isAllDay) {
            lines.append("All-day events are not counted as busy.")
        }
        // A calendar that couldn't be read may be busy in these slots.
        lines += summary.gaps.map {
            "[\($0.instanceLabel)] couldn't be read: \($0.reason.message). Its events are not counted."
        }
        let served = instances
            .filter { instance in !summary.gaps.contains { $0.instanceLabel == instance.displayLabel } }
            .map(\.displayLabel)
        return ToolResult(ok: true, text: lines.joined(separator: "\n"), instanceLabels: served,
                          unreadable: summary.gaps.map(\.instanceLabel))
    }

    /// `update_calendar_event` and `delete_calendar_event`: resolve the spoken title
    /// against that day's events, then the ordinary write path (`WriteAuthorizer`,
    /// the card, the provider). The card always shows: these tools offer no Always.
    func editEvent(_ call: ToolCall,
                   descriptor: ToolDescriptor,
                   named: String?,
                   candidates: [ConnectorInstance]) async -> ToolResult {
        let newTitle = Self.nonEmpty(call.arguments["title"])
        let phrase = Self.nonEmpty(call.arguments["when"])
        if call.tool == CalendarTools.updateEvent.name, newTitle == nil, phrase == nil {
            return .failure("\(call.tool) needs \"when\", \"title\" or both.")
        }
        guard let spoken = Self.nonEmpty(call.arguments[CalendarTools.eventArgument]) else {
            return .failure("\(call.tool) needs \"event\".")
        }
        let editors = candidates
            .filter { named == nil || $0.displayLabel == named }
            .compactMap { instance in (writeProvider(instance) as? any CalendarEditingProvider).map { (instance, $0) } }
        guard !editors.isEmpty else { return .failure("No calendar here can change events.") }

        let day = resolveDay(call.arguments["day"])
        var found: [(instance: ConnectorInstance, event: DayEvent)] = []
        var gaps: [String] = []
        for (instance, provider) in editors {
            let outcome = await provider.eventsToEdit(on: day.date, instance: instance)
            if let error = outcome.error {
                gaps.append("[\(instance.displayLabel)] couldn't be read: \(error.message)")
                continue
            }
            // Two connections can share a calendar; an occurrence is its id and start.
            for event in outcome.value
            where !found.contains(where: { $0.event.id == event.id && $0.event.start == event.start }) {
                found.append((instance, event))
            }
        }
        // Event titles are other people's text (an invitation), and every result
        // from here on can name one. Set after the card, so this call's own card
        // does not warn about a read the model had not seen.
        defer {
            if !found.isEmpty {
                taint.isSet = true
                taint.outsideSelection = true
            }
        }

        let hits = CalendarEventMatcher.matches(spoken, titles: found.map(\.event.title))
        guard hits.count == 1 else {
            let listed = (hits.isEmpty ? found : hits.map { found[$0] }).map { Self.eventLine($0.event) }
            let lead = hits.isEmpty
                ? "No event matches \u{201C}\(spoken)\u{201D} \(day.label)."
                : "More than one event matches \u{201C}\(spoken)\u{201D} \(day.label). Nothing was changed. Ask the user which one."
            let events = listed.isEmpty ? ["There are no events \(day.label)."] : ["Events:"] + listed
            return .failure(([lead] + events + gaps).joined(separator: "\n"))
        }
        let (instance, event) = found[hits[0]]

        var start: Date?
        var end: Date?
        if let phrase {
            guard !event.isAllDay else {
                return .failure("\u{201C}\(event.title)\u{201D} is an all-day event, so it can't be moved to a time.")
            }
            guard let parsed = RelativeTimeParser.parse(phrase, now: now()) else {
                return .failure("Couldn't work out a time from \u{201C}\(phrase)\u{201D}. "
                    + "Say it as a clear time, like \u{201C}tomorrow at 3pm\u{201D}.")
            }
            // A move keeps the event's own length.
            start = parsed
            end = parsed.addingTimeInterval(event.end.timeIntervalSince(event.start))
        }
        let arguments = CalendarEdit.arguments(for: event, title: newTitle, start: start, end: end)
        return await write(ToolCall(tool: call.tool, arguments: arguments),
                           descriptor: descriptor, instance: instance)
    }

    /// One row of the candidates, in `list_calendar_events`' format.
    private static func eventLine(_ event: DayEvent) -> String {
        let when = event.isAllDay ? "all day" : time.string(from: event.start)
        let whose = event.instanceLabel.isEmpty ? "" : " [\(event.instanceLabel)]"
        return "\(when) \u{2014} \(oneLine(event.title))\(whose)"
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
