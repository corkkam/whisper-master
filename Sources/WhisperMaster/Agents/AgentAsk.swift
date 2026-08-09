import Foundation

/// Something the agent is waiting on a person for.
///
/// Two shapes arrive down the same `permission` frame and they need different
/// surfaces, so they are different cases rather than one card with a mode flag:
///
/// - **approval** — a tool wants to run. Three fixed, short answers (once / always /
///   no), which fit on one line beside the question.
/// - **choice** — the `AskUserQuestion` tool. The options are *model authored and
///   unbounded*, so they have to stack, and a multi-select needs a confirm step.
///   kunai carries the reply as `Command.answers`: question text → chosen answer,
///   comma-joined for multi-select, merged into the tool's `updatedInput` on allow.
///
/// Both are pure values built from a wire event, so the copy and the option parsing
/// are unit-testable without a socket.
enum AgentAsk: Sendable, Equatable {
    case approval(AgentApproval)
    case choice(AgentChoice)

    var requestID: String {
        switch self {
        case .approval(let a): return a.requestID
        case .choice(let c): return c.requestID
        }
    }

    /// Build from a `permission` frame. Returns nil when the frame carries no
    /// request id, since there would be nothing to answer.
    static func make(from event: KunaiWire.Event, sessionTitle: String) -> AgentAsk? {
        guard let requestID = event.requestID, !requestID.isEmpty else { return nil }
        let input = event.input?.asJSON ?? .null

        if event.toolName == AgentChoice.toolName {
            let questions = AgentChoice.parseQuestions(from: input)
            if !questions.isEmpty {
                return .choice(AgentChoice(requestID: requestID, questions: questions,
                                           context: sessionTitle))
            }
            // A malformed AskUserQuestion still has to be answerable, or the turn
            // hangs behind a card nobody can dismiss. Fall through to an approval.
        }

        return .approval(
            AgentApproval(
                requestID: requestID,
                tool: event.toolName ?? "",
                headline: AgentApproval.headline(tool: event.toolName, input: input,
                                                 permTitle: event.permTitle),
                detail: event.description ?? sessionTitle))
    }
}

// MARK: - Approval

/// A tool call awaiting consent.
struct AgentApproval: Sendable, Equatable {
    var requestID: String
    /// The raw tool name. Never shown: a notch reading `list_calendar_events` is the
    /// same leak the connector approval card's raw arguments were. It is kept for
    /// the accessibility label of **Always**, which has to name what the grant covers.
    var tool: String
    var headline: String
    var detail: String

    /// What the card says, in the user's terms rather than the tool's.
    ///
    /// This *presents* the payload rather than selecting from it: an unrecognised
    /// tool still gets a usable line from `permTitle` or its own name, so a tool
    /// added to Claude Code later degrades to a plainer card instead of an empty one.
    static func headline(tool: String?, input: JSONValue, permTitle: String?) -> String {
        switch tool {
        case "Bash":
            if let command = input.string("command") { return "Run  \(command)" }
        case "Edit", "Write", "NotebookEdit":
            if let path = input.string("file_path") { return "Edit  \(lastTwoComponents(path))" }
        case "Read":
            if let path = input.string("file_path") { return "Read  \(lastTwoComponents(path))" }
        case "WebFetch":
            if let url = input.string("url") { return "Fetch  \(url)" }
        default:
            break
        }
        if let title = permTitle, !title.isEmpty { return title }
        if let tool, !tool.isEmpty { return tool }
        return "Permission needed"
    }

    /// Paths are long and the band is narrow, and the informative end of a path is
    /// the tail. Keeping the parent directory disambiguates the many files that
    /// share a leaf name in a Swift project.
    static func lastTwoComponents(_ path: String) -> String {
        let parts = path.split(separator: "/")
        guard parts.count > 1 else { return String(parts.last ?? "") }
        return parts.suffix(2).joined(separator: "/")
    }
}

// MARK: - Choice

/// The `AskUserQuestion` tool: pick between options the model wrote.
struct AgentChoice: Sendable, Equatable {
    static let toolName = "AskUserQuestion"

    /// How many options fit on the band before the rest are deferred to kunai.
    /// Beyond this the card says how many it is not showing rather than silently
    /// dropping them.
    static let maxVisibleOptions = 4

    struct Question: Sendable, Equatable, Identifiable {
        var id: String { text }
        var text: String
        var header: String?
        var multiSelect: Bool
        var options: [String]

        var visibleOptions: [String] { Array(options.prefix(maxVisibleOptions)) }
        var hiddenOptionCount: Int { max(0, options.count - maxVisibleOptions) }
    }

    var requestID: String
    var questions: [Question]
    /// The session this came from, for the card's second line.
    var context: String

    /// The notch answers one question at a time. Claude almost always asks one, and
    /// a band stacking two sets of options is a window, not a notch.
    var primary: Question? { questions.first }

    /// Whether the card can be shown at all.
    ///
    /// **Options are never truncated.** An option is the text of something a person
    /// is choosing between, so shortening it is the same failure as abbreviating a
    /// consent payload. If even one option is too long to render honestly the whole
    /// card defers to kunai instead.
    func isPresentable(maxOptionLength: Int = 72) -> Bool {
        guard let q = primary, !q.options.isEmpty else { return false }
        return q.visibleOptions.allSatisfy { $0.count <= maxOptionLength }
    }

    /// The reply payload kunai expects: question text → chosen answer, multi-select
    /// comma-joined.
    static func answers(for question: Question, selected: [String]) -> [String: String] {
        [question.text: selected.joined(separator: ",")]
    }

    /// Parse the tool input.
    ///
    /// Two option shapes are accepted because both are in the wild: an array of
    /// objects carrying `label` (what Claude Code sends) and a bare array of
    /// strings. Anything else yields no options, which `isPresentable` then rejects
    /// rather than showing an unanswerable card.
    static func parseQuestions(from input: JSONValue) -> [Question] {
        input.array("questions").compactMap { raw in
            guard let text = raw.string("question") ?? raw.string("header") else { return nil }
            let options: [String] = raw.array("options").compactMap { opt in
                if let label = opt.string("label") { return label }
                return opt.stringValue
            }
            let multi: Bool
            if case .object(let o) = raw, case .bool(let m) = o["multiSelect"] ?? .null {
                multi = m
            } else {
                multi = false
            }
            return Question(text: text, header: raw.string("header"),
                            multiSelect: multi, options: options)
        }
    }
}
