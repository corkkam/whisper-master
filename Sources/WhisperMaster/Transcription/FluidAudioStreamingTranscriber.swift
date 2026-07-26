@preconcurrency import AVFoundation
import FluidAudio
import Foundation

actor FluidAudioStreamingTranscriber {
    enum TranscriberError: Error {
        case notStarted
    }

    private let config: SlidingWindowAsrConfig
    private let previewConfig: SlidingWindowAsrConfig
    private let modelVersion: AsrModelVersion
    private var manager: SlidingWindowAsrManager
    private var updatesTask: Task<Void, Never>?
    /// The low-latency second track. See `previewStreamingConfig` for why it
    /// exists and `StreamingTranscriptUpdate.isPreview` for what may be done with
    /// its output (show it; nothing else).
    private var previewManager: SlidingWindowAsrManager
    private var previewUpdatesTask: Task<Void, Never>?
    private var started = false
    /// Loaded once, then reused across the manager recreations in stop()/cancel()
    /// so a session teardown never re-downloads or re-reads the model from disk.
    /// Shared by both tracks — `AsrManager.loadModels` only retains references to
    /// the `MLModel`s, so two managers over one `AsrModels` is safe and costs no
    /// extra memory or load time.
    private var loadedModels: AsrModels?

    /// Config for the **preview** track.
    ///
    /// The accurate track cannot be fast: `SlidingWindowAsrManager` only decodes
    /// once it holds `chunkSeconds + rightContextSeconds` of audio, so at the
    /// shipped 11 s + 2 s it emits *nothing at all* for the first 13 seconds — and
    /// a typical dictation is shorter than that, so the notch stayed empty until
    /// the key came up. (`SlidingWindowAsrConfig.hypothesisChunkSeconds` advertises
    /// "quick hypothesis updates for immediate feedback", but nothing in FluidAudio
    /// ever reads it — there is no hypothesis track to turn on.)
    ///
    /// So a second manager runs alongside with a short window: first words at
    /// roughly 1.8 s and a refresh every 1.5 s. It is deliberately *sloppy* —
    /// `confirmationThreshold: 0` promotes every window so the text accumulates
    /// rather than showing only the newest window, accuracy be damned. Nothing
    /// downstream of the notch ever sees it.
    ///
    /// Do **not** lower the accurate track's `chunkSeconds` to get this effect
    /// instead: `finish()` reconstructs the final transcript from these same
    /// windows, so shorter windows mean less acoustic context per decode and a
    /// worse transcript — which is the one thing that actually gets pasted.
    private static let previewStreamingConfig = SlidingWindowAsrConfig(
        chunkSeconds: 1.5,
        hypothesisChunkSeconds: 1.5,
        leftContextSeconds: 2.0,
        rightContextSeconds: 0.3,
        minContextForConfirmation: 0.0,
        confirmationThreshold: 0.0
    )

    /// - Parameter modelVersion: `.v3` is the multilingual Parakeet (default,
    ///   25 European languages); `.v2` is the English-only model — same size,
    ///   slightly better English WER, and without v3's documented long-form
    ///   English chunk-boundary glitches (FluidAudio issue #594).
    init(config: SlidingWindowAsrConfig = .streaming, modelVersion: AsrModelVersion = .v2) {
        self.modelVersion = modelVersion
        // v2 uses blankId 1024, v3 uses 8192 — pass it explicitly rather than
        // relying on the decoder's internal blank-token auto-adaptation.
        self.config = config.applying(tdtConfig: TdtConfig(blankId: modelVersion.blankId))
        self.previewConfig = Self.previewStreamingConfig
            .applying(tdtConfig: TdtConfig(blankId: modelVersion.blankId))
        self.manager = SlidingWindowAsrManager(config: self.config)
        self.previewManager = SlidingWindowAsrManager(config: self.previewConfig)
    }

    // NOTE: FluidAudio's CTC vocabulary boosting is deliberately NOT used.
    // In streaming mode its rescorer corrupts the transcript — it empties a
    // vocabulary-dense utterance entirely and truncates others by half (proven
    // by the AudioReplayTests A/B: vocab ON → P5 0 words, P2 halved). Custom
    // vocabulary is instead applied as a safe post-processing text replacement
    // (`VocabularyPostProcessor`) on the finished transcript.

    /// A buffer of digital silence at the engine's 16 kHz mono working format.
    /// Streamed just before `finish()` to stand in for the trailing room tone a
    /// live push-to-talk recording lacks: the user releases the key the instant
    /// they stop talking, so the final window never gets its right-context and
    /// the last word or two drop. A short silence gives that context back.
    /// (Recorded files don't need this — they have natural trailing silence.)
    private static func silenceBuffer(seconds: Double) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
        else { return nil }
        let frames = AVAudioFrameCount(seconds * format.sampleRate)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
        else { return nil }
        buffer.frameLength = frames
        if let channel = buffer.floatChannelData {
            memset(channel[0], 0, Int(frames) * MemoryLayout<Float>.size)
        }
        return buffer
    }
}

extension FluidAudioStreamingTranscriber: LocalStreamingTranscriber {
    func prepareModels(
        progress: @escaping @Sendable (DownloadUtils.DownloadProgress) -> Void
    ) async throws {
        if loadedModels != nil { return }
        let models = try await AsrModels.downloadAndLoad(version: modelVersion, progressHandler: progress)
        loadedModels = models
        try await manager.loadModels(models)
        // The preview track is a nicety: if it can't load, dictation still works,
        // it just goes back to showing nothing until the accurate track catches up.
        do {
            try await previewManager.loadModels(models)
        } catch {
            Log.transcription.error(
                "Preview track unavailable; the notch will lag the accurate track: \(error.localizedDescription, privacy: .public)")
        }
    }

    func start(
        updateHandler: @escaping @Sendable (StreamingTranscriptUpdate) -> Void
    ) async throws {
        updatesTask?.cancel()
        previewUpdatesTask?.cancel()
        started = true

        let updates = await manager.transcriptionUpdates
        updatesTask = Task {
            for await update in updates {
                let confirmed = await self.manager.confirmedTranscript
                let volatile = await self.manager.volatileTranscript
                let snapshot = StreamingTranscriptUpdate(
                    partialText: volatile,
                    confirmedText: confirmed,
                    latestText: update.text,
                    isConfirmed: update.isConfirmed
                )
                updateHandler(snapshot)
            }
        }

        // The preview track reports the same shape, flagged so the view model can
        // put it on the notch without letting it near the real transcript. Its
        // confirmed+volatile pair is *its own* running text, not the other track's.
        let previewUpdates = await previewManager.transcriptionUpdates
        previewUpdatesTask = Task {
            for await update in previewUpdates {
                let confirmed = await self.previewManager.confirmedTranscript
                let volatile = await self.previewManager.volatileTranscript
                updateHandler(StreamingTranscriptUpdate(
                    partialText: volatile,
                    confirmedText: confirmed,
                    latestText: update.text,
                    isConfirmed: update.isConfirmed,
                    isPreview: true
                ))
            }
        }

        // `startStreaming` doesn't touch the microphone — it only labels the source
        // and starts consuming whatever `streamAudio` feeds in. So both tracks can
        // run off the one capture session below.
        try await manager.startStreaming(source: .microphone)
        try? await previewManager.startStreaming(source: .microphone)
    }

    func append(_ buffer: AVAudioPCMBuffer) async throws {
        guard started else { throw TranscriberError.notStarted }
        await manager.streamAudio(buffer)
        await previewManager.streamAudio(buffer)
    }

    func stop() async throws -> String {
        guard started else { throw TranscriberError.notStarted }
        started = false

        // Give the final window ~1s of trailing silence so its right-context is
        // satisfied and the last word(s) actually flush (live push-to-talk cuts
        // off the instant the user releases). Streamed before finish() so the
        // recognizer drains it; silence transcribes to nothing.
        if let pad = Self.silenceBuffer(seconds: 1.0) {
            await manager.streamAudio(pad)
        }

        // Capture the engine's own two tracks *before* finish() — which can
        // throw after a window-processing failure — and before we recreate the
        // manager. This is the same confirmed+volatile reconstruction finish()
        // performs, so a failed final decode recovers the whole streamed
        // transcript instead of collapsing to the last sliding-window tail.
        let confirmedTrack = await manager.confirmedTranscript
        let volatileTrack = await manager.volatileTranscript
        let salvage = TranscriptMerger.bestEffort(confirmed: confirmedTrack, volatile: volatileTrack)

        let final: String
        do {
            let finished = try await manager.finish()
            final = finished.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? salvage : finished
        } catch {
            Log.transcription.error(
                "finish() failed; recovering \(salvage.count, privacy: .public) chars of streamed transcript: \(error.localizedDescription, privacy: .public)")
            final = salvage
        }

        updatesTask?.cancel()
        updatesTask = nil
        // SlidingWindowAsrManager finishes its internal AsyncStream on `finish()`,
        // so we recreate the manager between sessions instead of reusing a closed stream.
        // A failure here must not lose the transcript we already have.
        do {
            manager = try await freshManager(config: config)
        } catch {
            Log.transcription.error(
                "Post-stop model reload failed: \(error.localizedDescription, privacy: .public)")
        }
        await resetPreviewTrack()
        return final
    }

    func cancel() async {
        started = false
        updatesTask?.cancel()
        updatesTask = nil
        await manager.cancel()
        manager = (try? await freshManager(config: config)) ?? SlidingWindowAsrManager(config: config)
        await resetPreviewTrack()
    }

    /// Tear the preview track down and stand a fresh one up for the next session,
    /// mirroring what `stop()`/`cancel()` do for the accurate track. The old
    /// manager is always cancelled first — it owns a recognizer task pumping its
    /// input stream, which would otherwise outlive every dictation. Best-effort
    /// throughout: a dead preview track only costs the notch its head start.
    private func resetPreviewTrack() async {
        previewUpdatesTask?.cancel()
        previewUpdatesTask = nil
        await previewManager.cancel()
        previewManager = (try? await freshManager(config: previewConfig))
            ?? SlidingWindowAsrManager(config: previewConfig)
    }

    /// A new manager carrying the already-loaded models — no re-download, no disk
    /// read.
    private func freshManager(config: SlidingWindowAsrConfig) async throws -> SlidingWindowAsrManager {
        let replacement = SlidingWindowAsrManager(config: config)
        if let loadedModels {
            try await replacement.loadModels(loadedModels)
        }
        return replacement
    }
}
