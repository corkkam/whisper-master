import Foundation

/// What the *other* sessions have done since you last looked.
///
/// The notch watches one session at a time — one socket, one transcript, one card.
/// That is right for the surface and wrong for the machine: a second agent can block
/// on a permission it will never be asked about, or finish a turn nobody sees. This
/// is the piece that notices, without a socket per session: kunai's poll already
/// reports every session's state, so the transitions are there to be read.
///
/// **It is deliberately a bad interrupter.** Everything about the policy here exists
/// to keep the band from becoming a notification centre:
///
/// - **The watched session is never announced.** Its ask and its reply already have
///   their own surfaces, and saying it twice is how a surface starts to nag.
/// - **Only transitions.** A session that is *already* waiting when we first see it
///   is not news — otherwise every launch announced every idle session, and every
///   poll re-announced whatever was still blocked.
/// - **Once per event.** The announcement is remembered until the session leaves
///   that state, so a poll that flaps cannot repeat itself.
/// - **The newest event wins.** Two things happening while you were away is still one
///   interruption; the older one is dropped rather than queued, because a queue on
///   this surface is a stack of bands waiting to take the menu bar.
struct AgentAttention: Equatable {

    /// Why a session is asking for you.
    enum Kind: String, Equatable, Sendable {
        /// It stopped and needs a permission answered.
        case needsYou
        /// Its turn ended while you were looking elsewhere.
        case finished
    }

    struct Event: Equatable, Sendable, Identifiable {
        let sessionID: String
        let repo: String
        let kind: Kind
        var id: String { "\(sessionID)-\(kind.rawValue)" }

        /// One line, in the band's voice. Never the tool name, never the raw state.
        var line: String {
            switch kind {
            case .needsYou: return "\(name) needs you"
            case .finished: return "\(name) finished"
            }
        }

        /// What tapping it does, said plainly, because a band that can be tapped has
        /// to say so.
        var hint: String {
            switch kind {
            case .needsYou: return "Tap to answer"
            case .finished: return "Tap to read"
            }
        }

        private var name: String { repo.isEmpty ? "An agent" : repo }
    }

    /// Each session's state as of the previous pass. A session with no entry has
    /// never been seen, which is what makes "already waiting at launch" silent.
    private var seen: [String: KunaiWire.SessionState] = [:]
    /// Events already announced, so a state that persists across polls is not
    /// re-announced. Cleared when the session leaves the state that raised it.
    private var announced: Set<String> = []

    init() {}

    /// Fold in one poll. Returns the event worth interrupting for, if any.
    ///
    /// `watching` is the session the band is already showing — the one with the
    /// socket. It is excluded entirely, including from the state bookkeeping, so
    /// that switching attention to it later cannot fire a stale announcement.
    mutating func update(
        sessions: [AgentSession], watching: String?
    ) -> Event? {
        var newest: Event?
        var live = Set<String>()

        for session in sessions {
            live.insert(session.id)
            let previous = seen[session.id]
            seen[session.id] = session.state

            // The session on screen speaks for itself.
            guard session.id != watching else {
                announced.remove("\(session.id)-\(Kind.needsYou.rawValue)")
                announced.remove("\(session.id)-\(Kind.finished.rawValue)")
                continue
            }
            // Never seen before: record it, say nothing. A session that was already
            // blocked when the app launched is not something that just happened.
            guard let previous else { continue }

            if session.state != .awaitingPermission {
                announced.remove("\(session.id)-\(Kind.needsYou.rawValue)")
            }
            if session.state != .idle {
                announced.remove("\(session.id)-\(Kind.finished.rawValue)")
            }

            let kind: Kind?
            switch (previous, session.state) {
            case (let old, .awaitingPermission) where old != .awaitingPermission:
                kind = .needsYou
            case (.running, .idle):
                kind = .finished
            default:
                kind = nil
            }
            guard let kind else { continue }

            let event = Event(sessionID: session.id, repo: session.repo, kind: kind)
            guard announced.insert(event.id).inserted else { continue }
            // Newest wins: a permission outranks a finish, because one is blocking a
            // machine and the other is only news.
            if kind == .needsYou || newest == nil { newest = event }
        }

        // Forget sessions kunai no longer lists, so ids cannot accumulate forever.
        seen = seen.filter { live.contains($0.key) }
        announced = announced.filter { key in live.contains(where: { key.hasPrefix($0) }) }
        return newest
    }
}
