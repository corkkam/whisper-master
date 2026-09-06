import Foundation

/// The one thing that has earned the bezel at this second.
///
/// The notch is a single-occupancy surface, so "show me what is relevant right
/// now" cannot be answered with a list — it needs a *total order*, or the surface
/// flickers between two equally plausible candidates as the clock moves. That
/// order is `NowRelevance.pick`, and this is what it returns.
struct NowItem: Equatable, Identifiable, Sendable {
    /// Which rung of the ladder produced this item. Drives the wording, the
    /// colour, and whether a checkbox or a Join button rides beside it.
    enum Kind: Equatable, Sendable {
        /// A meeting that started and has not ended.
        case meetingNow
        /// A meeting inside `NowRelevance.meetingHorizon`.
        case meetingSoon
        /// A reminder whose time has passed and which is still not ticked.
        case reminderOverdue
        /// A reminder inside `NowRelevance.reminderHorizon`.
        case reminderSoon
        /// The next event today, with nothing more urgent than it.
        case nextEvent
    }

    let id: String
    let kind: Kind
    let title: String
    /// An event's start, or a reminder's due date.
    let at: Date
    /// An event's end. `nil` for a reminder, which is a moment rather than a span.
    let ends: Date?
    /// A conference link found on the event, when there is one. `nil` is the
    /// common case and means the row shows no Join affordance at all — an inert
    /// button that opens nothing is worse than no button.
    let joinURL: URL?
    /// Set for the two reminder rungs, so the row can tick it off in place.
    let reminderID: UUID?

    init(id: String,
         kind: Kind,
         title: String,
         at: Date,
         ends: Date? = nil,
         joinURL: URL? = nil,
         reminderID: UUID? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.at = at
        self.ends = ends
        self.joinURL = joinURL
        self.reminderID = reminderID
    }

    /// Whether this item is one of the user's own things (a reminder they wrote)
    /// rather than something arriving from a calendar. Ember is reserved for the
    /// former per the design system's §1.
    var isOwn: Bool { reminderID != nil }

    /// Whether the item is past its moment and still unanswered.
    var isLate: Bool { kind == .reminderOverdue }
}

// MARK: - The ladder

/// Picks the single ambient item the notch carries, and builds the ordered day
/// the hover panel unrolls into.
///
/// **Pure and clock-injected.** Every horizon here is a product decision that has
/// to be testable at an arbitrary instant, and every surface that reads it renders
/// on a timer — so nothing in this type may reach for `Date()` on its own.
///
/// **Agents are deliberately absent from this ladder.** A blocked or finished
/// coding agent already has its own surfaces (`NotchAgentAskBanner`,
/// `AgentAttention`, the tray submenu), all of which outrank anything ambient.
/// Adding a sixth rung here would mean two independent systems racing to describe
/// the same session.
enum NowRelevance {
    /// How long before a meeting it starts being worth the bezel.
    static let meetingHorizon: TimeInterval = 10 * 60
    /// The same, for a reminder. Longer than a meeting's, because a reminder is
    /// usually a thing to *do* rather than a room to be in.
    static let reminderHorizon: TimeInterval = 15 * 60
    /// How far ahead the quiet "next up" rung looks. Past this the notch is dark:
    /// an ambient surface that is never empty is a dashboard, and the notch is not
    /// one.
    static let lookahead: TimeInterval = 60 * 60

    /// The highest-ranked thing inside its horizon, or `nil` for a dark notch.
    ///
    /// All-day events never produce an item. They have no moment to count down to,
    /// so "Company offsite in 6m" would be a lie about a thing that is true for
    /// sixteen hours; they still appear in `timeline`, where the day has room to
    /// say so.
    static func pick(events: [DayEvent],
                     reminders: [ReminderItem],
                     now: Date) -> NowItem? {
        let timed = events.filter { !$0.isAllDay }
        let live = reminders.filter { !$0.isCompleted && !$0.isDeleted }

        // 1 — a meeting that is happening. The most recently started one wins, so
        // a short stand-up inside a long "focus" block is what gets named.
        if let running = timed
            .filter({ $0.start <= now && $0.end > now })
            .max(by: { $0.start < $1.start }) {
            return item(running, kind: .meetingNow)
        }

        // 2 — a meeting about to start.
        if let soon = timed
            .filter({ $0.start > now && $0.start.timeIntervalSince(now) <= meetingHorizon })
            .min(by: { $0.start < $1.start }) {
            return item(soon, kind: .meetingSoon)
        }

        // 3 — a reminder that is late. Oldest first: the one that has been waiting
        // longest is the one being ignored.
        if let overdue = live
            .filter({ $0.dueDate <= now })
            .min(by: { $0.dueDate < $1.dueDate }) {
            return item(overdue, kind: .reminderOverdue)
        }

        // 4 — a reminder about to come due.
        if let dueSoon = live
            .filter({ $0.dueDate > now && $0.dueDate.timeIntervalSince(now) <= reminderHorizon })
            .min(by: { $0.dueDate < $1.dueDate }) {
            return item(dueSoon, kind: .reminderSoon)
        }

        // 5 — the quiet look-ahead.
        if let next = timed
            .filter({ $0.start > now && $0.start.timeIntervalSince(now) <= lookahead })
            .min(by: { $0.start < $1.start }) {
            return item(next, kind: .nextEvent)
        }

        return nil
    }

    private static func item(_ event: DayEvent, kind: NowItem.Kind) -> NowItem {
        NowItem(
            id: "event:\(event.id)",
            kind: kind,
            title: event.title,
            at: event.start,
            ends: event.end,
            joinURL: event.joinURL)
    }

    private static func item(_ reminder: ReminderItem, kind: NowItem.Kind) -> NowItem {
        NowItem(
            id: "reminder:\(reminder.id.uuidString)",
            kind: kind,
            title: reminder.displayTitle,
            at: reminder.dueDate,
            reminderID: reminder.id)
    }
}

// MARK: - Wording

/// How an item's moment is said on the bezel.
///
/// **Coarse on purpose.** The band's one rule about motion is that nothing pulses,
/// and a countdown redrawing every second is that rule broken by another route —
/// so the smallest unit here is the minute, and a surface reading this only has to
/// repaint when the minute turns.
enum NowPhrase {
    /// "now", "in 6m", "overdue", "in 2h", or a clock time for the quiet rung.
    static func moment(for item: NowItem,
                       now: Date,
                       formatter: DateFormatter = clock) -> String {
        switch item.kind {
        case .meetingNow:
            return "now"
        case .reminderOverdue:
            return "overdue"
        case .meetingSoon, .reminderSoon:
            return "in " + relative(item.at.timeIntervalSince(now))
        case .nextEvent:
            return formatter.string(from: item.at)
        }
    }

    /// A whole-minute distance, rounded **up** so a meeting 30 seconds away reads
    /// "in 1m" rather than "in 0m". Hours past 90 minutes, because "in 118m" is a
    /// number nobody converts.
    static func relative(_ interval: TimeInterval) -> String {
        let minutes = max(1, Int((interval / 60).rounded(.up)))
        guard minutes > 90 else { return "\(minutes)m" }
        let hours = Int((Double(minutes) / 60).rounded())
        return "\(hours)h"
    }

    static let clock: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()
}
