import Foundation

/// A thing that can say sentences out loud.
///
/// Two implementations sit behind this: `SystemSpeechSynthesizer` (macOS's own voices,
/// nothing resident in our process) and `NaturalSpeechSynthesizer` (Kokoro on the Neural
/// Engine, opt-in). The seam exists so `AnswerSpeaker` — and everything above it — never
/// learns which one is talking, and so the natural backend can hand a failed utterance
/// straight to the system one rather than leaving the user in silence.
///
/// `speak` is `async` and **returns when the speech is over** — finished or cancelled.
/// That's what lets the caller hold the notch banner open for exactly as long as the
/// voice runs, with no polling and no completion-handler nesting.
@MainActor
protocol SpeechSynthesizing: AnyObject {
    /// Say each sentence in order. Returns once the last one has been spoken, or
    /// immediately after `stop()` cuts it short. Never throws: a backend that can't
    /// speak reports it its own way and returns, because a thrown error here would
    /// only ever be swallowed into "stay quiet".
    func speak(_ sentences: [String]) async

    /// Cut the current utterance off now. Safe to call when nothing is speaking, and
    /// safe to call repeatedly — this is the barge-in path, so it has to be cheap and
    /// unconditional.
    func stop()

    /// Whether audio is actually playing. The source of truth for the watchdog that
    /// reconciles `AppState.isSpeakingAnswer`, so it must reflect the backend's own
    /// view rather than a flag we set optimistically.
    var isSpeaking: Bool { get }
}
