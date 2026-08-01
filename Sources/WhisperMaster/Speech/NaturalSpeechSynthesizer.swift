@preconcurrency import AVFoundation
import FluidAudio
import Foundation

/// Speaks through Kokoro-82M on the Apple Neural Engine — the opt-in "natural" voice.
///
/// The models come from **FluidAudio**, which the app already depends on for ASR, so this
/// adds no new package and no version bump. `KokoroAneManager` splits the 7-stage chain
/// so the heavy layers (Albert / PostAlbert / Alignment / Vocoder) run on the **ANE**
/// rather than Metal — which is why it can coexist with the 1.8 GB MLX qwen without
/// fighting it for GPU memory.
///
/// Three things keep the memory cost honest and the experience non-janky:
///
/// - **Idle unload.** `cleanup()` drops the loaded `.mlmodelc`s after
///   `idleUnloadSeconds` of quiet, so the footprint is transient rather than permanent.
/// - **Never a long silence.** The first load takes seconds (CoreML + ANE compile), so a
///   cold answer is spoken by the *system* voice while the models warm in the background.
///   The next answer gets the natural voice.
/// - **Never silence at all.** Any failure — not installed, load threw, synthesis threw —
///   hands the remaining sentences to the system synthesizer. Same principle as
///   `MlxCleanupService` returning `nil` so the caller keeps the deterministic text:
///   the optional thing can only ever improve the result, never remove it.
///
/// Playback is `AVAudioPlayer` over the 24 kHz WAV the manager returns. Deliberately not
/// `AVAudioEngine`: the recording graph is the one thing this must not perturb.
@MainActor
final class NaturalSpeechSynthesizer: SpeechSynthesizing {

    /// How long the models stay resident after the last word. Long enough that a
    /// follow-up question doesn't pay the load again, short enough that an idle Mac
    /// isn't holding a TTS model open all afternoon.
    static let idleUnloadSeconds: UInt64 = 120

    /// Reported when the models are resident, and when something went wrong — relayed up
    /// to `AppState` so Settings can show "ready" or offer a retry.
    var onReady: @MainActor () -> Void = {}
    var onFailure: @MainActor (String) -> Void = { _ in }

    private let fallback: SystemSpeechSynthesizer
    private let voiceIdentifier: @MainActor () -> String
    private let manager = KokoroAneManager(variant: .english)
    private let playbackBridge = PlaybackBridge()

    private var isLoaded = false
    private var loadTask: Task<Void, Never>?
    private var unloadTask: Task<Void, Never>?
    private var player: AVAudioPlayer?
    private var playbackContinuation: CheckedContinuation<Void, Never>?
    /// Set by `stop()`; checked between sentences so barge-in lands within one utterance
    /// rather than at the end of the whole answer.
    private var stopped = false

    init(fallback: SystemSpeechSynthesizer, voiceIdentifier: @escaping @MainActor () -> String) {
        self.fallback = fallback
        self.voiceIdentifier = voiceIdentifier
        playbackBridge.owner = self
    }

    var isSpeaking: Bool { player?.isPlaying == true || fallback.isSpeaking }

    /// True once the chain is resident — Settings uses it to say so, and to decide
    /// whether a preview will be instant or warm first.
    var isReady: Bool { isLoaded }

    // MARK: - Speaking

    func speak(_ sentences: [String]) async {
        guard !sentences.isEmpty else { return }
        stop()
        stopped = false
        unloadTask?.cancel()

        guard NaturalVoiceInstaller.isInstalled else {
            await fallback.speak(sentences)
            return
        }
        guard isLoaded else {
            // Cold. Warming here would mean seconds of silence after a question, so the
            // system voice takes this one and the natural voice takes the next.
            prewarm()
            await fallback.speak(sentences)
            return
        }

        await speakNaturally(sentences)
        scheduleIdleUnload()
    }

    /// Synthesises sentence *n+1* while *n* is playing, so only the first sentence pays
    /// synthesis latency. This is also why `SpokenAnswer` chunks at all — `KokoroAneManager`
    /// rejects anything over 512 IPA tokens.
    private func speakNaturally(_ sentences: [String]) async {
        let voice = voiceIdentifier()
        var pending: Task<Data?, Never>? = synthesize(sentences[0], voice: voice)

        for index in sentences.indices {
            if stopped { return }
            guard let data = await pending?.value else {
                // Synthesis died mid-answer. Finish the thought in the system voice
                // rather than trailing off into nothing.
                if !stopped { await fallback.speak(Array(sentences[index...])) }
                return
            }
            let next = index + 1
            pending = next < sentences.count ? synthesize(sentences[next], voice: voice) : nil
            if stopped { return }
            await play(data)
        }
    }

    private func synthesize(_ text: String, voice: String) -> Task<Data?, Never> {
        Task.detached { [manager] in
            do {
                return try await manager.synthesize(text: text, voice: voice)
            } catch {
                Log.modelPrep.error(
                    "Natural voice synthesis failed: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
    }

    private func play(_ data: Data) async {
        guard let player = try? AVAudioPlayer(data: data) else { return }
        player.delegate = playbackBridge
        player.volume = 1
        self.player = player
        player.prepareToPlay()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            playbackContinuation = continuation
            if !player.play() { playbackEnded() }
        }
    }

    func stop() {
        stopped = true
        player?.stop()
        player = nil
        playbackEnded()
        fallback.stop()
    }

    /// Idempotent — reached from `stop()`, from a failed `play()`, and from the delegate.
    fileprivate func playbackEnded() {
        playbackContinuation?.resume()
        playbackContinuation = nil
    }

    // MARK: - Model lifecycle

    /// Load the models in the background. Called when the user picks the natural voice,
    /// when they preview it, and on the first (system-voiced) answer after a cold start.
    func prewarm() {
        guard !isLoaded, loadTask == nil, NaturalVoiceInstaller.isInstalled else { return }
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let started = Date()
                try await self.manager.initialize()
                self.isLoaded = true
                self.loadTask = nil
                Log.modelPrep.notice(
                    "Natural voice ready in \(Int(Date().timeIntervalSince(started) * 1000))ms")
                self.onReady()
            } catch {
                self.loadTask = nil
                Log.modelPrep.error(
                    "Natural voice failed to load: \(error.localizedDescription, privacy: .public)")
                self.onFailure(error.localizedDescription)
            }
        }
    }

    private func scheduleIdleUnload() {
        unloadTask?.cancel()
        unloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.idleUnloadSeconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.unload()
        }
    }

    /// Hands the models back. This is the answer to "won't a neural voice bloat memory":
    /// it's resident while you're using it and gone a couple of minutes later.
    func unload() async {
        guard isLoaded else { return }
        isLoaded = false
        await manager.cleanup()
        Log.modelPrep.notice("Natural voice unloaded after idle")
    }
}

/// `AVAudioPlayerDelegate`'s requirements are non-isolated and the callback arrives off
/// the main actor, so — exactly as with the speech-synthesizer delegate — the conformance
/// lives on a plain shim that hops before touching anything.
private final class PlaybackBridge: NSObject, AVAudioPlayerDelegate {
    weak var owner: NaturalSpeechSynthesizer?

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let owner = owner
        Task { @MainActor in owner?.playbackEnded() }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let owner = owner
        Task { @MainActor in owner?.playbackEnded() }
    }
}
