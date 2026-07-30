import Foundation

/// One turn of the transcript the loop keeps.
struct AgentTurn: Equatable, Sendable {
    enum Role: String, Sendable { case model, tool, system }
    let role: Role
    let text: String
}

/// What the loop produced.
struct AgentOutcome: Equatable, Sendable {
    let answer: String
    /// Connections that actually served a call, for the notch's provenance line.
    let instanceLabels: [String]
    let turns: [AgentTurn]
    /// True when the loop failed and the caller should fall back to the deterministic
    /// summary. `answer` is empty in that case.
    let exhausted: Bool

    static let failed = AgentOutcome(answer: "", instanceLabels: [], turns: [], exhausted: true)
}

/// The prompt the loop runs under.
enum AgentPrompt {
    /// Terse and rule-shaped on purpose. A 4-bit 3B model follows short imperative
    /// constraints far better than prose, and every extra sentence is a chance for it to
    /// start explaining itself instead of emitting JSON.
    static func system(toolList: String) -> String {
        """
        You answer questions about the user's calendar, tasks and messages by calling tools.

        Tools:
        \(toolList)

        Rules:
        - Reply with ONE JSON object and nothing else. No prose, no markdown fence.
        - To call a tool: {"tool":"<name>","args":{...}}
        - To answer: {"answer":"<one or two short sentences>"}
        - Only use arguments listed for that tool.
        - Omit the connector argument to use every connector.
        - Answer as soon as you have enough. Never call the same tool twice.
        - Never invent events, names or numbers. Only report what a tool returned.
        """
    }
}

/// The local tool-calling loop.
///
/// Runs on the **already-installed** `qwen2.5-3B-Instruct-4bit` — no second model, no
/// cloud call, so a connector answer never leaves the Mac. That model is also the
/// binding constraint on the whole design, and the loop is shaped around it:
///
/// - a small flat tool set (`ToolRegistry` filters to what the user can actually serve)
/// - **hard-fail validation** on every call (`ToolCallParser` rejects, never coerces)
/// - a low iteration cap and a wall-clock budget
/// - a deterministic fallback, so the notch always answers
///
/// The model call is injected (`generate`), which is what makes the entire loop
/// testable — MLX inference cannot run under `swift test` at all, so a real model in
/// this type would mean no tests for any of the control flow.
@MainActor
struct AgentLoop {
    /// `(userText, systemPrompt) -> reply`. Signature matches
    /// `MlxCleanupService.clean(_:systemPrompt:)`, which is the production generator.
    typealias Generate = (String, String) async -> String?

    let tools: [ToolDescriptor]
    let router: ToolRouter
    let generate: Generate
    /// Four is enough for "list, then answer" with two retries for a malformed call.
    /// Higher just gives a struggling 3B more rope.
    var maxIterations: Int = 4
    var budget: TimeInterval = 20
    var now: () -> Date = Date.init

    func run(question: String) async -> AgentOutcome {
        guard !tools.isEmpty else { return .failed }
        let systemPrompt = AgentPrompt.system(toolList: ToolRegistry.promptDescription(for: tools))
        let deadline = now().addingTimeInterval(budget)

        var turns: [AgentTurn] = []
        var labels: [String] = []
        /// Tools already run this session. Re-running one is the classic small-model
        /// loop — it reads its own result, doesn't recognise it as an answer, and calls
        /// again — so a repeat is treated as "you already have this".
        var calledTools = Set<String>()
        var transcript = "Question: \(question)"

        for _ in 0..<maxIterations {
            guard now() < deadline else { break }

            guard let raw = await generate(transcript, systemPrompt) else { break }
            turns.append(AgentTurn(role: .model, text: raw))

            switch ToolCallParser.parse(raw, tools: tools) {
            case .failure(let error):
                turns.append(AgentTurn(role: .system, text: error.modelFeedback))
                transcript += "\n\nThat was invalid: \(error.modelFeedback)\nTry again."

            case .success(.answer(let answer)):
                return AgentOutcome(answer: answer, instanceLabels: labels,
                                    turns: turns, exhausted: false)

            case .success(.call(let call)):
                if calledTools.contains(call.tool) {
                    let note = "You already called \(call.tool). Answer now using what it returned."
                    turns.append(AgentTurn(role: .system, text: note))
                    transcript += "\n\n\(note)"
                    continue
                }
                calledTools.insert(call.tool)
                let result = await router.run(call)
                labels.append(contentsOf: result.instanceLabels)
                turns.append(AgentTurn(role: .tool, text: result.text))
                transcript += "\n\n\(call.tool) returned:\n\(result.text)"
                // Nudge toward finishing: without it a 3B will often keep exploring
                // rather than answer from a result it already has.
                transcript += "\n\nNow reply with {\"answer\":\"...\"}."
            }
        }

        // Out of iterations or time with no answer. A partial tool result is *not*
        // turned into an answer here — summarising it ourselves would be inventing the
        // model's conclusion. The caller falls back to the deterministic path.
        return AgentOutcome(answer: "", instanceLabels: labels, turns: turns, exhausted: true)
    }
}
