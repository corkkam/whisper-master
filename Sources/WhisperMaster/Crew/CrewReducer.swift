import Foundation

/// Turns Crew events into the ten face states. Pure: no AppKit, no timers. The
/// caller feeds events with `apply` and the clock with `tick`. Each agent has one
/// entry, keyed by `project + "/" + agent`.
struct CrewReducer {
    struct Entry: Equatable {
        var project: String
        var agent: String
        var state: AgentFaceState = .idle
        var since: Date
        var lastEventAt: Date
        var detail: String?
        var discussionGroup: String?
        var contextClearedAt: Date?

        var key: String { CrewReducer.key(project: project, agent: agent) }

        /// `since` moves only when the state changes. Only `working` keeps a detail.
        mutating func set(_ new: AgentFaceState, at time: Date) {
            if state != new {
                state = new
                since = time
            }
            if new != .working { detail = nil }
            if new == .idle || new == .asleep { discussionGroup = nil }
        }
    }

    private(set) var entries: [String: Entry] = [:]

    static func key(project: String, agent: String) -> String { project + "/" + agent }

    static func detail(forKind kind: String?) -> String? {
        switch kind {
        case "test": return "tests"
        case "build": return "build"
        case "git": return "git"
        case "search": return "search"
        case "edit": return "editing"
        case "read": return "reading"
        case "web": return "web"
        case "agent": return "delegating"
        default: return nil
        }
    }

    // MARK: Events

    mutating func apply(_ e: CrewEvent) {
        let key = Self.key(project: e.project, agent: e.agent)
        switch e.event {
        case "session.start", "run.start", "agent.start", "prompt":
            update(key, e) { $0.set(.thinking, at: e.ts) }
        case "tool.start":
            update(key, e) {
                $0.set(.working, at: e.ts)
                $0.detail = Self.detail(forKind: e.kind)
            }
        case "tool.end", "tool.fail":
            update(key, e) { $0.set(.thinking, at: e.ts) }
        case "needs.input":
            update(key, e) { $0.set(.waiting, at: e.ts) }
        case "huddle.start", "huddle.round":
            let group = "huddle:" + (e.session ?? e.agent)
            for id in [e.agent] + e.agents {
                update(Self.key(project: e.project, agent: id), e, agent: id) {
                    $0.set(.discussing, at: e.ts)
                    $0.discussionGroup = group
                }
            }
        case "huddle.end":
            update(key, e) { $0.set(.thinking, at: e.ts); $0.discussionGroup = nil }
            for id in e.agents where id != e.agent {
                update(Self.key(project: e.project, agent: id), e, agent: id) {
                    $0.set(.idle, at: e.ts)
                }
            }
        case "agent.stop", "turn.end":
            update(key, e) { $0.set(.done, at: e.ts) }
        case "run.end":
            update(key, e) {
                $0.set(Self.state(forRunEndNote: e.note), at: e.ts)
                $0.contextClearedAt = e.ts
            }
        case "turn.fail":
            update(key, e) { $0.set(.error, at: e.ts) }
        case "budget.over":
            update(key, e) { $0.set(.overBudget, at: e.ts) }
        case "stop.on", "stop.off":
            let state: AgentFaceState = e.event == "stop.on" ? .asleep : .idle
            for k in entries.keys where entries[k]?.project == e.project {
                entries[k]?.set(state, at: e.ts)
                entries[k]?.lastEventAt = e.ts
            }
        case "session.end":
            guard entries[key] != nil else { return }
            update(key, e) {
                switch $0.state {
                case .done, .error, .overBudget: break
                default: $0.set(.idle, at: e.ts)
                }
            }
        case "context.clear":
            guard entries[key] != nil else { return }
            update(key, e) { $0.contextClearedAt = e.ts }
        default:
            // guard.deny, loop.start, loop.end and unknown names: no state change.
            guard entries[key] != nil else { return }
            update(key, e) { _ in }
        }
    }

    /// Notes that the spec does not list end the run quietly as `done`.
    private static func state(forRunEndNote note: String?) -> AgentFaceState {
        switch note {
        case "error", "crash", "blocked": return .error
        case "budget", "window": return .overBudget
        case "stopped": return .asleep
        default: return .done
        }
    }

    /// Creates the entry on first sight, stamps `lastEventAt`, then runs `change`.
    private mutating func update(
        _ key: String, _ e: CrewEvent, agent: String? = nil, _ change: (inout Entry) -> Void
    ) {
        var entry = entries[key]
            ?? Entry(project: e.project, agent: agent ?? e.agent, since: e.ts, lastEventAt: e.ts)
        entry.lastEventAt = e.ts
        change(&entry)
        entries[key] = entry
    }

    // MARK: Time

    static let doneHold: TimeInterval = 10
    static let thinkingTimeout: TimeInterval = 5 * 60
    static let workingTimeout: TimeInterval = 15 * 60
    static let waitingSleep: TimeInterval = 30 * 60
    static let errorSleep: TimeInterval = 60 * 60
    static let quietSleep: TimeInterval = 30 * 60
    static let asleepRemoval: TimeInterval = 6 * 60 * 60

    /// Call about once a second. While `globalStop` is true, every key is asleep.
    mutating func tick(now: Date, globalStop: Bool) {
        for key in Array(entries.keys) {
            guard var e = entries[key] else { continue }
            let quiet = now.timeIntervalSince(e.lastEventAt)
            if globalStop {
                e.set(.asleep, at: now)
            } else {
                switch e.state {
                case .done:
                    if now.timeIntervalSince(e.since) >= Self.doneHold { e.set(.idle, at: now) }
                case .thinking, .discussing:
                    if quiet >= Self.thinkingTimeout { e.set(.idle, at: now) }
                case .working:
                    if quiet >= Self.workingTimeout { e.set(.idle, at: now) }
                case .waiting:
                    if quiet >= Self.waitingSleep { e.set(.asleep, at: now) }
                case .error, .overBudget:
                    if quiet >= Self.errorSleep { e.set(.asleep, at: now) }
                case .idle, .listening, .asleep:
                    break
                }
                switch e.state {
                case .waiting, .error, .overBudget, .asleep: break
                default:
                    if quiet >= Self.quietSleep { e.set(.asleep, at: now) }
                }
            }
            if e.state == .asleep, quiet >= Self.asleepRemoval {
                entries[key] = nil
            } else {
                entries[key] = e
            }
        }
    }

    // MARK: Output

    /// Every key, with no visibility filter, in key order. An agent that the roster
    /// maps to nil (a helper) is dropped.
    func items(roster: (String, String) -> AgentFaceIdentity?) -> [AgentRailItem] {
        entries.values.sorted { $0.key < $1.key }.compactMap { e in
            roster(e.project, e.agent).map {
                AgentRailItem(
                    id: e.key, identity: $0, state: e.state, detail: e.detail,
                    discussionGroup: e.discussionGroup, since: e.since,
                    contextClearedAt: e.contextClearedAt)
            }
        }
    }
}
