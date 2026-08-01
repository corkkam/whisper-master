import AppKit
import Foundation

/// Which voice reads the answers.
enum AnswerVoiceEngine: String, CaseIterable, Identifiable {
    /// A voice macOS already has. Nothing downloaded, nothing resident in our process.
    case system
    /// Kokoro on the Neural Engine. Better, opt-in, ~310 MB on disk, unloaded when idle.
    case natural

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .natural: return "Natural"
        }
    }
}

/// Reads an assistant answer aloud.
///
/// Sits between `DictationViewModel` and the two backends: prepares the text, picks the
/// engine, enforces the rules about *when* it's appropriate to talk at all, and reports
/// when it starts and stops — but never writes `AppState` itself. The owner does that,
/// because "the view model is the ONLY thing that mutates `PrototypeAppState`" (root
/// `CLAUDE.md`) and a speaking flag is no exception.
///
/// Created on demand rather than at launch: a user who never turns this on should never
/// cause an `AVSpeechSynthesizer` to exist, and neither `swift test` nor the headless
/// snapshot renderer should either.
@MainActor
final class AnswerSpeaker {

    /// Everything the speaker needs from `AppState`, read fresh at each call so a change
    /// in Settings takes effect on the very next answer.
    struct Preferences {
        var engine: AnswerVoiceEngine
        var systemVoiceIdentifier: String
        var naturalVoiceID: String
    }

    /// A recording has only just finished when the first answer lands. Opening a player
    /// into a capture graph that is still tearing itself down is the kind of thing that
    /// provokes an `AVAudioEngineConfigurationChange` — which `MicrophoneCaptureService`
    /// survives by rebuilding the engine, but not provoking it is cheaper than surviving
    /// it. A fifth of a second is inaudible as a delay and well clear of the teardown.
    private static let leadInNanoseconds: UInt64 = 250_000_000

    /// Nothing we say should run longer than this. `SpokenAnswer` already caps the text,
    /// so hitting this means a backend wedged — and a wedged backend would otherwise pin
    /// the notch banner open forever, because its clock is paused while we "speak".
    static let maxHoldSeconds: TimeInterval = 90

    /// Fired when speech starts and when it ends. The owner turns this into
    /// `AppState.isSpeakingAnswer`.
    var onStateChange: @MainActor (Bool) -> Void = { _ in }
    /// Natural-voice readiness, for the Settings status line.
    var onNaturalReady: @MainActor () -> Void = {}
    var onNaturalFailure: @MainActor (String) -> Void = { _ in }

    private let preferences: @MainActor () -> Preferences
    private lazy var system = SystemSpeechSynthesizer(
        voiceIdentifier: { [preferences] in preferences().systemVoiceIdentifier })
    private var natural: NaturalSpeechSynthesizer?
    private var speakTask: Task<Void, Never>?

    /// When the current utterance began — the watchdog's input for the ceiling above.
    private(set) var startedAt: Date?

    init(preferences: @escaping @MainActor () -> Preferences) {
        self.preferences = preferences
    }

    /// True while an utterance is in flight, including its lead-in. This — not the
    /// backend's `isSpeaking` — is what the reconcile loop trusts, because during the
    /// lead-in no audio is playing yet and the banner must already be held.
    var isRunning: Bool { speakTask != nil }

    // MARK: - Speaking

    /// Say an answer. Returns whether it will actually be spoken, so the caller knows
    /// whether to hold the notch banner open for a voice.
    ///
    /// - Parameter detail: the banner's second line — pass `nil` where it's provenance
    ///   chrome. See `SpokenAnswer.prepare`.
    @discardableResult
    func speak(headline: String, detail: String?) -> Bool {
        let sentences = SpokenAnswer.prepare(headline: headline, detail: detail)
        guard !sentences.isEmpty else { return false }
        // VoiceOver is already reading the banner. Two voices over each other is worse
        // than either alone.
        guard !NSWorkspace.shared.isVoiceOverEnabled else { return false }

        stop()
        let backend = resolvedBackend()
        startedAt = Date()
        onStateChange(true)

        speakTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.leadInNanoseconds)
            guard let self, !Task.isCancelled else { return }
            await backend.speak(sentences)
            guard !Task.isCancelled else { return }
            self.speakTask = nil
            self.startedAt = nil
            self.onStateChange(false)
        }
        return true
    }

    /// Cut it off now — barge-in, a superseding answer, or the app quitting. Cheap,
    /// unconditional and safe to call when nothing is speaking.
    func stop() {
        speakTask?.cancel()
        speakTask = nil
        startedAt = nil
        system.stop()
        natural?.stop()
        onStateChange(false)
    }

    /// Speak a fixed line so the user can hear a voice before committing to it. The same
    /// shape as a real answer rather than "Hello", so the preview is honest.
    func preview() {
        speak(headline: "You have three meetings today. The first one starts at ten.", detail: nil)
    }

    // MARK: - Backends

    private func resolvedBackend() -> SpeechSynthesizing {
        switch preferences().engine {
        case .system:
            return system
        case .natural:
            return naturalBackend()
        }
    }

    private func naturalBackend() -> NaturalSpeechSynthesizer {
        if let natural { return natural }
        let backend = NaturalSpeechSynthesizer(
            fallback: system,
            voiceIdentifier: { [preferences] in preferences().naturalVoiceID })
        backend.onReady = { [weak self] in self?.onNaturalReady() }
        backend.onFailure = { [weak self] reason in self?.onNaturalFailure(reason) }
        natural = backend
        return backend
    }

    /// Whether the natural models are loaded and ready to speak instantly.
    var naturalVoiceIsReady: Bool { natural?.isReady ?? false }

    /// Start loading the natural models in the background so the *first* answer isn't
    /// the one that pays for it. Safe to call repeatedly — it no-ops unless there's work.
    func prewarmNaturalVoiceIfNeeded() {
        guard preferences().engine == .natural, NaturalVoiceInstaller.isInstalled else { return }
        naturalBackend().prewarm()
    }

    /// Hand the natural models back immediately — used when the user switches away from
    /// the natural voice, rather than waiting out its idle timer.
    func releaseNaturalVoice() {
        guard let natural else { return }
        Task { await natural.unload() }
    }
}
