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
/// - **Tool calling, intent and meeting notes** (`CleanupModel.General`) is
///   **Qwen3-4B-Thinking-2507** since 2026-10-17 (Qwen3-4B-Instruct-2507 before
///   that, which is still used where it is the only assistant on disk). It reasons
///   before answering, so its `<think>` block is stripped by `MlxCleanupService`
///   before anything parses the output.
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
    /// **Nothing downloads this at launch.** It is loaded only when it is already
    /// on disk; `AssistantModelManager` fetches it on the first use of the chord or
    /// from Settings, so a new install is not made to fetch 2.3 GB for a feature it
    /// may never touch.
    enum General {
        /// **Qwen3-4B-Thinking-2507** since 2026-10-17, chosen as the best reasoning
        /// model that loads on the pinned mlx-swift-examples 2.29.1 (Qwen3.5 needs
        /// 2.31.3+). It always reasons before answering, so every call to it goes
        /// through the reasoning budget (`MlxCleanupService.reasoningMaxTokens` /
        /// `reasoningTimeoutSeconds`) and the agent loop gets `AgentLoop.reasoningBudget`.
        /// The cost, measured in the Lab on 2026-10-04 (16 tool cases, M5): 15/16 at
        /// 10.7 s p50 / 64 s p95, against Instruct-2507's 16/16 at 3.9 s. To go back,
        /// swap these ids with `previousArchiveName` and restore the
        /// `.shippingAssistant` badge in `LabCatalog`; `thinks` follows from the directory.
        static let archiveName = "Qwen3-4B-Thinking-2507-4bit"
        static let huggingFaceId = "mlx-community/Qwen3-4B-Thinking-2507-4bit"
        static let label = "assistant model"

        /// **The assistant before 2026-10-17** (Qwen3-4B-Instruct-2507, non-thinking).
        /// Every install that used the chord before the switch has it on disk, and the
        /// Thinking archive is not on the mirror yet, so ignoring it would mean an update
        /// leaves the assistant on the keyword gate while 2.3 GB downloads, or for good
        /// if that download fails. It answers until the shipped model has arrived; the
        /// bytes are left in place afterwards, like every other model.
        static let previousArchiveName = "Qwen3-4B-Instruct-2507-4bit"

        /// The model the assistant loads: a **dev build's** Model Lab choice when it has
        /// one (`LabModelOverride`, which refuses on every other channel and falls back
        /// whenever the chosen model is not on disk), else `installedDirectory`.
        static var directory: URL {
            LabModelOverride.directory(for: .assistant) ?? installedDirectory
        }

        /// Where the mirror unpacks the shipped model.
        static var shippedDirectory: URL {
            CleanupModel.modelsRoot.appendingPathComponent(archiveName, isDirectory: true)
        }

        /// Where the Hugging Face fallback lands: MLX's own hub cache, the same place
        /// the Lab reads (`LabPaths.huggingFaceCacheDirectory`). Without this a model
        /// fetched through the fallback was on disk but `isInstalled` never saw it, so
        /// `prepareGeneralIfInstalled` skipped it on every later launch.
        static var hubCacheDirectory: URL {
            LabPaths.huggingFaceCacheDirectory(for: huggingFaceId)
        }

        static var previousDirectory: URL {
            CleanupModel.modelsRoot.appendingPathComponent(previousArchiveName, isDirectory: true)
        }

        /// The shipped model from the mirror, else from Hugging Face, else the previous
        /// assistant, else the mirror path (so a fresh install still writes where it
        /// always has).
        static var installedDirectory: URL {
            resolveInstalledDirectory { LabPaths.isInstalled(at: $0) }
        }

        /// `installedDirectory`'s order, with the filesystem check injected so the order
        /// is tested without a 2 GB model on disk.
        static func resolveInstalledDirectory(isInstalled: (URL) -> Bool) -> URL {
            [shippedDirectory, hubCacheDirectory, previousDirectory].first(where: isInstalled)
                ?? shippedDirectory
        }

        /// Something loadable is on disk: the shipped model, the previous one, or a dev
        /// build's override.
        static var isInstalled: Bool { LabPaths.isInstalled(at: directory) }

        /// Whether the shipped model is still owed a download. The previous assistant
        /// standing in does not count, and neither does a dev build's override, which
        /// is running the model it was pointed at on purpose.
        static var needsShippedModel: Bool {
            LabModelOverride.directory(for: .assistant) == nil
                && !LabPaths.isInstalled(at: shippedDirectory)
                && !LabPaths.isInstalled(at: hubCacheDirectory)
        }

        /// Whether the model in `directory` reasons before answering. Only the shipped
        /// model does: the previous assistant is non-thinking, and `LabModelOverride`
        /// never hands the slot a reasoning row.
        static func thinks(loadedFrom directory: URL) -> Bool {
            let path = directory.standardizedFileURL.path
            return path == shippedDirectory.standardizedFileURL.path
                || path == hubCacheDirectory.standardizedFileURL.path
        }

        /// Whether the assistant will reason, judged from the directory it would load
        /// now. For sizing a budget before the model is loaded; generation itself reads
        /// what was actually loaded (`MlxCleanupService.loadedThinks`), because a Lab
        /// override or a finished download changes this answer before the resident
        /// model changes.
        static var thinks: Bool { thinks(loadedFrom: directory) }
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
