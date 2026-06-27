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
    private var isLoadingVocabulary = false

    init(config: SlidingWindowAsrConfig = .streaming) {
        self.config = config
        self.manager = SlidingWindowAsrManager(config: config)
    }

    /// Store the terms to bias decoding toward (proper nouns, jargon like
    /// "RAG"). Cheap — no I/O; the model loading happens in
    /// `loadVocabularyResources()`.
    func setVocabulary(_ terms: [String]) {
        vocabularyTerms = terms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Ensure the CTC keyword model is loaded and the biasing is applied. Meant
    /// to run in the background after the main models are ready: transcription
    /// works (unbiased) until this finishes and it never blocks recording.
    /// Best-effort — failures leave transcription working without biasing.
    func loadVocabularyResources() async {
        guard !vocabularyTerms.isEmpty else { return }
        if ctcModels == nil {
            guard !isLoadingVocabulary else { return } // a load is already in flight
            isLoadingVocabulary = true
            defer { isLoadingVocabulary = false }
            // Mirror-first: pre-place the CTC model so `downloadAndLoad` reads
            // from disk instead of HuggingFace; it falls back to HF on a miss.
            let cacheDirectory = CtcModels.defaultCacheDirectory(for: .ctc110m)
            try? await ModelInstaller.installIfNeeded(
                archiveName: cacheDirectory.lastPathComponent,
                destinationRoot: cacheDirectory.deletingLastPathComponent(),
                label: "vocabulary model",
                isInstalled: { CtcModels.modelsExist(at: cacheDirectory) }
            )
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
        await applyVocabularyBoosting()
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
        await applyVocabularyBoosting()
    }
}
