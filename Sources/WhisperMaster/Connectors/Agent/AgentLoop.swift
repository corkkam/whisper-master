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
        - You may call several tools, one per reply, before answering.
        - Never repeat a call with the same arguments — you already have that result.
        - Answer as soon as you have enough.
        - Never invent events, names or numbers. Only report what a tool returned.
        """
    }

    /// The prompt for a **spoken command** — the fn + control chord.
    ///
    /// Different from `system` in one load-bearing way: the user held a key that
    /// means "act on this", so answering without calling anything is a failure, not a
    /// shortcut. The last rule is what turns an unclassifiable mumble into a saved
    /// note instead of a lost one, and it's backed up in code — a run that called no
    /// tool is treated as exhausted and falls back to filing the words verbatim.
    static func command(toolList: String) -> String {
        """
        The user spoke a command. Carry it out by calling one tool, then report what you did.

        Tools:
        \(toolList)

        Rules:
        - Reply with ONE JSON object and nothing else. No prose, no markdown fence.
        - To call a tool: {"tool":"<name>","args":{...}}
        - To report the result: {"answer":"<one short sentence>"}
        - Call a tool first. Never answer before calling one.
        - Only use arguments listed for that tool.
        - Never repeat a call with the same arguments — you already have that result.
        - For times, pass the user's own words ("tomorrow at 9"), never a date you worked out.
        - Never invent events, names or numbers. Only report what a tool returned.
        - If nothing else fits, call create_note with what the user said.
        """
    }

    /// The **native** counterpart to `system`, for the model's own tool-calling path.
    ///
    /// The tool list and the call format are injected by the chat template (the
    /// `<tools>` block and the `<tool_call>` convention), so this carries only the
    /// behavioural rules — listing the tools or the JSON shape here would fight the
    /// template rather than reinforce it.
    static func systemNative() -> String {
        """
        You answer questions about the user's calendar, tasks and messages by calling the provided functions.

        Rules:
        - Call a function when one can answer the question.
        - Omit the connector argument to use every connector.
        - Never repeat a call with the same arguments — you already have that result.
        - Answer as soon as you have enough.
        - Never invent events, names or numbers. Only report what a function returned.
        """
    }

    /// The **native** counterpart to `command`. Same load-bearing difference: the user
    /// held a key that means "act on this", so a function call comes first.
    static func commandNative() -> String {
        """
        The user spoke a command. Carry it out by calling one of the provided functions, then report what you did.

        Rules:
        - Call a function first. Never answer before calling one.
        - For times, pass the user's own words ("tomorrow at 9"), never a date you worked out.
        - Never repeat a call with the same arguments — you already have that result.
        - Never invent events, names or numbers. Only report what a function returned.
        - If nothing else fits, call create_note with what the user said.
        """
    }
}

/// One-shot winner flag for the generation race in `AgentLoop`.
///
/// Locked rather than actor-isolated so whichever racer finishes first can settle it
/// wherever it happens to be running: a hop would leave a window in which both of them
/// resume the same continuation, which traps.
private final class FirstPastThePost: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    /// True for the first caller and nobody else.
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

/// The local tool-calling loop.
///
/// Runs on the **already-installed** `Qwen3-4B-Instruct-2507-4bit` — no second model, no
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
    ///
    /// `@Sendable` because the loop runs it in a task it can walk away from when the
    /// budget runs out (see `generateWithinBudget`), so it can't be a closure that
    /// only works on one thread.
    typealias Generate = @Sendable (String, String) async -> String?

    /// `(messages, toolSchemasJSON) -> reply`. Signature matches
    /// `MlxCleanupService.generateWithTools`. Messages are `[role, content]` pairs;
    /// tool schemas are JSON function definitions. When this is set, the loop renders
    /// through the model's **native** chat template + tools and parses the reply with
    /// `NativeToolCallParser`, instead of the hand-rolled prompt + `ToolCallParser`.
    ///
    /// `@Sendable` for the same reason as `Generate`: the loop runs it in a task it
    /// can walk away from when the budget runs out.
    typealias GenerateNative = @Sendable ([[String: String]], [String]) async -> String?

    /// The production generator: the already-loaded qwen.
    ///
    /// **Note the cost.** `MlxCleanupService` keeps a persistent KV cache primed on
    /// the *cleanup* system prompt; passing a different system prompt re-prefills it.
    /// So an agent call re-primes, and the next dictation cleanup re-primes back.
    /// That's acceptable — neither is in the sub-second dictation hot path — but it's
    /// the reason the loop isn't run speculatively or on every transcript.
    ///
    /// It lived on `ConnectorAgentService`, which existed to assemble the agent for a
    /// scheduled automation and for the retired day-query key. With automations gone
    /// the chord (`CommandAgentService`) is the only caller left, so the wrapper went
    /// with them and the one piece worth keeping moved here.
    static func liveGenerator() -> Generate {
        { text, systemPrompt in
            await MlxCleanupService.shared.clean(text, systemPrompt: systemPrompt)
        }
    }

    /// The production **native** generator: the same loaded qwen, driven through its
    /// chat template's tools mechanism. Wired onto `generateNative` by a caller that
    /// wants the native tool-calling path; unset keeps the hand-rolled path.
    static func liveNativeGenerator() -> GenerateNative {
        { messages, toolSchemas in
            await MlxCleanupService.shared.generateWithTools(
                messages: messages, toolSchemasJSON: toolSchemas)
        }
    }

    let tools: [ToolDescriptor]
    let router: any AgentToolRunning
    let generate: Generate
    /// When set, the loop uses the model's native tool-calling instead of the
    /// hand-rolled JSON prompt (see `GenerateNative`). Nil (the default) keeps the
    /// hand-rolled path, so nothing changes for a caller that doesn't opt in.
    var generateNative: GenerateNative? = nil
    /// Enough for a real chain — read, read again with different arguments, act,
    /// report — plus a retry or two for a malformed call.
    ///
    /// It was four, which is "list, then answer" and nothing else: any question that
    /// genuinely needed two lookups (both calendars, today *and* tomorrow) or a
    /// read before a write spent its whole budget getting to the second call and
    /// then reported exhausted. The wall-clock budget, not this number, is what
    /// actually protects the notch from a struggling model — which is why the cap
    /// can double while the budget only goes to 30s: the chord suppresses the paste
    /// and the band says "Working on it" the whole time, so a long failure reads as a
    /// hang. Thirty seconds covers a three-or-four step chain on a 3B and still gives
    /// up before the user does.
    var maxIterations: Int = 8
    var budget: TimeInterval = 30
    var now: () -> Date = Date.init
    /// The prompt the loop runs under. A question and a spoken command want different
    /// instructions (see `AgentPrompt.command`), and the difference is the caller's to
    /// make — everything below is the same machine either way.
    var prompt: (String) -> String = AgentPrompt.system(toolList:)
    /// The system prompt for the native path (used only when `generateNative` is set).
    /// It takes no tool list — the chat template injects the tools — so it is a plain
    /// `() -> String`, unlike `prompt`.
    var nativePrompt: () -> String = AgentPrompt.systemNative
    /// Reports what the loop is about to do, so the notch can name the connector it's
    /// waiting on instead of saying "Working on it" for thirty seconds. No-op by
    /// default, so a caller with nothing to caption (a test) can ignore it.
    var onStep: (AgentActivity) -> Void = { _ in }

    func run(question: String) async -> AgentOutcome {
        guard !tools.isEmpty else { return .failed }
        // The native path renders tools through the chat template, so its system
        // prompt carries no tool list; the hand-rolled path lists them inline.
        let useNative = generateNative != nil
        let systemPrompt = useNative
            ? nativePrompt()
            : prompt(ToolRegistry.promptDescription(for: tools))
        let toolSchemas = useNative ? ToolSchema.functionSchemas(for: tools) : []
        let deadline = now().addingTimeInterval(budget)

        var turns: [AgentTurn] = []
        var labels: [String] = []
        /// Calls already made, keyed by tool **and arguments**.
        ///
        /// Keying on the tool name alone was the single biggest limit on what the
        /// agent could do: `list_calendar_events` on Work and then on Personal, or
        /// today and then tomorrow, are two different questions, and the second was
        /// refused as a repeat. What actually needs blocking is the small-model spin
        /// — reading its own result, not recognising it as an answer, and issuing the
        /// *identical* call again — which is what this key catches.
        var madeCalls = Set<String>()
        var messages: [AgentMessage] = [.init(role: .user, text: question)]

        // Reported once, not before every generate. After a call returns, the model
        // is reasoning *about that connector's result*, so holding its caption is
        // both truthful and calmer than flipping back to the generic line between
        // every step — which on a three-call chain would be six caption changes.
        onStep(.thinking)

        for _ in 0..<maxIterations {
            let remaining = deadline.timeIntervalSince(now())
            guard remaining > 0 else { break }

            let raw: String?
            if let generateNative {
                raw = await Self.generateNativeWithinBudget(
                    generateNative,
                    messages: Self.wireMessages(system: systemPrompt, messages),
                    tools: toolSchemas, seconds: remaining)
            } else {
                raw = await Self.generateWithinBudget(
                    generate, text: Self.render(messages), systemPrompt: systemPrompt,
                    seconds: remaining)
            }
            guard let raw else { break }
            turns.append(AgentTurn(role: .model, text: raw))
            messages.append(.init(role: .assistant, text: raw))

            let parsed = useNative
                ? NativeToolCallParser.parse(raw, tools: tools)
                : ToolCallParser.parse(raw, tools: tools)
            switch parsed {
            case .failure(let error):
                turns.append(AgentTurn(role: .system, text: error.modelFeedback))
                messages.append(.init(role: .system, text: "That was invalid: \(error.modelFeedback) Try again."))

            case .success(.answer(let answer)):
                return AgentOutcome(answer: answer, instanceLabels: labels,
                                    turns: turns, exhausted: false)

            case .success(.call(let call)):
                let key = Self.callKey(call)
                if madeCalls.contains(key) {
                    let note = "You already called \(call.tool) with those arguments. "
                        + "Use what it returned, or call something different."
                    turns.append(AgentTurn(role: .system, text: note))
                    messages.append(.init(role: .system, text: note))
                    continue
                }
                madeCalls.insert(key)
                onStep(.running(call))
                let result = await router.run(call)
                // Only `call.tool` — the catalog's own fixed name — reaches analytics.
                // The arguments are the user's dictated content and never leave, the
                // same rule the notch caption and the consent card follow.
                Analytics.shared.send(.assistantToolRun(tool: call.tool, succeeded: result.ok))
                labels.append(contentsOf: result.instanceLabels)
                turns.append(AgentTurn(role: .tool, text: result.text))
                messages.append(.init(role: .tool, text: result.text, tool: call.tool))
                // Nudge toward finishing: without it a 3B will often keep exploring
                // rather than answer from a result it already has. It's a nudge, not a
                // rule — a further call with different arguments is still allowed.
                messages.append(.init(
                    role: .system,
                    text: "Answer now with {\"answer\":\"...\"} if that is enough, "
                        + "otherwise call another tool."))
            }
        }

        // Out of iterations or time with no answer. A partial tool result is *not*
        // turned into an answer here — summarising it ourselves would be inventing the
        // model's conclusion. The caller falls back to the deterministic path.
        //
        // Counted, because this is the interesting failure: the loop spent its whole
        // budget and the user still got the deterministic fallback. Against
        // `Assistant.invoked` it says how often the agent is worth its 30 seconds.
        Analytics.shared.send(.assistantFailed(reason: .budgetExhausted))
        return AgentOutcome(answer: "", instanceLabels: labels, turns: turns, exhausted: true)
    }

    /// One entry in the conversation the model is shown.
    ///
    /// The loop used to keep this as a single `String` it appended to, which made two
    /// things impossible to keep straight: what the model itself said (so it can see
    /// its own malformed attempt next to the correction) and which text came from a
    /// tool rather than from us. Roles are the fix, and they're cheap — the shape a
    /// tool-calling agent normally has.
    struct AgentMessage: Equatable, Sendable {
        enum Role: Sendable { case user, assistant, tool, system }
        let role: Role
        let text: String
        /// Which tool produced this, for `.tool` messages.
        var tool: String?

        init(role: Role, text: String, tool: String? = nil) {
            self.role = role
            self.text = text
            self.tool = tool
        }
    }

    /// Run the generator, and give up on it once the budget is spent.
    ///
    /// The budget used to be checked only *between* iterations, with a bare `await` on
    /// the model in between. The production generator is `MlxCleanupService.clean`, so
    /// a wedged MLX/Metal call held the loop — and the notch's "Working on it" — open
    /// with no ceiling at all, whatever `budget` said.
    ///
    /// The two racers are **unstructured** tasks on purpose: a task group waits for its
    /// children on the way out, which is exactly what a stall makes impossible, so the
    /// abandoned generation has to be one nobody is awaiting. It's cancelled, but a
    /// synchronous MLX generation can't observe that — walking away is the only real
    /// guarantee. A timeout then reads to the caller exactly like a dead generator:
    /// nil, and the loop reports exhausted, rather than a cancellation error the notch
    /// would have to explain.
    private static func generateWithinBudget(_ generate: @escaping Generate,
                                             text: String,
                                             systemPrompt: String,
                                             seconds: TimeInterval) async -> String? {
        let work = Task { await generate(text, systemPrompt) }
        let produced = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let race = FirstPastThePost()
            let timeout = Task {
                try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
                if race.claim() { continuation.resume(returning: nil) }
            }
            Task {
                let value = await work.value
                timeout.cancel()
                if race.claim() { continuation.resume(returning: value) }
            }
        }
        // A no-op when it already finished, and the only thing that can be done about
        // one that hasn't.
        work.cancel()
        return produced
    }

    /// The native twin of `generateWithinBudget`: same walk-away-on-timeout guarantee,
    /// for the structured `(messages, tools)` generator. Kept separate rather than
    /// generic because the two generators have genuinely different argument shapes and
    /// a shared wrapper would only obscure that.
    private static func generateNativeWithinBudget(_ generate: @escaping GenerateNative,
                                                   messages: [[String: String]],
                                                   tools: [String],
                                                   seconds: TimeInterval) async -> String? {
        let work = Task { await generate(messages, tools) }
        let produced = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let race = FirstPastThePost()
            let timeout = Task {
                try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
                if race.claim() { continuation.resume(returning: nil) }
            }
            Task {
                let value = await work.value
                timeout.cancel()
                if race.claim() { continuation.resume(returning: value) }
            }
        }
        work.cancel()
        return produced
    }

    /// The conversation as `[role, content]` pairs for the native chat template, with
    /// the system prompt at the front. Roles map straight through: a `.tool` message
    /// becomes the template's `tool` role (a `<tool_response>` block), and the loop's
    /// `.system` nudges stay `system` — the Qwen3 template renders a non-leading
    /// system message as its own turn.
    static func wireMessages(system: String, _ messages: [AgentMessage]) -> [[String: String]] {
        var wire: [[String: String]] = [["role": "system", "content": system]]
        for message in messages {
            switch message.role {
            case .user: wire.append(["role": "user", "content": message.text])
            case .assistant: wire.append(["role": "assistant", "content": message.text])
            case .tool: wire.append(["role": "tool", "content": message.text])
            case .system: wire.append(["role": "system", "content": message.text])
            }
        }
        return wire
    }

    /// Flatten the conversation into the single prompt string the MLX generator takes.
    ///
    /// The generator's signature is `(userText, systemPrompt)` — it's
    /// `MlxCleanupService.clean`, which primes a KV cache on the system prompt and
    /// feeds the rest as one block — so the roles are rendered as labelled turns
    /// rather than passed as a message array. Keeping them structured up to this
    /// point is still what makes the transcript coherent and testable; only the last
    /// step is textual.
    static func render(_ messages: [AgentMessage]) -> String {
        messages.map { message in
            switch message.role {
            case .user: return "Question: \(message.text)"
            case .assistant: return "You replied: \(message.text)"
            case .tool: return "\(message.tool ?? "tool") returned:\n\(message.text)"
            case .system: return message.text
            }
        }.joined(separator: "\n\n")
    }

    /// A call's identity for repeat detection: the tool plus its arguments, with keys
    /// sorted so dictionary ordering can't make the same call look like a new one.
    private static func callKey(_ call: ToolCall) -> String {
        let arguments = call.arguments
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "&")
        return "\(call.tool)?\(arguments)"
    }
}
