import Foundation

/// The Desk: one general Claude Code session on this Mac that the assistant hands
/// tasks to (`delegate_task`). It is an ordinary kunai session, told apart from the
/// coding sessions by the title the app gives it at create.
///
/// Pure, so the rules that keep a Desk task out of a coding session are testable with
/// no socket. `AgentSurfaceController.handToDesk` is the only caller that sends.
enum AgentDesk {
    /// The title the app gives the Desk at create. kunai keeps a title for the life of
    /// the session, so it finds the Desk again after a relaunch.
    static let title = "Whisper Master Desk"

    /// The folder the Desk opens in: the Project folder setting, tilde expanded, or nil.
    /// Nil for an empty setting and for the home folder itself: a Desk never falls
    /// back to `~`, which is the guess `AppState.agentDefaultDirectory` refuses too.
    static func folder(_ setting: String?, home: String = NSHomeDirectory()) -> String? {
        let trimmed = (setting ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let tilde = trimmed == "~" || trimmed.hasPrefix("~/")
        let absolute = tilde ? home + trimmed.dropFirst() : trimmed
        // Checked before standardizing, which would resolve a relative path against
        // whatever the app's working directory happens to be.
        guard absolute.hasPrefix("/") else { return nil }
        let expanded = standardized(absolute)
        guard expanded != standardized(home) else { return nil }
        return expanded
    }

    /// Whether a session is a Desk, on this Mac. A session on another machine never is:
    /// the app creates the Desk on this Mac only.
    static func isDesk(_ session: AgentSession, rememberedID: String?) -> Bool {
        guard !session.isRemote else { return false }
        return session.id == rememberedID || session.title == title
    }

    /// The Desk for `folder` among `sessions`, or nil. **Only a Desk**: a coding
    /// session in the same folder, open on the band or the most recent one, is never
    /// returned, so a Desk task cannot reach it.
    static func find(in sessions: [AgentSession], folder: String,
                     rememberedID: String?) -> AgentSession? {
        let desks = sessions.filter {
            isDesk($0, rememberedID: rememberedID) && standardized($0.cwd) == folder
        }
        return desks.first { $0.id == rememberedID } ?? desks.first
    }

    /// The task's destination as the card and the receipt name it.
    static func destination(folder: String) -> String {
        "Claude Code on this Mac, in \(AgentSession.repoName(fromPath: folder))"
    }

    private static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
