import Foundation

/// The prompt for the on-device cleanup pass.
///
/// **The model is `S1-mini by Superwhisper`** — a 0.6B text normalizer fine-tuned
/// from Qwen3-0.6B, Apache 2.0 with one extra term: wherever it is used it must keep
/// that exact name, which is why the name appears verbatim here and in the Settings
/// copy. It replaced qwen2.5-3B-Instruct, which was a general instruct model doing
/// this job badly enough that the whole pass had to be off by default: 1.5 GB and
/// ~250 ms for **the same 85/89** on `eval/text-cleanup/cases.jsonl`, where S1-mini
/// is 335 MB and ~130 ms.
///
/// **Three things about the format are load-bearing, and every integration bug
/// traces to one of them** (the model card says so, and it is right):
///
/// 1. The system prompt is **exact**. It is not a prompt to be tuned — it is the
///    string the model was trained against, so an "improvement" here is a
///    regression. Do not rewrite it.
/// 2. The user turn begins with a **control line** naming styling, structure and
///    context, then a newline, then the raw transcript.
/// 3. **`enable_thinking` must be false.** It is a Qwen3 template, so it defaults to
///    a thinking block; left on, the output arrives wrapped in `<think>` and the
///    guard rightly rejects all of it. `MlxCleanupService` passes it through
///    `additionalContext`, and `sanitize` strips a stray block as a second line of
///    defence.
enum CleanupPrompt {

    /// Verbatim from the model card. Changing a character changes the model's
    /// behaviour for the worse.
    static let system = """
        You are a text normalizer for speech-to-text transcripts. The input begins with a control line specifying the styling, structure, and context settings; clean the transcript to match those settings and output only the cleaned text.
        """

    /// **S1-mini has no per-target *prompt* — it has axes.** Where the outgoing
    /// general model needed a differently-worded system prompt per destination
    /// (`slack`, `email`, `code`), this model takes one trained system prompt and a
    /// control line, so a target is a *setting*, not a rewrite. That also means every
    /// target shares one primed KV cache instead of thrashing it on each switch.
    ///
    /// The axes are fixed by the model card and only these values exist.
    enum Styling: String {
        case casual
        case semiCasual = "semi-casual"
        case semiFormal = "semi-formal"
        case formal
    }

    enum Structure: String { case prose, lists }
    enum Context: String { case general, email }

    /// How a `CleanupTarget` becomes a control line.
    ///
    /// `.code` is the honest gap: S1-mini has no code notion, and there is no axis
    /// that would give it one, so it takes the plain reading and is documented as
    /// unsupported rather than faked with a styling that means something else.
    static func axes(for target: CleanupTarget) -> (Styling, Structure, Context) {
        switch target {
        case .light: return (.semiFormal, .prose, .general)
        case .polish: return (.formal, .prose, .general)
        case .slack: return (.casual, .prose, .general)
        case .email: return (.semiFormal, .prose, .email)
        case .code: return (.semiFormal, .prose, .general)
        }
    }

    /// The user turn: control line, newline, transcript.
    static func userTurn(_ transcript: String, target: CleanupTarget) -> String {
        let (styling, structure, context) = axes(for: target)
        return "[Styling: \(styling.rawValue)] [Structure: \(structure.rawValue)] "
            + "[Context: \(context.rawValue)]\n\(transcript)"
    }

    /// The shipped path only has the two toggles, so it keeps a boolean.
    static func userTurn(_ transcript: String, grammarPolish: Bool) -> String {
        userTurn(transcript, target: grammarPolish ? .polish : .light)
    }

    /// One system prompt for every target now — the axes carry the difference — kept
    /// as a function so the call sites did not all have to change.
    static func resolved(grammarPolish: Bool) -> String { system }
}
