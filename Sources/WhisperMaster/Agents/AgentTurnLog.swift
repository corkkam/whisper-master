import Foundation

/// The readable tail of one session's conversation.
///
/// A pure reducer over `KunaiWire.Event`s, so the whole transcript surface can be
/// tested without a socket. It keeps only the **tail**: the notch answers "what just
/// happened, and does it need me", not "show me everything". kunai itself tail-caps
/// transcript reads for the same reason — those files run to tens of megabytes — and
/// the full history is one tap away in the browser.
///
/// Two wire behaviours shape this:
///
/// - **`delta` then `assistant`.** Text streams as `delta` frames and the finished
///   message arrives as an `assistant` frame carrying full blocks. So deltas
///   accumulate in `streaming` and are *discarded* when the `assistant` frame lands,
///   rather than being committed and then duplicated by it.
/// - **`epoch` changes on respawn.** The replacement process numbers its events from
///   1 again, so a retained sequence would swallow the conversation. `reset()` is
///   what the stream calls when it sees a new epoch.
struct AgentTurnLog: Sendable, Equatable {

    /// One readable line of the conversation.
    enum Entry: Sendable, Equatable, Identifiable {
        case user(id: String, text: String)
        case assistant(id: String, text: String)
        /// A tool call. `detail` is the informative argument (a command, a path) and
        /// `verdict` is what became of it once known.
        case tool(id: String, name: String, detail: String, verdict: String?)

        var id: String {
            switch self {
            case .user(let id, _), .assistant(let id, _), .tool(let id, _, _, _): return id
            }
        }
    }

    /// How many entries the tail keeps. Deep enough for one full exchange — the
    /// prompt, a real turn's worth of tool calls, and the reply — because the
    /// expanded band shows the turn's tool calls and a tail that evicted them
    /// mid-turn would show a turn with its middle missing.
    static let maxEntries = 12

    private(set) var entries: [Entry] = []
    /// Assistant text still streaming in. Rendered under the committed entries and
    /// replaced wholesale by the `assistant` frame that follows.
    private(set) var streaming: String = ""
    /// The highest sequence applied, which is what a reattach resumes from.
    private(set) var highestSeq: UInt64 = 0

    init() {}

    /// Everything worth rendering, streaming text included.
    var renderable: [Entry] {
        guard !streaming.isEmpty else { return entries }
        return entries + [.assistant(id: "streaming", text: streaming)]
    }

    var isEmpty: Bool { entries.isEmpty && streaming.isEmpty }

    /// One tool call of the current turn, as the expanded band lists them.
    struct ToolLine: Sendable, Equatable, Identifiable {
        var id: String
        var name: String
        var detail: String
        var verdict: String?
    }

    /// The tool calls since the last user prompt — the work this turn did, in
    /// order. This is the "what is it doing" the band was rightly said to be
    /// hiding.
    var currentTurnTools: [ToolLine] {
        var lastUser = -1
        for (index, entry) in entries.enumerated() {
            if case .user = entry { lastUser = index }
        }
        return entries.dropFirst(lastUser + 1).compactMap { entry in
            guard case .tool(let id, let name, let detail, let verdict) = entry else {
                return nil
            }
            return ToolLine(id: id, name: name, detail: detail, verdict: verdict)
        }
    }

    /// The newest thing the user said — the question the expanded reply answers.
    /// Shown above the reply, because an answer with no visible question is "old
    /// history, missing".
    var lastUserPrompt: String? {
        for entry in entries.reversed() {
            if case .user(_, let text) = entry { return text }
        }
        return nil
    }

    /// What the agent is doing right now, in the user's terms — the caption the
    /// working row shows beside "Working 17s".
    ///
    /// The newest tool call still awaiting its result wins (that is the thing
    /// actually running); otherwise the newest tool call at all, since "just
    /// finished editing X" beats a bare repo name. Nil until a tool has appeared,
    /// which the caller renders as the repo.
    var currentActivity: String? {
        var newest: (name: String, detail: String)?
        var inFlight: (name: String, detail: String)?
        for entry in entries {
            guard case .tool(_, let name, let detail, let verdict) = entry else { continue }
            newest = (name, detail)
            if verdict == nil { inFlight = (name, detail) }
        }
        guard let pick = inFlight ?? newest else { return nil }
        return Self.presentActivity(name: pick.name, detail: pick.detail)
    }

    /// Turn a tool line into a progressive caption: "Run  swift test" reads as a
    /// request, "Running swift test" reads as what is happening.
    static func presentActivity(name: String, detail: String) -> String {
        let progressive: [(prefix: String, verb: String)] = [
            ("Run  ", "Running "), ("Edit  ", "Editing "),
            ("Read  ", "Reading "), ("Fetch  ", "Fetching "),
        ]
        for rule in progressive where detail.hasPrefix(rule.prefix) {
            return rule.verb + detail.dropFirst(rule.prefix.count)
        }
        if !detail.isEmpty { return detail }
        // No argument to show: the tool's own name, made humane for the two
        // commonest cases, is still better than a bare repo.
        switch name {
        case "Bash": return "Running a command"
        case "Edit", "Write": return "Editing files"
        default: return name
        }
    }

    /// Drop everything. Called when the session's epoch changes, because the new
    /// process's sequence numbering has no relationship to the old one's.
    mutating func reset() {
        entries.removeAll()
        streaming = ""
        highestSeq = 0
    }

    /// Fold one frame in.
    mutating func apply(_ event: KunaiWire.Event) {
        highestSeq = max(highestSeq, event.seq)

        switch event.kind {
        case .user:
            guard let text = event.text?.trimmed, !text.isEmpty else { return }
            streaming = ""
            append(.user(id: "u\(event.seq)", text: text))

        case .delta:
            streaming += event.text ?? ""

        case .assistant:
            // The finished message supersedes whatever streamed.
            streaming = ""
            for (index, block) in (event.blocks ?? []).enumerated() {
                let id = "a\(event.seq)-\(index)"
                switch block.type {
                case "text":
                    guard let text = block.text?.trimmed, !text.isEmpty else { continue }
                    append(.assistant(id: id, text: text))
                case "tool_use":
                    // Most tool calls never raise a permission (reads, auto mode), so
                    // this block is the only chance to say what the call *is*.
                    let detail = AgentApproval.headline(
                        tool: block.name, input: block.input?.asJSON ?? .null,
                        permTitle: nil)
                    append(.tool(id: block.id ?? id, name: block.name ?? "Tool",
                                 detail: detail == (block.name ?? "") ? "" : detail,
                                 verdict: nil))
                default:
                    continue  // thinking blocks stay out of the tail
                }
            }

        case .permission:
            // The ask itself becomes a tool line so the transcript shows what was
            // asked even after the card is answered and gone.
            guard let toolUseID = event.toolUseID ?? event.requestID else { return }
            let detail = AgentApproval.headline(
                tool: event.toolName, input: event.input?.asJSON ?? .null,
                permTitle: event.permTitle)
            upsertTool(id: toolUseID, name: event.toolName ?? "Tool", detail: detail)

        case .permissionResolved:
            guard let toolUseID = event.toolUseID ?? event.requestID else { return }
            setVerdict(id: toolUseID, verdict: event.behavior == "allow" ? "allowed" : "denied")

        case .toolResult:
            guard let toolUseID = event.toolUseID else { return }
            setVerdict(id: toolUseID, verdict: event.isError == true ? "failed" : "done")

        case .error:
            guard let message = event.message?.trimmed, !message.isEmpty else { return }
            append(.assistant(id: "e\(event.seq)", text: message))

        case .thinking:
            // Reasoning is not conversation. It streams as its own frame and the
            // tail is what someone reads to catch up, so showing it would bury the
            // reply under the thinking that produced it.
            return

        case .hello, .mode, .result, .state, .unknown:
            return
        }
    }

    // MARK: Mutation helpers

    private mutating func append(_ entry: Entry) {
        entries.append(entry)
        if entries.count > Self.maxEntries {
            entries.removeFirst(entries.count - Self.maxEntries)
        }
    }

    /// Add a tool line, or fill in the detail of one the `assistant` frame already
    /// announced. The `tool_use` block arrives before the permission ask, so without
    /// this the same call would show twice.
    private mutating func upsertTool(id: String, name: String, detail: String) {
        if let index = entries.firstIndex(where: { $0.id == id }) {
            if case .tool(_, _, _, let verdict) = entries[index] {
                entries[index] = .tool(id: id, name: name, detail: detail, verdict: verdict)
                return
            }
        }
        append(.tool(id: id, name: name, detail: detail, verdict: nil))
    }

    private mutating func setVerdict(id: String, verdict: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }),
              case .tool(_, let name, let detail, _) = entries[index] else { return }
        entries[index] = .tool(id: id, name: name, detail: detail, verdict: verdict)
    }
}

extension String {
    /// Local convenience so the reducer reads cleanly; whitespace-only wire text is
    /// common on partial frames and must not become an empty bubble.
    fileprivate var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
