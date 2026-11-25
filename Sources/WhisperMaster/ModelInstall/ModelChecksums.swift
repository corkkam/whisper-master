import Foundation

/// Per-archive SHA-256 pins for the model archives served from the R2 mirror
/// (`https://dl.corkkam.com/models/<archiveName>.zip`). This is a compiled-in
/// constant, so it ships **inside** the Sparkle/EdDSA-signed app bundle: an
/// attacker who can write the (unsigned) R2 bucket still cannot move the expected
/// hash, so `ModelInstaller` rejects a swapped archive before it is ever unpacked.
///
/// ⚠️ Publish-time obligation: after uploading a new or updated `<archive>.zip`
/// to R2, add or update its lowercase-hex SHA-256 here — an archive with **no**
/// pin is refused by `ModelInstaller` (fail closed), so a new model does not
/// install at all until it is pinned. Compute it with `shasum -a 256 <archive>.zip`.
///
/// A pin that disagrees with the hosted bytes is a failed download: `ModelInstaller`
/// refuses the archive before unpacking it, and the caller falls back to Hugging Face
/// (the assistant through `LabHuggingFace.download`, the natural voice through
/// `KokoroAneManager.initialize()`). If that fails too, the assistant keeps whatever
/// model is already on disk and answers are read by the system voice.
///
/// **Hugging Face only (owner decision, 2026-11-24):** `Qwen3-4B-Thinking-2507-4bit`
/// (the previous assistant), `kokoro-82m-coreml` and `kokoro` (the natural voice) are not
/// uploaded to R2. They are listed in `huggingFaceOnly`, so `ModelInstaller` makes no
/// mirror request for them and `Scripts/release.sh` does not check them. Their pins
/// stay: the zips they describe are kept outside the repository in
/// `~/code/whisper/model-archives/` on the release Mac. To put one on the mirror,
/// **upload that exact file** (`ditto` embeds timestamps, so a re-zip hashes
/// differently and this pin would reject it), then remove it from `huggingFaceOnly`.
/// `Scripts/release.sh` refuses to release while any other archive pinned here is not
/// on the mirror.
enum ModelChecksums {
    /// Pinned archives that are deliberately not on the mirror. `ModelInstaller`
    /// throws `InstallError.huggingFaceOnly` for these before any request, so the
    /// caller goes to Hugging Face at once. `Scripts/release.sh` reads this list from
    /// this file (one quoted name per line) and skips these in its mirror check.
    static let huggingFaceOnly: Set<String> = [
        "Qwen3-4B-Thinking-2507-4bit",
        "kokoro-82m-coreml",
        "kokoro",
    ]

    /// `archiveName` (no `.zip`) → lowercase hex SHA-256 of the hosted `.zip`.
    static let sha256: [String: String] = [
        // Copied byte-for-byte from the legacy bucket to the live one rather than
        // re-zipped from the model directory —
        // `ditto` embeds timestamps, so a re-zip of identical files produces a
        // different hash and this pin would reject it.
        "s1-mini-4bit": "517d5091f6c5ac8c8af9a67f1cece60f9cf9899560652e38ba5ca4f788bc17aa",
        "Qwen3-4B-Instruct-2507-4bit": "cedaaf80d01fc27bfcfecf8b5582c5ce23a7e9662f8f54fff3131ba93b3e8410",
        "parakeet-tdt-0.6b-v2": "8ccbec0158b6abe9c33e8f741eaac77cf34d5f81f5a1020851b65388e63654ca",
        "Qwen2.5-3B-Instruct-4bit": "d5ed6d71e317535b7e9016bde99c0fe419c2cff36b690c2f43f29637cc2c008b",
        "Qwen3-4B-Thinking-2507-4bit": "f93ce2af99ba2316bc4bca39c006f687bd41725fa351cb447eb7d8dd1b2593a8",
        // The natural voice (`NaturalVoiceInstaller`). Built 2026-10-14 from
        // FluidInference/kokoro-82m-coreml @ d93c5f3e; the source copies of both zips
        // are kept outside git in `~/code/whisper/model-archives/`. Upload those exact
        // files: a re-zip changes the hash.
        "kokoro-82m-coreml": "672a96284f38e9ca73b19af8989314b6818f7dc057997170b95b1f0745d2bde4",
        "kokoro": "866d21e9ef063dbcde24d27d5ad522572af2bf04c8656ba572df7903beed4681",
    ]
}
