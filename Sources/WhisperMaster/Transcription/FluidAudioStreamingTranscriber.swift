@preconcurrency import AVFoundation
import FluidAudio
import Foundation

actor FluidAudioStreamingTranscriber {
    enum TranscriberError: Error {
        case notStarted
    }

    private let config: SlidingWindowAsrConfig
    private let modelVersion: AsrModelVersion
    private var manager: SlidingWindowAsrManager
    private var updatesTask: Task<Void, Never>?
    private var started = false
    /// Loaded once, then reused across the manager recreations in stop()/cancel()
    /// so a session teardown never re-downloads or re-reads the model from disk.
    private var loadedModels: AsrModels?

    /// - Parameter modelVersion: `.v3` is the multilingual Parakeet (default,
    ///   25 European languages); `.v2` is the English-only model — same size,
    ///   slightly better English WER, and without v3's documented long-form
    ///   English chunk-boundary glitches (FluidAudio issue #594).
    init(config: SlidingWindowAsrConfig = .streaming, modelVersion: AsrModelVersion = .v2) {
        self.modelVersion = modelVersion
        // v2 uses blankId 1024, v3 uses 8192 — pass it explicitly rather than
        // relying on the decoder's internal blank-token auto-adaptation.
        self.config = config.applying(tdtConfig: TdtConfig(blankId: modelVersion.blankId))
        self.manager = SlidingWindowAsrManager(config: self.config)
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
    }

    func start(
        updateHandler: @escaping @Sendable (StreamingTranscriptUpdate) -> Void
    ) async throws {
        updatesTask?.cancel()
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

        try await manager.startStreaming(source: .microphone)
    }

    func append(_ buffer: AVAudioPCMBuffer) async throws {
        guard started else { throw TranscriberError.notStarted }
        await manager.streamAudio(buffer)
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
        let replacement = SlidingWindowAsrManager(config: config)
        if let loadedModels {
            // Reuse the already-loaded models (no re-download / disk read). A
            // failure here must not lose the transcript we already have.
            do {
                try await replacement.loadModels(loadedModels)
            } catch {
                Log.transcription.error(
                    "Post-stop model reload failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        manager = replacement
        return final
    }

    func cancel() async {
        started = false
        updatesTask?.cancel()
        updatesTask = nil
        await manager.cancel()
        let replacement = SlidingWindowAsrManager(config: config)
        if let loadedModels {
            try? await replacement.loadModels(loadedModels)
        }
        manager = replacement
    }
}
