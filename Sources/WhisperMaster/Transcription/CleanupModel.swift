import Foundation

/// Where the on-device cleanup model lives on disk and how we know it's a
/// *complete* install. Mirrors `TranscriberEngine`'s convention (same
/// Application Support root) so the cleanup model sits beside the voice engine.
///
/// **Two models, because these are two jobs.** `dev` and this branch reached the same
/// conclusion from opposite ends: dev by moving the shared model up to
/// `Qwen3-4B-Instruct-2507` *for the tool-calling tier*, this branch by measuring that
/// a 0.6B normalizer beats a general instruct model at cleanup. Both were right about
/// their own half, so the merge keeps both halves:
///
/// - **Cleanup** (`MlxCleanupService.shared`, the dictation hot path) is
///   **S1-mini** — 335 MB, ~100 ms, and better than the 3B it replaced on
///   `eval/text-cleanup/cases.jsonl`.
/// - **Tool calling and intent** (`CleanupModel.General`) is
///   **Qwen3-4B-Instruct-2507** — dev's choice and dev's reasoning: the 2507 instruct
///   build carries a real function-calling posture and is non-thinking by default, so
///   it never emits `<think>` blocks that would break the loop's single-JSON parse.
///
/// Any change to either re-runs `eval/text-cleanup/run-eval.sh` and re-checks
/// `CleanupFaithfulnessGuard`, which is tuned to a model's failure modes.
enum CleanupModel {
    /// R2 archive base name (`<archiveName>.zip` on the mirror) and the unpacked
    /// directory name — identical so the zip's top-level folder matches on disk.
    static let archiveName = "s1-mini-4bit"

    /// Hugging Face id, used only as the dev / first-run fallback when the R2
    /// mirror is unavailable (see `CleanupModelManager`).
    /// The upstream weights are BF16 safetensors; the shipped build is our own
    /// 4-bit MLX conversion, mirrored on R2. This id is the last-resort fallback
    /// only — a failed load costs nothing, because the deterministic text has
    /// already been pasted by then.
    static let huggingFaceId = "superwhisper/s1-mini"

    /// Human label used in progress/log text.
    static let label = "smart cleanup model"

    /// **The general instruct model, which is a different job.**
    ///
    /// S1-mini is a text *normalizer*: the model card is explicit that it is not a
    /// chat model and will not follow general instructions. Two paths in this app
    /// need one that does — `AgentLoop` (the connector assistant behind the chord)
    /// and the intent classifier — because they pass their own tool-calling prompts
    /// and parse structured answers back.
    ///
    /// So they keep qwen. Swapping them onto S1-mini would not fail loudly: the
    /// agent would return normalised prose, no tool would execute,
    /// `CommandAgentService` would correctly read that as "did not act", and the
    /// whole assistant would quietly fall back to the keyword gate forever.
    ///
    /// **Nothing downloads this on its own.** It is loaded only when it is already
    /// on disk, so an existing install keeps its assistant and a new one is not made
    /// to fetch 1.5 GB for a feature it may never touch. Giving this its own
    /// download affordance is the obvious follow-up.
    enum General {
        /// **Qwen3-4B-Thinking-2507** since 2026-10-17, chosen as the best reasoning
        /// model that loads on the pinned mlx-swift-examples 2.29.1 (Qwen3.5 needs
        /// 2.31.3+). It always reasons before answering, so every call goes through
        /// the reasoning budget (`MlxCleanupService.reasoningMaxTokens` /
        /// `reasoningTimeoutSeconds`) and the agent loop gets `AgentLoop.reasoningBudget`.
        /// The cost, measured in the Lab on 2026-10-04 (16 tool cases, M5): 15/16 at
        /// 10.7 s p50 / 64 s p95, against Instruct-2507's 16/16 at 3.9 s. To go back,
        /// restore the Instruct ids here and the `.shippingAssistant` badge in
        /// `LabCatalog`; `thinks` follows from the directory.
        static let archiveName = "Qwen3-4B-Thinking-2507-4bit"
        static let huggingFaceId = "mlx-community/Qwen3-4B-Thinking-2507-4bit"
        static let label = "assistant model"

        /// Whether the loaded assistant reasons first. True for the shipped model;
        /// false when a dev build points the slot at another model from the Lab,
        /// which never allows a reasoning row there (`LabModelOverride`).
        static var thinks: Bool {
            LabModelOverride.directory(for: .assistant) == nil
        }

        /// The shipped assistant model, unless a **dev build** has been pointed
        /// at another one from the Model Lab (`LabModelOverride`, which refuses
        /// on every other channel and falls back here whenever the chosen model
        /// is not on disk).
        static var directory: URL {
            LabModelOverride.directory(for: .assistant) ?? installedDirectory
        }

        static var shippedDirectory: URL {
            CleanupModel.modelsRoot.appendingPathComponent(archiveName, isDirectory: true)
        }

        /// Where the Hugging Face fallback lands: MLX's `HubApi` default,
        /// `~/Documents/huggingface/models/<repo>`. Without this, a model fetched
        /// through the fallback was on disk but `isInstalled` never saw it, so
        /// `prepareGeneralIfInstalled` skipped it on every later launch.
        static var hubCacheDirectory: URL {
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("huggingface/models/\(huggingFaceId)", isDirectory: true)
        }

        /// The mirror install if present, else the Hugging Face one, else the
        /// mirror path (so a fresh install still writes where it always has).
        static var installedDirectory: URL {
            if hasModel(at: shippedDirectory) { return shippedDirectory }
            if hasModel(at: hubCacheDirectory) { return hubCacheDirectory }
            return shippedDirectory
        }

        static var isInstalled: Bool { hasModel(at: directory) }

        private static func hasModel(at url: URL) -> Bool {
            let fm = FileManager.default
            return fm.fileExists(atPath: url.appendingPathComponent("config.json").path)
                && fm.fileExists(atPath: url.appendingPathComponent("tokenizer.json").path)
        }
    }

    static var modelsRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    /// The unpacked model directory MLX loads from.
    ///
    /// A **dev build** can point this at another open-source model from the Model
    /// Lab; see `LabModelOverride` for the three fences on that. Every other
    /// channel, and any override naming a model that is not installed, gets
    /// `shippedDirectory`.
    static var directory: URL {
        LabModelOverride.directory(for: .cleanup) ?? shippedDirectory
    }

    /// Where the model this build actually ships with lives, override or no
    /// override. The installer writes here.
    static var shippedDirectory: URL {
        modelsRoot.appendingPathComponent(archiveName, isDirectory: true)
    }

    /// True only when the MLX weights, config, and tokenizer are all present. A
    /// partial or interrupted unpack reads as not installed, so the mirror
    /// re-fetches it rather than MLX failing to load a half-written folder.
    static var isInstalled: Bool {
        let fm = FileManager.default
        let config = directory.appendingPathComponent("config.json")
        let tokenizer = directory.appendingPathComponent("tokenizer.json")
        guard fm.fileExists(atPath: config.path), fm.fileExists(atPath: tokenizer.path) else { return false }
        let contents = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        return contents.contains { $0.hasSuffix(".safetensors") }
    }
}
