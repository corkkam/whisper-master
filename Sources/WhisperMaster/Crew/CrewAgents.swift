import Foundation
import Observation

/// The Crew agents of the projects on this Mac, as the right-edge rail shows them.
/// It reads `<crewHome>/events.jsonl` and each project's `.crew/crew.json`. It
/// writes one file only: `<crewHome>/STOP`. Held beside `ShedAgents`.
///
/// Dormant until `start()`, so tests and the snapshot renderer start no loop. The
/// 1 s loop only calls `step()`. Tests call `step()` with a test clock. All file
/// reads run in `CrewReader`, off the main actor.
@MainActor
@Observable
final class CrewAgents {

    /// What the rail shows now: the visibility rule already applied.
    private(set) var items: [AgentRailItem] = []
    /// The events file exists.
    private(set) var isAvailable = false
    /// Any agent is not idle or asleep, or was so within the last 60 s.
    private(set) var isActive = false
    /// Any agent is waiting or in error.
    private(set) var needsYou = false
    /// The Crew project with the newest event, where the app starts a task
    /// (`CrewRuns`). A project in a temporary folder is a kit test and is skipped.
    private(set) var project: String?
    /// The `crewFacesAlwaysShow` setting: keep the leads on screen after the active time.
    var showLeadWhenIdle = false {
        didSet { if oldValue != showLeadWhenIdle { publish() } }
    }

    static let activeHold: TimeInterval = 60

    @ObservationIgnored let crewHome: URL
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private var reader: CrewReader
    /// Moves on each stop(), so a read that was in flight is dropped.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var rosters: [String: CrewRoster.Members] = [:]
    @ObservationIgnored private var reducer = CrewReducer()
    @ObservationIgnored private var all: [AgentRailItem] = []
    @ObservationIgnored private var lastActiveAt: Date?
    @ObservationIgnored private var task: Task<Void, Never>?

    /// `CREW_HOME` moves the folder (for tests). Else it is `~/.crew`.
    nonisolated static func defaultHome(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let path = environment["CREW_HOME"], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".crew")
    }

    init(crewHome: URL = CrewAgents.defaultHome(), now: @escaping () -> Date = Date.init) {
        self.crewHome = crewHome
        self.clock = now
        self.reader = CrewReader(crewHome: crewHome)
    }

    private var stopURL: URL { CrewReader.stopURL(crewHome) }

    // MARK: Lifecycle

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.step()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        // A new reader starts its tail at the first-read window again, so a restart
        // rebuilds recent state and does not read the whole backlog.
        generation += 1
        reader = CrewReader(crewHome: crewHome)
        reducer = CrewReducer()
        all = []
        rosters = [:]
        lastActiveAt = nil
        isAvailable = false
        isActive = false
        needsYou = false
        if !items.isEmpty { items = [] }
    }

    /// Writes the global STOP file. Every Crew run and guard reads it. A person
    /// removes it with `crew resume --global`.
    func stopAll() {
        let line = "stopped \(CrewEvent.format(clock())) app\n"
        try? FileManager.default.createDirectory(at: crewHome, withIntermediateDirectories: true)
        try? line.write(to: stopURL, atomically: true, encoding: .utf8)
    }

    // MARK: One pass

    /// Read the new events off the main actor, apply them, move the clock, and
    /// publish what changed.
    func step() async {
        let started = generation
        let pass = await reader.read(projects: Set(reducer.entries.values.map(\.project)))
        guard started == generation else { return }  // stop() came during the read
        let now = clock()
        for event in pass.events { reducer.apply(event) }
        reducer.tick(now: now, globalStop: pass.stopped)
        rosters = pass.rosters
        all = reducer.items { [rosters] in (rosters[$0] ?? .init()).identity(agent: $1) }
        addMissingLeads()

        let busy = all.contains { Self.isBusy($0.state) }
        if busy { lastActiveAt = now }
        let active = busy || (lastActiveAt.map { now.timeIntervalSince($0) < Self.activeHold } ?? false)
        let needs = all.contains { $0.state == .waiting || $0.state == .error }
        if active != isActive { isActive = active }
        if pass.available != isAvailable { isAvailable = pass.available }
        if needs != needsYou { needsYou = needs }
        let newest = reducer.entries.values
            .filter { rosters[$0.project]?.leadID != nil && !Self.isScratch($0.project) }
            .max { $0.lastEventAt < $1.lastEventAt }?.project
        if newest != project { project = newest }
        publish()
    }

    /// shortcut: a path test for the kit's smoke projects; add a project setting if a
    /// real crew ever lives in a temporary folder.
    nonisolated static func isScratch(_ path: String) -> Bool {
        ["/private/var/folders/", "/var/folders/", "/tmp/", "/private/tmp/"].contains { path.hasPrefix($0) }
    }

    /// Spec 12.4: each project with any key shows its lead. A lead with no key of
    /// its own gets an idle item.
    private func addMissingLeads() {
        let projects = Set(reducer.entries.values.map(\.project))
        for project in projects {
            guard let roster = rosters[project], let lead = roster.leadID,
                  let identity = roster.identity(agent: lead) else { continue }
            let id = CrewReducer.key(project: project, agent: lead)
            if !all.contains(where: { $0.id == id }) {
                all.append(AgentRailItem(id: id, identity: identity, state: .idle))
            }
        }
        all.sort { $0.id < $1.id }
    }

    private static func isBusy(_ state: AgentFaceState) -> Bool {
        state != .idle && state != .asleep
    }

    /// The visibility rule: while active, each lead and every busy agent. After
    /// that, nothing, or the leads only when `showLeadWhenIdle` is on.
    private func publish() {
        let visible: [AgentRailItem]
        if isActive {
            visible = all.filter { isLead($0) || Self.isBusy($0.state) }
        } else if showLeadWhenIdle {
            visible = all.filter(isLead)
        } else {
            visible = []
        }
        if visible != items { items = visible }
    }

    private func isLead(_ item: AgentRailItem) -> Bool {
        // The id is project + "/" + agent. An agent id has no "/".
        guard let slash = item.id.lastIndex(of: "/") else { return false }
        return rosters[String(item.id[..<slash])]?
            .isLead(agent: String(item.id[item.id.index(after: slash)...])) ?? false
    }

    // MARK: Snapshots and tests

    func seedForSnapshot(_ items: [AgentRailItem]) {
        self.items = items
        isAvailable = true
        isActive = !items.isEmpty
        needsYou = items.contains { $0.state == .waiting || $0.state == .error }
    }
}

/// The file reads of one `CrewAgents` pass. An actor, so they run off the main
/// actor. It returns values only.
actor CrewReader {
    struct Pass: Sendable {
        var events: [CrewEvent]
        var stopped: Bool
        var available: Bool
        var rosters: [String: CrewRoster.Members]
    }

    nonisolated static func stopURL(_ crewHome: URL) -> URL { crewHome.appendingPathComponent("STOP") }

    private let tail: CrewEventTail
    private let roster = CrewRoster()
    private let stopPath: String

    init(crewHome: URL) {
        tail = CrewEventTail(url: crewHome.appendingPathComponent("events.jsonl"))
        stopPath = Self.stopURL(crewHome).path
    }

    /// `projects` are the projects that already have keys. The projects of new
    /// events are added, so the result covers every key after the events apply.
    func read(projects: Set<String>) -> Pass {
        let events = tail.poll()
        var all = projects
        for event in events { all.insert(event.project) }
        var rosters: [String: CrewRoster.Members] = [:]
        for project in all { rosters[project] = roster.members(project: project) }
        return Pass(
            events: events,
            stopped: FileManager.default.fileExists(atPath: stopPath),
            available: FileManager.default.fileExists(atPath: tail.url.path),
            rosters: rosters)
    }
}
