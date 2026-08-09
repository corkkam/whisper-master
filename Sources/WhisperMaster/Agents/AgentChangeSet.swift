import Foundation

/// What a turn changed, and what undoing it would cost.
///
/// These are **two different questions** and the design deliberately keeps them
/// apart, because kunai's own revert preview exists for exactly that reason:
///
/// - *What did this turn edit?* comes from the turn's own tool calls. It is short,
///   readable, and the honest answer to "what did it just do".
/// - *What would Undo change?* comes from `GET /api/sessions/{id}/revert`, which
///   asks **git**. A revert is a whole-repository operation: it also discards later
///   turns' edits, anything changed in an editor since, and every untracked file in
///   the repo. Deriving that list from the turn's tool calls would be reassuringly
///   short and wrong.
///
/// So the panel shows the first as "what changed" and only ever quotes the second
/// when offering the undo, with its real blast radius attached.
struct AgentChangeSet: Sendable, Equatable {

    /// Files this turn's own tool calls touched, in the order they were touched.
    var editedPaths: [String] = []

    /// The authoritative preview, once fetched. Nil means "not asked yet", which is
    /// different from "nothing would change" and must not render as a safe-looking
    /// empty list.
    var revert: RevertPreview?

    /// git's answer to what a revert would do.
    struct RevertPreview: Sendable, Equatable, Decodable {
        /// Tracked files that would be restored.
        var changed: [String]
        /// Untracked files that would be **deleted**. Named separately because this
        /// is the destructive half and the one a person cannot get back.
        var removed: [String]

        enum CodingKeys: String, CodingKey { case changed, removed }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            changed = (try? c.decode([String].self, forKey: .changed)) ?? []
            removed = (try? c.decode([String].self, forKey: .removed)) ?? []
        }

        init(changed: [String], removed: [String]) {
            self.changed = changed
            self.removed = removed
        }

        var isEmpty: Bool { changed.isEmpty && removed.isEmpty }

        /// One line stating the blast radius, destructive part first.
        ///
        /// The deletion count leads when there is one: restoring a tracked file is
        /// recoverable and deleting an untracked one is not, so the irreversible
        /// half must not be the clause someone stops reading before.
        var summary: String {
            let changedPart = changed.count == 1
                ? "1 file restored" : "\(changed.count) files restored"
            guard !removed.isEmpty else { return changedPart }
            let removedPart = removed.count == 1
                ? "1 untracked file deleted" : "\(removed.count) untracked files deleted"
            return "\(removedPart), \(changedPart)"
        }
    }

    /// Collect the paths a turn edited from its tool calls.
    ///
    /// Only the tools that actually write are counted. A `Read` is not a change, and
    /// a panel that listed reads as changes would make every turn look destructive.
    static func editedPaths(in log: AgentTurnLog) -> [String] {
        var seen = Set<String>()
        var paths: [String] = []
        for entry in log.entries {
            guard case .tool(_, let name, let detail, _) = entry,
                  Self.writingTools.contains(name) else { continue }
            // `detail` is the presented headline ("Edit  UI/Theme.swift"); the path is
            // its tail. Falling back to the whole detail keeps an unfamiliar shape
            // visible rather than dropping the row.
            let path = detail.split(separator: " ").last.map(String.init) ?? detail
            guard !path.isEmpty, seen.insert(path).inserted else { continue }
            paths.append(path)
        }
        return paths
    }

    /// Tools whose call means a file on disk changed.
    static let writingTools: Set<String> = ["Edit", "Write", "NotebookEdit", "MultiEdit"]

    var isEmpty: Bool { editedPaths.isEmpty && (revert?.isEmpty ?? true) }
}
