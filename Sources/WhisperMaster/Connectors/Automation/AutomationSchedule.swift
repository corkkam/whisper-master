import Foundation

/// When an automation fires.
///
/// Three concrete cases rather than a cron string. openworker uses 5-field cron because
/// it's a server-side tool whose users write cron; this is a menu-bar app whose
/// automations UI offers "every day at 8am". A half-correct cron parser (ranges, steps,
/// day-of-week vs day-of-month precedence) would be a subtle-bug factory for capability
/// nothing in the UI exposes. If cron is ever needed, it becomes a fourth case.
///
/// Pure and `Calendar`-based, so DST and month lengths are handled by the system rather
/// than by arithmetic on seconds.
enum AutomationSchedule: Codable, Equatable, Sendable {
    /// Every day at a wall-clock time.
    case daily(hour: Int, minute: Int)
    /// Weekly, `weekday` being `Calendar`'s 1 = Sunday … 7 = Saturday.
    case weekly(weekday: Int, hour: Int, minute: Int)
    /// A single firing.
    case once(at: Date)

    /// The next firing strictly after `date`, or nil for a spent one-shot.
    ///
    /// "Strictly after" is load-bearing: `>=` would let a task that just ran at exactly
    /// its scheduled second immediately qualify again and spin.
    func nextFire(after date: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .once(let at):
            return at > date ? at : nil

        case .daily(let hour, let minute):
            var components = DateComponents()
            components.hour = hour
            components.minute = minute
            // `nextDate` walks forward over DST gaps rather than producing a time that
            // doesn't exist on the day the clocks change.
            return calendar.nextDate(after: date, matching: components,
                                     matchingPolicy: .nextTime, direction: .forward)

        case .weekly(let weekday, let hour, let minute):
            var components = DateComponents()
            components.weekday = weekday
            components.hour = hour
            components.minute = minute
            return calendar.nextDate(after: date, matching: components,
                                     matchingPolicy: .nextTime, direction: .forward)
        }
    }

    /// A human label for the automations list.
    var human: String {
        switch self {
        case .daily(let hour, let minute):
            return "Every day at \(Self.clock(hour, minute))"
        case .weekly(let weekday, let hour, let minute):
            return "Every \(Self.weekdayName(weekday)) at \(Self.clock(hour, minute))"
        case .once(let at):
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return "Once, \(formatter.string(from: at))"
        }
    }

    private static func clock(_ hour: Int, _ minute: Int) -> String {
        let suffix = hour < 12 ? "AM" : "PM"
        let twelve = hour % 12 == 0 ? 12 : hour % 12
        return String(format: "%d:%02d %@", twelve, minute, suffix)
    }

    private static func weekdayName(_ weekday: Int) -> String {
        let names = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        let index = (weekday - 1) % 7
        return names[index < 0 ? 0 : index]
    }
}

/// A saved automation: a question, asked on a schedule.
///
/// The instruction is natural language and runs through the same `AgentLoop` a spoken
/// query does — an automation is a *scheduled question*, not a second execution path
/// that could drift from the interactive one.
struct ScheduledTask: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    var title: String
    /// What to ask, e.g. "what's on my work calendar today".
    var instructions: String
    var schedule: AutomationSchedule
    var isEnabled: Bool
    let createdAt: Date
    /// Computed by the store; nil once a one-shot is spent.
    var nextRun: Date?
    var lastRun: Date?
    var lastStatus: RunStatus?
    var runCount: Int

    init(id: UUID = UUID(),
         title: String,
         instructions: String,
         schedule: AutomationSchedule,
         isEnabled: Bool = true,
         createdAt: Date = Date(),
         nextRun: Date? = nil,
         lastRun: Date? = nil,
         lastStatus: RunStatus? = nil,
         runCount: Int = 0) {
        self.id = id
        self.title = title
        self.instructions = instructions
        self.schedule = schedule
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.nextRun = nextRun
        self.lastRun = lastRun
        self.lastStatus = lastStatus
        self.runCount = runCount
    }

    /// Whether this is due at `now`. Disabled tasks are never due, and a nil `nextRun`
    /// means a spent one-shot.
    func isDue(at now: Date) -> Bool {
        guard isEnabled, let nextRun else { return false }
        return nextRun <= now
    }
}

enum RunStatus: String, Codable, Equatable, Sendable {
    case ok
    case failed
    /// Skipped because the previous run of this task was still going.
    case skipped
}

/// One firing, kept so the user can see what an automation actually said.
struct TaskRun: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let taskID: UUID
    let startedAt: Date
    var finishedAt: Date?
    var status: RunStatus
    var answer: String
    /// `schedule` | `manual` | `catchup` — a catch-up run is worth distinguishing,
    /// since its answer may describe a moment that has passed.
    var trigger: String

    init(id: UUID = UUID(),
         taskID: UUID,
         startedAt: Date = Date(),
         finishedAt: Date? = nil,
         status: RunStatus = .ok,
         answer: String = "",
         trigger: String = "schedule") {
        self.id = id
        self.taskID = taskID
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.status = status
        self.answer = answer
        self.trigger = trigger
    }
}
