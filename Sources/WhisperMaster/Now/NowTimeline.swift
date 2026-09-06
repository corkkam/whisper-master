import Foundation

/// One line of the day, as the hover panel draws it.
///
/// Events and reminders are **interleaved by time** rather than columned by type,
/// which is the whole point of the surface: "what is left today" is one question,
/// and answering it in two lists makes the reader merge them by eye.
struct NowTimelineRow: Identifiable, Equatable, Sendable {
    enum Payload: Equatable, Sendable {
        case event(DayEvent)
        case reminder(ReminderItem)
    }

    let id: String
    let payload: Payload
    /// Sort key. An all-day event has no clock time, so it borrows the start of
    /// the day to sort to the top.
    let at: Date
    /// Whether the moment has gone. Past rows are **dimmed, not hidden** — a day
    /// with its morning deleted reads as an empty day.
    let isPast: Bool

    var title: String {
        switch payload {
        case .event(let event): return event.title
        case .reminder(let reminder): return reminder.displayTitle
        }
    }

    var isAllDay: Bool {
        if case .event(let event) = payload { return event.isAllDay }
        return false
    }

    var reminder: ReminderItem? {
        if case .reminder(let reminder) = payload { return reminder }
        return nil
    }

    var event: DayEvent? {
        if case .event(let event) = payload { return event }
        return nil
    }

    /// The provenance line: which calendar an event came from, or the plain word
    /// for a reminder, so the two kinds are told apart without an icon legend.
    var source: String {
        switch payload {
        case .event(let event): return event.provenance
        case .reminder: return "Reminder"
        }
    }
}

/// Builds the ordered day the quick-actions band unrolls into.
///
/// Pure and clock-injected, like `NowRelevance` and for the same reason.
enum NowTimeline {
    /// Most rows the band will draw. Past this it stops being a glance, and the
    /// surface says how many it left out rather than truncating in silence.
    static let displayLimit = 5

    /// Today, in order: all-day events first, then everything else by time.
    ///
    /// A **completed** reminder is dropped unless it was ticked inside this glance
    /// (the caller passes those through `keeping`), which is what lets the
    /// checkbox tick both ways on a surface with no undo of its own.
    ///
    /// Reminders are narrowed to **today, plus anything overdue and unanswered**.
    /// The store holds every reminder the user has ever set, so passing it straight
    /// through would put next month's dentist appointment in a column headed
    /// "Today"; and an overdue one from last week has to stay, because being late
    /// is the whole reason it is worth the bezel.
    static func rows(events: [DayEvent],
                     reminders: [ReminderItem],
                     now: Date,
                     keeping: Set<UUID> = [],
                     calendar: Calendar = .current) -> [NowTimelineRow] {
        let startOfDay = calendar.startOfDay(for: now)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? now

        let eventRows = events.map { event in
            NowTimelineRow(
                id: "event:\(event.id)",
                payload: .event(event),
                at: event.isAllDay ? startOfDay : event.start,
                // An all-day event is never "past" — it is true for the whole day,
                // so dimming it at one minute past midnight says the wrong thing.
                isPast: event.isAllDay ? false : event.end <= now)
        }

        let reminderRows = reminders
            .filter { !$0.isDeleted }
            .filter { !$0.isCompleted || keeping.contains($0.id) }
            .filter { $0.dueDate < endOfDay }
            .map { reminder in
                NowTimelineRow(
                    id: "reminder:\(reminder.id.uuidString)",
                    payload: .reminder(reminder),
                    at: reminder.dueDate,
                    isPast: reminder.isCompleted)
            }

        return (eventRows + reminderRows).sorted { lhs, rhs in
            // All-day rows lead, whatever their borrowed sort key would say next
            // to an 00:15 event.
            if lhs.isAllDay != rhs.isAllDay { return lhs.isAllDay }
            if lhs.at != rhs.at { return lhs.at < rhs.at }
            return lhs.id < rhs.id
        }
    }

    /// What the band actually draws, and how many it had to leave out.
    ///
    /// **What is ahead of you wins the room.** A day that is mostly behind you
    /// should not spend the whole band on its morning, so the future is taken
    /// first and the *most recent* past fills whatever is left — which means a
    /// finished day still shows its tail rather than going blank.
    ///
    /// The kept rows are re-read out of the original array rather than
    /// concatenated, so an all-day row (which sorts first but is never `isPast`)
    /// stays at the top where it belongs.
    static func window(_ rows: [NowTimelineRow],
                       limit: Int = displayLimit) -> (rows: [NowTimelineRow], hidden: Int) {
        guard rows.count > limit else { return (rows, 0) }
        let ahead = rows.filter { !$0.isPast }.prefix(limit)
        let past = rows.filter(\.isPast).suffix(limit - ahead.count)
        let keep = Set(ahead.map(\.id)).union(past.map(\.id))
        let kept = rows.filter { keep.contains($0.id) }
        return (kept, rows.count - kept.count)
    }
}
