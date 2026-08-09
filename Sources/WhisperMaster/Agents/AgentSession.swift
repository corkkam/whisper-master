import Foundation

/// One agent session as the notch reads it.
///
/// This is the row in the glance: which codebase, what the agent is doing, and
/// whether it is waiting on a person. Built from `KunaiWire.SessionMeta` plus
/// whatever the live event stream has said since, so a session that is not attached
/// still has an honest row.
struct AgentSession: Sendable, Equatable, Identifiable {
    var id: String
    /// The codebase, derived from `cwd`. This is what the row leads with, because
    /// "which project" is how anyone finds the session they mean.
    var repo: String
    /// kunai's own title for the session, if it has one.
    var title: String
    var state: KunaiWire.SessionState
    var mode: KunaiWire.PermissionMode
    /// What the agent is doing right now, in the user's terms. Nil when idle.
    var activity: String?
    /// When the running turn began, unix ms, or nil when nothing is running.
    var turnStartedAt: Int64?
    /// Set while this session is the one holding a question.
    var isWaiting: Bool { state == .awaitingPermission }

    init(meta: KunaiWire.SessionMeta,
         mode: KunaiWire.PermissionMode = .ask,
         activity: String? = nil) {
        id = meta.id
        repo = AgentSession.repoName(fromPath: meta.cwd)
        title = meta.title
        state = KunaiWire.SessionState(wire: meta.state)
        self.mode = mode
        self.activity = activity
        turnStartedAt = (meta.turnStartedAt ?? 0) > 0 ? meta.turnStartedAt : nil
    }

    init(id: String, repo: String, title: String = "",
         state: KunaiWire.SessionState = .idle,
         mode: KunaiWire.PermissionMode = .ask,
         activity: String? = nil,
         turnStartedAt: Int64? = nil) {
        self.id = id
        self.repo = repo
        self.title = title
        self.state = state
        self.mode = mode
        self.activity = activity
        self.turnStartedAt = turnStartedAt
    }

    /// The last path component of `cwd`, which is the repository directory in every
    /// normal checkout. Falls back to the whole path rather than an empty row.
    static func repoName(fromPath path: String) -> String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard let last = trimmed.split(separator: "/").last, !last.isEmpty else {
            return trimmed.isEmpty ? "session" : trimmed
        }
        return String(last)
    }

    /// The status word at the trailing edge of a glance row.
    ///
    /// A running turn reports **how long** it has been running, because twenty
    /// seconds is a session thinking and twenty minutes is one worth looking at, and
    /// only the elapsed form tells those apart.
    func statusLabel(now: Date) -> String {
        switch state {
        case .awaitingPermission: return "Needs you"
        case .starting: return "Starting"
        case .running:
            guard let started = turnStartedAt else { return "Working" }
            return "Working \(AgentSession.elapsed(sinceMilliseconds: started, now: now))"
        case .idle: return "Idle"
        }
    }

    /// The second line of a glance row: what it is doing, or the session's own title,
    /// or nothing. Never the raw tool name.
    var subtitle: String {
        if let activity, !activity.isEmpty { return activity }
        if !title.isEmpty { return title }
        return state == .idle ? "Waiting for your next prompt" : ""
    }

    /// Compact elapsed time: seconds under a minute, then minutes, then hours. The
    /// band has no room for "1 hour 4 minutes" and nobody reads it there anyway.
    static func elapsed(sinceMilliseconds startedAt: Int64, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince1970 - Double(startedAt) / 1000)
        guard seconds > 0 else { return "0s" }
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h"
    }
}

// MARK: - Ordering

extension [AgentSession] {

    /// The order the glance shows.
    ///
    /// Waiting first, because that is the only row that is *asking* for something;
    /// then running, longest-running first, since a turn that has been going a while
    /// is the one worth a look; then idle. Ties break on repo name so the list does
    /// not shuffle between ticks, which a list that repaints twice a second would
    /// otherwise do.
    func rankedForGlance() -> [AgentSession] {
        sorted { a, b in
            let ra = a.glanceRank, rb = b.glanceRank
            if ra != rb { return ra < rb }
            if a.state == .running, b.state == .running {
                let sa = a.turnStartedAt ?? .max, sb = b.turnStartedAt ?? .max
                if sa != sb { return sa < sb }
            }
            if a.repo != b.repo { return a.repo < b.repo }
            return a.id < b.id
        }
    }
}

extension AgentSession {
    fileprivate var glanceRank: Int {
        switch state {
        case .awaitingPermission: return 0
        case .running, .starting: return 1
        case .idle: return 2
        }
    }
}
