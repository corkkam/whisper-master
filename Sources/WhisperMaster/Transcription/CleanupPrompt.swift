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

    /// S1-mini has no separate "polish" prompt — it has **styling**. The heavier
    /// mode asks for formal styling rather than a different system prompt, so both
    /// modes share one primed KV cache instead of thrashing it on every toggle.
    ///
    /// Note this is a genuine change in kind: the 3B rewrote grammar, and S1-mini
    /// normalizes. It is not a rewriter and will not restructure a sentence, which
    /// is why the Settings copy for that toggle no longer promises one.
    enum Styling: String {
        case semiFormal = "semi-formal"
        case formal
    }

    /// The user turn: control line, newline, transcript. Structure and context are
    /// pinned — the notch dictates into arbitrary apps, so "prose" and "general" are
    /// the only honest answers, and guessing "email" from a transcript would change
    /// how it formats for a reason the user never asked for.
    static func userTurn(_ transcript: String, grammarPolish: Bool) -> String {
        let styling: Styling = grammarPolish ? .formal : .semiFormal
        return "[Styling: \(styling.rawValue)] [Structure: prose] [Context: general]\n\(transcript)"
    }

    /// One system prompt for both modes now, kept for call-site compatibility.
    static func resolved(grammarPolish: Bool) -> String { system }
}
