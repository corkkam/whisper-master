import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers

/// On-device transcript cleanup using qwen2.5-3B via MLX.
///
/// An `actor` so the (large, single) model loads once and is shared without
/// races. It is deliberately dumb: given a loaded model it cleans a string; it
/// knows nothing about downloads/toggles/UI (that's `CleanupModelManager`).
///
/// **System-prompt KV caching.** The cleanup system prompt is ~600 tokens and is
/// identical on every call. Re-prefilling it each time dominates latency, so we
/// prefill it once into a persistent KV cache (this doubles as Metal-kernel
/// warmup) and per call feed only the *delta* tokens — the user turn — then
/// `trimPromptCache` back to the system offset. Correct by construction: the
/// `[system]` tokenization (no generation prompt) is a strict prefix of the
/// `[system, user]` tokenization, so the delta is just a slice.
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
    /// ~1.8 GB stays resident until we explicitly clear that pool. Order matters:
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
    /// `grammarPolish` selects S1-mini's *styling* axis rather than a second system
    /// prompt, so both modes share one primed KV cache.
    func clean(
        _ text: String, systemPrompt: String = CleanupPrompt.system, grammarPolish: Bool = false
    ) async -> String? {
        guard case .ready(let container) = state else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let wordCount = trimmed.split { $0 == " " || $0 == "\n" || $0 == "\t" }.count
        let maxTokens = min(512, max(48, wordCount * 2 + 32))

        let box = self.box
        do {
            // The control line is part of the input format, not decoration: without
            // it the model has no styling/structure/context to normalise against.
            let user = CleanupPrompt.userTurn(trimmed, grammarPolish: grammarPolish)
            let raw = try await container.perform { (context: ModelContext) in
                try Self.generateCached(
                    context: context, box: box, user: user,
                    maxTokens: maxTokens, systemPrompt: systemPrompt)
            }
            return Self.sanitize(raw)
        } catch {
            return nil
        }
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
        if box.primed, box.primedPrompt == systemPrompt, box.cache.first?.offset == box.systemOffset { return }

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

    /// Generate a cleanup for `user` reusing the cached system prefix, then trim
    /// the cache back to the system offset for the next call.
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
        // can't be done cleanly, drop priming so the next call re-prefills.
        let offset = box.cache.first?.offset ?? box.systemOffset
        let extra = offset - box.systemOffset
        if extra > 0 { trimPromptCache(box.cache, numTokens: extra) }
        if box.cache.first?.offset != box.systemOffset { box.primed = false }

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
