import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers

/// On-device transcript cleanup via MLX. Two instances, two models: `shared` is
/// S1-mini on the dictation hot path, `general` is Qwen3-4B-Instruct-2507 for the
/// callers that need to tool-call.
///
/// An `actor` so the (large, single) model loads once and is shared without
/// races. It is deliberately dumb: given a loaded model it cleans a string; it
/// knows nothing about downloads/toggles/UI (that's `CleanupModelManager`).
///
/// **⚠️ Each cleanup gets a fresh KV cache, and that is a correctness rule, not a
/// performance choice.** A persistent system-prompt cache was reused across calls
/// and trimmed back afterwards. `trimPromptCache` takes one count for all 28 of
/// Qwen3's per-layer caches, so once the layers drift out of sync no count is
/// right, and **one dictation's keys survived into the next one's generation** —
/// the eval caught text from an earlier transcript appearing verbatim in a later
/// output. Whatever that does to quality, a local dictation app must not let one
/// recording's content bleed into another's pasted text.
///
/// It also flattered the eval: cases were feeding each other context, so scores
/// were better than any real user's first dictation could be. See
/// `generateFresh`.
///
/// `clean` returns `nil` on any problem (not ready, timeout, failure, empty) so
/// the caller falls straight back to the deterministic text — cleanup can only
/// ever help, never block.
actor MlxCleanupService {
    /// The **cleanup** model: S1-mini, on the dictation hot path.
    static let shared = MlxCleanupService()

    /// The **general instruct** model, for the two callers that need one — the
    /// connector agent and the intent classifier. A separate instance because it is
    /// a separate model with a separate KV cache; sharing one would thrash the cache
    /// between two system prompts on every chord.
    static let general = MlxCleanupService()

    /// Load the general model **only if it is already on disk**. Never downloads:
    /// see `CleanupModel.General`. Cheap and idempotent, so the assistant paths can
    /// just call it before they generate.
    static func prepareGeneralIfInstalled() async {
        guard CleanupModel.General.isInstalled else { return }
        await general.prepare(
            configuration: ModelConfiguration(directory: CleanupModel.General.directory))
    }

    /// Safety net against a runaway decode, not a normal-path limit. Generous so
    /// a merely-slow generation still cleans rather than silently falling back.
    static let timeoutSeconds: Double = 12.0

    /// Hard ceiling on a *single* load/warmup attempt. A stalled MLX/Metal init
    /// (seen under launch-time GPU contention) would otherwise wedge the model on
    /// "Preparing…" forever; on timeout we fail cleanly so the manager can retry.
    static let loadTimeoutSeconds: Double = 60

    /// Serial holder for the reused KV cache + its system prefix length.
    /// `@unchecked Sendable` is safe: the actor plus `container.perform` guarantee
    /// strictly one-at-a-time access; nothing here is touched concurrently.
    private final class CacheBox: @unchecked Sendable {
        var cache: [KVCache] = []
        var systemOffset = 0
        var primed = false
        /// Which system prompt the cache was primed for. When the caller switches
        /// modes (light cleanup vs grammar polish) the prompt changes, so the KV
        /// prefix is stale and must be re-primed.
        var primedPrompt: String?

        /// **Every layer, not just the first.**
        ///
        /// This is the bug that made long-form cleanup fail after a few hundred
        /// generations while the identical input in isolation came out clean.
        /// Qwen3 keeps one `KVCache` per layer — 28 of them — and both the primed
        /// check and the post-generation trim asked only `cache.first`. But
        /// `trimPromptCache` trims each layer independently and a layer can trim
        /// **less than it was asked for**. Layer 0 landing back on `systemOffset`
        /// therefore proved nothing about layers 1…27, which kept residue from the
        /// previous transcript. The next call then attended to another dictation's
        /// keys — which is exactly what the eval saw: content from elsewhere in the
        /// text appearing at the top of the output, and sentences repeating.
        ///
        /// Residue also compounds, which is why a short run never showed it.
        func isAtSystemOffset(_ offset: Int) -> Bool {
            !cache.isEmpty && cache.allSatisfy { $0.offset == offset }
        }
    }

    private enum LoadState {
        case idle, loading, ready(ModelContainer), failed
    }
    private var state: LoadState = .idle
    private let box = CacheBox()

    /// Whether the model is loaded and `clean` can run.
    var isReady: Bool {
        if case .ready = state { return true }
        return false
    }

    /// Load the MLX model for a configuration — a local directory (the R2 mirror
    /// path) or a Hugging Face id (fallback, downloads on demand, progress via
    /// `onProgress`). Idempotent; also prefills the system prompt (warmup).
    func prepare(
        configuration: ModelConfiguration,
        onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async {
        switch state {
        case .ready, .loading: return
        case .idle, .failed: state = .loading
        }

        let started = DispatchTime.now()
        func elapsedMs() -> Int {
            Int(Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e6)
        }

        do {
            Log.modelPrep.notice("MLX cleanup: loading container\u{2026}")
            let container = try await Self.withTimeout(Self.loadTimeoutSeconds) {
                try await LLMModelFactory.shared.loadContainer(configuration: configuration) {
                    onProgress($0.fractionCompleted)
                }
            }
            let loadMs = elapsedMs()
            Log.modelPrep.notice("MLX cleanup: container loaded in \(loadMs)ms; priming prompt\u{2026}")
            let box = self.box
            try await Self.withTimeout(Self.loadTimeoutSeconds) {
                try await Self.primeSystemPrompt(container: container, box: box)
            }
            state = .ready(container)
            Log.modelPrep.notice("MLX cleanup model ready (total \(elapsedMs())ms, load \(loadMs)ms)")
        } catch {
            state = .failed
            Log.modelPrep.error(
                "MLX cleanup model load failed after \(elapsedMs())ms: \(error.localizedDescription, privacy: .public)")
        }
    }

    private enum LoadError: Error { case timedOut }

    /// Race an async operation against a timeout. On timeout the losing child is
    /// cancelled and `LoadError.timedOut` is thrown, so a stalled load surfaces as
    /// a clean failure instead of an unbounded await.
    private static func withTimeout<T: Sendable>(
        _ seconds: Double, _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw LoadError.timedOut
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    /// Drop the model + cache to free memory (feature turned off).
    ///
    /// Dropping the container releases the weight arrays, but MLX pools freed
    /// Metal buffers for reuse instead of returning them to the OS — so the
    /// ~2.3 GB stays resident until we explicitly clear that pool. Order matters:
    /// release the container first, then clear the cache so the just-freed
    /// buffers are actually handed back.
    func release() {
        state = .idle
        box.cache = []
        box.primed = false
        MLX.GPU.clearCache()
    }

    /// Clean one transcript. Returns `nil` (→ caller keeps original) if the model
    /// isn't ready, input is empty, or generation times out / throws. Output is
    /// *not* trusted here — `CleanupFaithfulnessGuard` vets it upstream.
    /// `target` selects S1-mini's control-line *axes* rather than a second system
    /// prompt, so every target shares one primed KV cache.
    func clean(
        _ text: String, systemPrompt: String = CleanupPrompt.system,
        target: CleanupTarget = .light
    ) async -> String? {
        guard case .ready(let container) = state else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // **A long dictation is cleaned in pieces, not truncated.** Past ~390 words
        // of output the `maxTokens` ceiling below cut the generation mid-sentence,
        // and the faithfulness guard's 30% floor was far too loose to notice — see
        // `TranscriptChunker`. Splitting at sentence boundaries keeps every pass in
        // the range the model was trained for.
        //
        // Not for `.email`: that context lays out a greeting, body and sign-off
        // across the *whole* text, so cleaning it in pieces would produce a greeting
        // per chunk. An over-long email keeps the single pass it always had.
        if CleanupPrompt.axes(for: target).2 == .general,
           TranscriptChunker.needsChunking(trimmed) {
            return await cleanInPieces(trimmed, systemPrompt: systemPrompt, target: target)
        }

        return await cleanOnePass(trimmed, systemPrompt: systemPrompt, target: target,
                                  container: container)
    }

    /// Clean each piece and rejoin. **A piece that fails keeps its own raw text**
    /// rather than vanishing: the alternative is silently returning three quarters
    /// of someone's paragraph, which is the exact failure this path exists to stop.
    /// The guard upstream still vets the joined result as a whole.
    private func cleanInPieces(
        _ text: String, systemPrompt: String, target: CleanupTarget
    ) async -> String? {
        guard case .ready(let container) = state else { return nil }
        let pieces = TranscriptChunker.chunks(text)
        guard !pieces.isEmpty else { return nil }

        var out: [String] = []
        var anyCleaned = false
        for piece in pieces {
            let cleaned = await cleanOnePass(piece, systemPrompt: systemPrompt,
                                             target: target, container: container)
            if let cleaned, !cleaned.isEmpty {
                anyCleaned = true
                out.append(cleaned)
            } else {
                // S1-mini returns an empty string for filler-only input, which its
                // card calls a valid result. At chunk scale that is nearly always a
                // failed pass rather than a genuinely empty paragraph, and keeping
                // the words is the safe reading of an ambiguous one.
                out.append(piece)
            }
        }
        // If nothing cleaned, this is a failed run, not a cleanup that changed
        // nothing — say so, so the caller keeps the deterministic text.
        guard anyCleaned else { return nil }
        return out.joined(separator: " ")
    }

    private func cleanOnePass(
        _ trimmed: String, systemPrompt: String, target: CleanupTarget,
        container: ModelContainer
    ) async -> String? {
        let wordCount = trimmed.split { $0 == " " || $0 == "\n" || $0 == "\t" }.count
        let maxTokens = min(512, max(48, wordCount * 2 + 32))

        do {
            // The control line is part of the input format, not decoration: without
            // it the model has no styling/structure/context to normalise against.
            let user = CleanupPrompt.userTurn(trimmed, target: target)
            let raw = try await container.perform { (context: ModelContext) in
                try Self.generateFresh(
                    context: context, user: user,
                    maxTokens: maxTokens, systemPrompt: systemPrompt)
            }
            return Self.sanitize(raw)
        } catch {
            return nil
        }
    }

    /// Generate against the model's **native** tool-calling posture: structured
    /// messages plus function schemas rendered through the chat template's `tools`
    /// mechanism, so Qwen3 emits its own `<tool_call>{"name":…,"arguments":…}</tool_call>`
    /// format rather than the hand-rolled `{"tool":…}` shape.
    ///
    /// Deliberately separate from `clean`, and it must stay that way: **no KV-cache
    /// reuse.** The prompt — messages *and* tools — differs every turn, so there is no
    /// stable prefix to reuse, and touching `box` here would corrupt the cleanup
    /// path's primed system-prompt cache. A fresh cache is built per call.
    ///
    /// Returns `nil` on any problem, exactly like `clean`, so the loop can fall back
    /// to the hand-rolled path. `messages` is `[role, content]` pairs; `toolSchemasJSON`
    /// is one JSON function schema per tool. Both are plain value types so they cross
    /// the actor boundary without a Sendable escape hatch — the `[String: Any]`
    /// `ToolSpec` the tokenizer wants is rebuilt here, inside the actor.
    func generateWithTools(
        messages: [[String: String]],
        toolSchemasJSON: [String],
        maxTokens: Int = 512
    ) async -> String? {
        guard case .ready(let container) = state else { return nil }
        guard !messages.isEmpty else { return nil }

        let tools: [ToolSpec] = toolSchemasJSON.compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }
        let chatMessages: [Message] = messages.map { message -> Message in
            ["role": message["role"] ?? "user", "content": message["content"] ?? ""]
        }

        do {
            let raw = try await container.perform { (context: ModelContext) -> String in
                let tokens = try context.tokenizer.applyChatTemplate(
                    messages: chatMessages, chatTemplate: nil, addGenerationPrompt: true,
                    truncation: false, maxLength: nil,
                    tools: tools.isEmpty ? nil : tools,
                    // Same `enable_thinking: false` every other render passes. Without
                    // it a template that honours the flag opens a reasoning block, and
                    // the tool call — if it survives at all — arrives after a wall of
                    // text the parser has to dig through.
                    additionalContext: Self.templateContext)
                let input = LMInput(tokens: MLXArray(tokens.map { Int32($0) }))
                // A fresh cache, never the primed cleanup one.
                let cache = context.model.newCache(parameters: nil)
                let params = GenerateParameters(maxTokens: maxTokens, temperature: 0)
                let iterator = try TokenIterator(
                    input: input, model: context.model, cache: cache, parameters: params)
                let start = Date()
                let result = MLXLMCommon.generate(
                    input: input, context: context, iterator: iterator
                ) { (_: [Int]) in
                    Date().timeIntervalSince(start) > Self.timeoutSeconds ? .stop : .more
                }
                Stream.gpu.synchronize()
                return result.output
            }
            return Self.sanitize(raw)
        } catch {
            return nil
        }
    }

    /// Generate for the **agent loop**: the conversation exactly as written, against
    /// the agent's own system prompt, with a fixed token ceiling.
    ///
    /// **The agent must not go through `clean`, and this is why.** `clean` is the
    /// transcript-cleanup path, and it does three things to its input that are correct
    /// for a dictation and wrong for a tool-calling turn:
    ///
    /// - it prepends the cleanup **control line**
    ///   (`[Styling: …] [Structure: prose] [Context: general]`), which tells the model
    ///   to normalise prose in the same breath the agent prompt tells it to emit one
    ///   JSON object and nothing else;
    /// - it sizes `maxTokens` from the **input** word count (`words * 2 + 32`, floor
    ///   48), which is the right rule for a rewrite — output length tracks input
    ///   length — and the wrong one here, where the shortest command can need the
    ///   longest call. The floor of 48 happened to cover every case in the bench, so
    ///   this is a latent fault rather than a measured one; a fixed ceiling costs
    ///   nothing and removes it;
    /// - it **chunks** anything past `TranscriptChunker.maxWords` (240) into pieces,
    ///   generates each one separately and joins them with a space. **This one is
    ///   measured.** Given a 460-word conversation — one day's calendar merged across
    ///   two connections — `ToolCallParser` then took the first balanced JSON object
    ///   out of the joined text and dropped the rest: the answer covered the work
    ///   calendar alone and gave its range as 01:00–07:00 against data saying
    ///   01:00–09:00. Reproduced on both runs. Nothing reported the loss.
    ///
    /// None of that is `clean`'s fault — it was never the agent's generator. Returns
    /// `nil` on the same terms as `clean`, so the loop's budget race and fallback are
    /// unchanged. `AgentToolEval`'s `via clean` arm is the regression guard.
    func generateAgent(
        _ user: String, systemPrompt: String, maxTokens: Int = 384
    ) async -> String? {
        guard case .ready(let container) = state else { return nil }
        let trimmed = user.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            let raw = try await container.perform { (context: ModelContext) in
                try Self.generateFresh(
                    context: context, user: trimmed,
                    maxTokens: maxTokens, systemPrompt: systemPrompt)
            }
            return Self.sanitize(raw)
        } catch {
            return nil
        }
    }

    /// The shipped path has two toggles, not five targets.
    func clean(
        _ text: String, systemPrompt: String = CleanupPrompt.system, grammarPolish: Bool
    ) async -> String? {
        await clean(text, systemPrompt: systemPrompt, target: grammarPolish ? .polish : .light)
    }

    // MARK: - Cached generation

    /// Ensure the persistent cache holds exactly the system-prompt KV. Cheap when
    /// already primed; re-prefills if never primed or left in a bad offset.
    private static func primeSystemPrompt(
        container: ModelContainer, box: CacheBox, systemPrompt: String = CleanupPrompt.system
    ) async throws {
        try await container.perform { (context: ModelContext) in
            try ensurePrimed(context: context, box: box, systemPrompt: systemPrompt)
            Stream.gpu.synchronize()
        }
    }

    private static func ensurePrimed(context: ModelContext, box: CacheBox, systemPrompt: String) throws {
        if box.primed, box.primedPrompt == systemPrompt,
           box.isAtSystemOffset(box.systemOffset) { return }

        let sysTokens = try context.tokenizer.applyChatTemplate(
            messages: [["role": "system", "content": systemPrompt]],
            chatTemplate: nil, addGenerationPrompt: false,
            truncation: false, maxLength: nil, tools: nil,
            additionalContext: Self.templateContext)
        box.systemOffset = sysTokens.count
        box.cache = context.model.newCache(parameters: nil)

        // Prefill: run one step so every system token (including the last) lands
        // in the cache, then stop — the single sampled token is never fed back,
        // so the cache ends at exactly `systemOffset`.
        let input = LMInput(tokens: MLXArray(sysTokens.map { Int32($0) }))
        let params = GenerateParameters(maxTokens: 1, temperature: 0)
        let iterator = try TokenIterator(input: input, model: context.model, cache: box.cache, parameters: params)
        _ = MLXLMCommon.generate(input: input, context: context, iterator: iterator) { (_: [Int]) in .stop }
        box.primed = true
        box.primedPrompt = systemPrompt
    }

    /// Generate a cleanup against a **fresh cache**, prompt tokenized whole.
    ///
    /// This replaced a persistent system-prompt KV cache that was reused across
    /// calls and trimmed back afterwards, and removing it fixed two opposite bugs
    /// that the eval caught from both ends:
    ///
    /// - **Reuse corrupted long-form output.** Qwen3 keeps one `KVCache` per layer
    ///   — 28 — and `trimPromptCache` takes a single count for all of them, so when
    ///   the layers drift out of sync no number is right. Trimming by layer 0's
    ///   figure left the rest long, and the next call attended to the *previous*
    ///   transcript's keys: 207 words back from a 521-word dictation in one run, a
    ///   sentence repeated 19 times in another.
    /// - **Re-priming degraded short output.** Detecting the drift and re-prefilling
    ///   instead measurably made cleanups worse — "translate good morning into
    ///   spanish" lost the word "translate"; another case came back untouched. The
    ///   delta arithmetic against a re-primed prefix does not reliably reproduce the
    ///   prompt the model was trained on.
    ///
    /// **The optimisation had also stopped paying.** It was written for a ~600-token
    /// system prompt where re-prefilling dominated latency. S1-mini's trained system
    /// prompt is ~45 tokens, so there is almost nothing left to save — and it was
    /// buying that nothing with every failure mode above. Measured after the change:
    /// no latency regression.
    ///
    /// What is left is what the model card's own reference implementation does:
    /// tokenize `[system, user]`, generate, done.
    private static func generateFresh(
        context: ModelContext, user: String, maxTokens: Int, systemPrompt: String
    ) throws -> String {
        let tokens = try context.tokenizer.applyChatTemplate(
            messages: [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": user],
            ],
            chatTemplate: nil, addGenerationPrompt: true,
            truncation: false, maxLength: nil, tools: nil,
            additionalContext: Self.templateContext)

        let input = LMInput(tokens: MLXArray(tokens.map { Int32($0) }))
        let params = GenerateParameters(maxTokens: maxTokens, temperature: 0)
        let cache = context.model.newCache(parameters: nil)
        let iterator = try TokenIterator(
            input: input, model: context.model, cache: cache, parameters: params)

        let start = Date()
        let result = MLXLMCommon.generate(input: input, context: context, iterator: iterator) {
            (_: [Int]) in Date().timeIntervalSince(start) > timeoutSeconds ? .stop : .more
        }
        Stream.gpu.synchronize()
        return result.output
    }

    /// Generate a cleanup for `user` reusing the cached system prefix, then trim
    /// the cache back to the system offset for the next call.
    ///
    /// **Unused by the cleanup path** — see `generateFresh` for why. Kept only
    /// because `primeSystemPrompt` still warms Metal at load time.
    private static func generateCached(
        context: ModelContext, box: CacheBox, user: String, maxTokens: Int, systemPrompt: String
    ) throws -> String {
        try ensurePrimed(context: context, box: box, systemPrompt: systemPrompt)

        // Delta = the [system,user] tokenization minus the cached system prefix.
        let full = try context.tokenizer.applyChatTemplate(
            messages: [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": user],
            ],
            chatTemplate: nil, addGenerationPrompt: true,
            truncation: false, maxLength: nil, tools: nil,
            additionalContext: Self.templateContext)
        guard full.count > box.systemOffset else { return "" }
        let delta = Array(full[box.systemOffset...])

        let input = LMInput(tokens: MLXArray(delta.map { Int32($0) }))
        let params = GenerateParameters(maxTokens: maxTokens, temperature: 0)
        let iterator = try TokenIterator(input: input, model: context.model, cache: box.cache, parameters: params)

        let start = Date()
        let result = MLXLMCommon.generate(input: input, context: context, iterator: iterator) { (_: [Int]) in
            Date().timeIntervalSince(start) > timeoutSeconds ? .stop : .more
        }
        Stream.gpu.synchronize()

        // Restore the cache to just the system prefix for the next call. If that
        // can't be done cleanly on **every** layer, drop priming so the next call
        // re-prefills from scratch — see `CacheBox.isAtSystemOffset`. Trimming is
        // per-layer and can come up short, and a layer left long is another
        // transcript's keys bleeding into the next generation.
        // `trimPromptCache` takes ONE count for every layer, so when the layers
        // disagree no single number is right: layer 0's figure leaves the others
        // long (the original bug — another transcript's keys survive into the next
        // call), and the maximum over-trims layer 0 and eats part of the system
        // prefix (measured: four short cases regressed). When they disagree the
        // correct move is to trim nothing and rebuild, which costs ~45 tokens.
        let offsets = Set(box.cache.map(\.offset))
        if offsets.count == 1, let offset = offsets.first {
            let extra = offset - box.systemOffset
            if extra > 0 { trimPromptCache(box.cache, numTokens: extra) }
        }
        if !box.isAtSystemOffset(box.systemOffset) {
            box.primed = false
            // Cheap now and worth knowing: S1-mini's system prompt is ~45 tokens,
            // so re-priming costs almost nothing. It was ~600 under the old model,
            // which is the only reason this reuse machinery exists at all.
            Log.modelPrep.debug("Cleanup KV cache would not trim cleanly; re-priming")
        }

        return result.output
    }

    /// **`enable_thinking: false`.** S1-mini carries a Qwen3 chat template, which
    /// defaults to emitting a `<think>` block. Left on, every cleaned transcript
    /// arrives wrapped in reasoning the guard correctly refuses, so the pass looks
    /// broken rather than off. The model card names this as the single commonest
    /// integration bug, and it is invisible until you read the raw output.
    private static let templateContext: [String: Any] = ["enable_thinking": false]

    // MARK: - Helpers

    /// Trim whitespace and strip a wrapping pair of quotes the model sometimes
    /// adds despite the prompt. Returns `nil` for an empty result.
    private static func sanitize(_ raw: String) -> String? {
        var out = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Second line of defence for the thinking block: if a template ever ignores
        // `enable_thinking`, keep what follows the block rather than pasting the
        // model's reasoning into someone's message.
        if let close = out.range(of: "</think>") {
            out = String(out[close.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if out.count >= 2, let first = out.first, let last = out.last,
           (first == "\"" && last == "\"") || (first == "\u{201C}" && last == "\u{201D}") {
            out = String(out.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return out.isEmpty ? nil : out
    }
}
