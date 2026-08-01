@preconcurrency import AVFoundation

/// Speaks through macOS's own speech service — the default backend, and the fallback
/// whenever the natural one can't run.
///
/// **This is playback, not capture.** It never touches `AVAudioEngine` and never reads or
/// writes a Core Audio device property, which is exactly why it's safe to run beside
/// `MicrophoneCaptureService` (see the device-juggling prohibitions in the root
/// `CLAUDE.md`). Synthesis happens out of process in `speechsynthesisd`, so the only
/// thing resident here is a thin `AVSpeechSynthesizer` proxy — no model, no download,
/// no entitlement, and nothing measurable in our memory footprint.
///
/// The synthesizer is a stored property on purpose: a locally-created one deallocates
/// mid-utterance and the voice stops in the middle of a word.
@MainActor
final class SystemSpeechSynthesizer: SpeechSynthesizing {

    /// Slightly above `AVSpeechUtteranceDefaultSpeechRate` (0.5). A brisk answer reads
    /// as confident; the default reads as a clinical announcement.
    static let rate: Float = 0.52

    private let synthesizer = AVSpeechSynthesizer()
    private let bridge = DelegateBridge()
    private var continuation: CheckedContinuation<Void, Never>?

    /// Read at speak time rather than captured, so changing the voice in Settings takes
    /// effect on the very next answer without anything having to be rebuilt.
    private let voiceIdentifier: @MainActor () -> String

    init(voiceIdentifier: @escaping @MainActor () -> String) {
        self.voiceIdentifier = voiceIdentifier
        bridge.owner = self
        synthesizer.delegate = bridge     // `delegate` is weak; `bridge` is our strong ref
    }

    var isSpeaking: Bool { synthesizer.isSpeaking }

    /// Speaks the sentences as **one** utterance.
    ///
    /// The chunking `SpokenAnswer` did is a hard requirement of the natural backend, not
    /// of this one — and joining the pieces back up gives better prosody (the synthesizer
    /// reads across the punctuation itself) plus exactly one `didFinish` to wait on.
    func speak(_ sentences: [String]) async {
        let text = sentences.joined(separator: " ")
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }

        // A second answer supersedes the first. Re-enqueueing while speaking would also
        // raise an Objective-C exception, which is an abort() no `try` can catch.
        stop()

        // Always a fresh utterance — an `AVSpeechUtterance` cannot be re-spoken.
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = SystemVoiceCatalog.resolve(voiceIdentifier())
        utterance.rate = Self.rate
        utterance.volume = 1              // relative to system output volume
        utterance.preUtteranceDelay = 0
        utterance.postUtteranceDelay = 0

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.continuation = continuation
            synthesizer.speak(utterance)
        }
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        // Resume right away rather than waiting for `didCancel`: barge-in has to be
        // synchronous from the caller's point of view, and a cancel callback that never
        // arrives would otherwise hang the awaiting task forever.
        utteranceEnded()
    }

    /// Idempotent — `stop()` and a later `didCancel` both land here.
    fileprivate func utteranceEnded() {
        continuation?.resume()
        continuation = nil
    }
}

/// AVFoundation delivers these callbacks on an unspecified queue, and
/// `AVSpeechSynthesizerDelegate`'s requirements are non-isolated. A `@MainActor` type
/// conforming directly would be satisfying them with main-actor methods — a warning
/// today and an error under Swift 6 — so the conformance lives on this plain shim, which
/// hops to the main actor before touching anything.
private final class DelegateBridge: NSObject, AVSpeechSynthesizerDelegate {
    weak var owner: SystemSpeechSynthesizer?

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let owner = owner
        Task { @MainActor in owner?.utteranceEnded() }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let owner = owner
        Task { @MainActor in owner?.utteranceEnded() }
    }
}
