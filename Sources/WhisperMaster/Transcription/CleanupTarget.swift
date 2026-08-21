import Foundation

/// A cleanup / format mode the eval can grade. `light` and `polish` are the
/// shipped Settings toggles; `slack`, `email`, and `code` are eval-only
/// destinations (à la Wispr Flow) so we can measure app-aware formatting
/// without wiring those prompts into the paste path.
///
/// Adding a target is: a case here + a prompt + cases that list it. The runner
/// and scorer take `rawValue` as an opaque string.
enum CleanupTarget: String, CaseIterable {
    case light
    case polish
    case slack
    case email
    case code

    var allowsRephrase: Bool { self != .light }

    /// **One system prompt for every target.** S1-mini takes its destination from the
    /// control line's axes (`CleanupPrompt.axes(for:)`), not from differently-worded
    /// instructions, so the per-target prompts the general model needed are gone.
    var prompt: String { CleanupPrompt.system }
}
