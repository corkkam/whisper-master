import Foundation
import Observation

/// Saved automations plus their run history, per account.
///
/// Same persistence shape as `ConnectorInstanceStore` (per-Clerk-user JSON under
/// Application Support, repointed by `AppDelegate`) because an automation is as
/// personal as the connection it reads.
@MainActor
@Observable
final class AutomationStore {
    private(set) var tasks: [ScheduledTask] = []
    /// Newest first, capped — a menu-bar app has no business growing an unbounded log.
    private(set) var runs: [TaskRun] = []

    static let maxRuns = 100

    var persistenceEnabled: Bool = true
    private var userID: String?

    init(load: Bool = true) {
        if load { activate(userID: nil) }
    }

    // MARK: - Account scoping

    func activate(userID: String?) {
        let normalized = userID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = (normalized?.isEmpty ?? true) ? nil : normalized
        if self.userID == resolved, !tasks.isEmpty { return }
        self.userID = resolved
        loadFromDisk()
    }

    func deactivate() {
        userID = nil
        tasks = []
        runs = []
    }

    // MARK: - Tasks

    /// Add a task, computing its first firing. A schedule whose only firing is in the
    /// past lands with `nextRun == nil` and is inert rather than instantly overdue.
    @discardableResult
    func add(_ task: ScheduledTask, now: Date = Date()) -> ScheduledTask {
        var toAdd = task
        toAdd.nextRun = task.schedule.nextFire(after: now)
        tasks.append(toAdd)
        persist()
        return toAdd
    }

    func remove(_ id: UUID) {
        tasks.removeAll { $0.id == id }
        runs.removeAll { $0.taskID == id }
        persist()
    }

    func setEnabled(_ id: UUID, _ on: Bool, now: Date = Date()) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].isEnabled = on
        // Re-arm from *now* on re-enable, so a task disabled for a week doesn't fire
        // immediately for every firing it missed while off.
        if on { tasks[index].nextRun = tasks[index].schedule.nextFire(after: now) }
        persist()
    }

    /// Every task due at `now`, in a stable order.
    func due(at now: Date) -> [ScheduledTask] {
        tasks.filter { $0.isDue(at: now) }.sorted { $0.createdAt < $1.createdAt }
    }

    /// Record a completed firing and re-arm the task.
    func complete(_ run: TaskRun, now: Date = Date()) {
        addRun(run)
        guard let index = tasks.firstIndex(where: { $0.id == run.taskID }) else { return }
        // A skipped run is not a firing: it must not advance the count or move the
        // schedule, or an overlapping long run would silently eat the next slot.
        if run.status != .skipped {
            tasks[index].runCount += 1
            tasks[index].lastRun = run.startedAt
            tasks[index].lastStatus = run.status
        }
        tasks[index].nextRun = tasks[index].schedule.nextFire(after: now)
        persist()
    }

    // MARK: - Runs

    func runs(for taskID: UUID) -> [TaskRun] {
        runs.filter { $0.taskID == taskID }
    }

    private func addRun(_ run: TaskRun) {
        runs.insert(run, at: 0)
        if runs.count > Self.maxRuns { runs = Array(runs.prefix(Self.maxRuns)) }
    }

    // MARK: - Persistence

    private struct Payload: Codable {
        var tasks: [ScheduledTask]
        var runs: [TaskRun]
    }

    nonisolated static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("WhisperMaster/Automations", isDirectory: true)
    }

    /// Sanitized per-account path, same rule as the other per-user stores — never trust
    /// an id straight into a path.
    nonisolated static func fileURL(forUserID userID: String?) -> URL {
        guard let userID, !userID.isEmpty else {
            return directory.appendingPathComponent("device.json", isDirectory: false)
        }
        let safe = String(userID.map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" ? $0 : "_" })
        return directory.appendingPathComponent("\(safe).json", isDirectory: false)
    }

    private func loadFromDisk() {
        tasks = []
        runs = []
        guard persistenceEnabled,
              let data = try? Data(contentsOf: Self.fileURL(forUserID: userID)),
              let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else { return }
        tasks = payload.tasks
        runs = payload.runs
    }

    private func persist() {
        guard persistenceEnabled else { return }
        guard let data = try? JSONEncoder().encode(Payload(tasks: tasks, runs: runs)) else { return }
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        try? data.write(to: Self.fileURL(forUserID: userID), options: .atomic)
    }
}
