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
    private var vocabularyTerms: [String] = []
    private var ctcModels: CtcModels?

    init(config: SlidingWindowAsrConfig = .streaming) {
        self.config = config
        self.manager = SlidingWindowAsrManager(config: config)
    }

    /// Bias decoding toward custom terms (proper nouns, jargon like "RAG").
    /// Loads the CTC keyword-spotting model on first use and re-applies the
    /// boosting to the current manager; a free no-op when `terms` is empty.
    /// Best-effort — failures (offline, model missing) leave transcription
    /// working without biasing.
    func setVocabulary(_ terms: [String]) async {
        let cleaned = terms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        vocabularyTerms = cleaned
        guard !cleaned.isEmpty else { return }
        if ctcModels == nil {
            ctcModels = try? await CtcModels.downloadAndLoad()
        }
        await applyVocabularyBoosting()
    }

    private func applyVocabularyBoosting() async {
        guard !vocabularyTerms.isEmpty, let ctcModels else { return }
        let context = CustomVocabularyContext(
            terms: vocabularyTerms.map { CustomVocabularyTerm(text: $0) }
        )
        try? await manager.configureVocabularyBoosting(vocabulary: context, ctcModels: ctcModels)
    }
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
        let final = try await manager.finish()
        updatesTask?.cancel()
        updatesTask = nil
        // SlidingWindowAsrManager finishes its internal AsyncStream on `finish()`,
        // so we recreate the manager between sessions instead of reusing a closed stream.
        let replacement = SlidingWindowAsrManager(config: config)
        if modelsLoaded {
            try await replacement.loadModels()
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
