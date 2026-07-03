import Foundation

/// Resolves the `TextFormatting` instance to use for the current preference.
///
/// The default is the deterministic rule engine — instant, on-device, no model.
/// The Apple on-device LLM is used **only** when the user opts in
/// (`AppleIntelligencePreference`) and it can run (macOS 26 + `FoundationModels`).
/// While opted out, the Apple session is never created and any prior one is
/// dropped, so no model stays resident. One actor so local dictation and remote
/// sessions share a single (optional) warmed session.
actor TextFormatterProvider {
    static let shared = TextFormatterProvider()

    private let deterministic: TextFormatting = DeterministicTextFormatter()
    private var apple: TextFormatting?

    /// The formatter for the current preference. Creates the Apple session lazily
    /// only when opted in; drops it when opted out (freeing the model).
    func current() -> TextFormatting {
        #if canImport(FoundationModels)
        if #available(macOS 26, *), AppleIntelligencePreference.isEnabled {
            if apple == nil { apple = AppleTextFormatter() }
            return apple!
        }
        #endif
        apple = nil
        return deterministic
    }

    /// Drop any cached Apple session immediately — called when the user turns the
    /// opt-in off, so the on-device model stops consuming resources right away.
    func releaseApple() { apple = nil }
}
