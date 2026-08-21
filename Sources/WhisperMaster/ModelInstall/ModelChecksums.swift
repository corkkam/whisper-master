import Foundation

/// Per-archive SHA-256 pins for the model archives served from the R2 mirror
/// (`https://dl.corkkam.com/models/<archiveName>.zip`). This is a compiled-in
/// constant, so it ships **inside** the Sparkle/EdDSA-signed app bundle: an
/// attacker who can write the (unsigned) R2 bucket still cannot move the expected
/// hash, so `ModelInstaller` rejects a swapped archive before it is ever unpacked.
///
/// ⚠️ Publish-time obligation: after uploading a new or updated `<archive>.zip`
/// to R2, add or update its lowercase-hex SHA-256 here — otherwise the archive
/// ships **unverified** (it installs through the safety-valve branch in
/// `ModelInstaller`). Compute it with `shasum -a 256 <archive>.zip`. A pin that
/// disagrees with the hosted bytes is treated as a failed download and falls back
/// to the slower HuggingFace source.
enum ModelChecksums {
    /// `archiveName` (no `.zip`) → lowercase hex SHA-256 of the hosted `.zip`.
    static let sha256: [String: String] = [
        // The bytes currently served from the **legacy** bucket
        // (`model.scoopscore.in/models/s1-mini-4bit.zip`). Copy that object to the
        // live bucket byte-for-byte rather than re-zipping the model directory —
        // `ditto` embeds timestamps, so a re-zip of identical files produces a
        // different hash and this pin would reject it.
        "s1-mini-4bit": "517d5091f6c5ac8c8af9a67f1cece60f9cf9899560652e38ba5ca4f788bc17aa",
        "Qwen3-4B-Instruct-2507-4bit": "cedaaf80d01fc27bfcfecf8b5582c5ce23a7e9662f8f54fff3131ba93b3e8410",
        "parakeet-tdt-0.6b-v2": "8ccbec0158b6abe9c33e8f741eaac77cf34d5f81f5a1020851b65388e63654ca",
        "Qwen2.5-3B-Instruct-4bit": "d5ed6d71e317535b7e9016bde99c0fe419c2cff36b690c2f43f29637cc2c008b",
    ]
}
