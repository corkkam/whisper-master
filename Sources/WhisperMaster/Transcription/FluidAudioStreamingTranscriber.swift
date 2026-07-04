@preconcurrency import AVFoundation
import FluidAudio
import Foundation

actor FluidAudioStreamingTranscriber {
    enum TranscriberError: Error {
        case notStarted
    }

    private let config: SlidingWindowAsrConfig
    private var manager: SlidingWindowAsrManager
    private var updatesTask: Task<Void, Never>?
    private var started = false
    private var modelsLoaded = false

    init(config: SlidingWindowAsrConfig = .streaming) {
        self.config = config
        self.manager = SlidingWindowAsrManager(config: config)
    }

    // NOTE: FluidAudio's CTC vocabulary boosting is deliberately NOT used.
    // In streaming mode its rescorer corrupts the transcript — it empties a
    // vocabulary-dense utterance entirely and truncates others by half (proven
    // by the AudioReplayTests A/B: vocab ON → P5 0 words, P2 halved). Custom
    // vocabulary is instead applied as a safe post-processing text replacement
    // (`VocabularyPostProcessor`) on the finished transcript.
}

extension FluidAudioStreamingTranscriber: LocalStreamingTranscriber {
    func prepareModels(
        progress: @escaping @Sendable (DownloadUtils.DownloadProgress) -> Void
    ) async throws {
        if modelsLoaded { return }
        try await manager.loadModels(progressHandler: progress)
        modelsLoaded = true
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
        if modelsLoaded {
            // A reload failure must not lose the transcript we already have; the
            // next recording re-prepares. Log loudly rather than throwing.
            do {
                try await replacement.loadModels()
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
        if modelsLoaded {
            try? await replacement.loadModels()
        }
        manager = replacement
    }
}
