import Foundation

/// Where the on-device qwen cleanup model lives on disk and how we know it's a
/// *complete* install. Mirrors `TranscriberEngine`'s convention (same
/// Application Support root) so the cleanup model sits beside the voice engine.
///
/// One model serves both jobs: transcript cleanup (`MlxCleanupService`) and the
/// spoken-command tool-calling loop (`AgentLoop`, through the same service). The
/// move from `Qwen2.5-3B-Instruct` to `Qwen3-4B-Instruct-2507` is for the
/// tool-calling tier: the 2507 instruct build carries a real function-calling
/// posture (and is non-thinking by default, so it never emits `<think>` blocks
/// that would break the loop's single-JSON parse), which is where the old model
/// declined and dropped the words into a note. Any change here re-runs
/// `eval/text-cleanup/run-eval.sh` and re-tunes `CleanupFaithfulnessGuard`
/// (tuned to the previous model's failure modes) before shipping.
enum CleanupModel {
    /// R2 archive base name (`<archiveName>.zip` on the mirror) and the unpacked
    /// directory name — identical so the zip's top-level folder matches on disk.
    static let archiveName = "Qwen3-4B-Instruct-2507-4bit"

    /// Hugging Face id, used only as the dev / first-run fallback when the R2
    /// mirror is unavailable (see `CleanupModelManager`).
    static let huggingFaceId = "mlx-community/Qwen3-4B-Instruct-2507-4bit"

    /// Human label used in progress/log text.
    static let label = "smart cleanup model"

    static var modelsRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    /// The unpacked model directory MLX loads from.
    static var directory: URL {
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
