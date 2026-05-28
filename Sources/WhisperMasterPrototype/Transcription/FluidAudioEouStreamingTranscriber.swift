@preconcurrency import AVFoundation
import FluidAudio
import Foundation

actor FluidAudioEouStreamingTranscriber {
    enum TranscriberError: Error {
        case notStarted
    }

    private let manager: StreamingEouAsrManager
    private var started = false
    private var modelsLoaded = false

    init(chunkSize: StreamingChunkSize = .ms160) {
        self.manager = StreamingEouAsrManager(chunkSize: chunkSize)
    }
}

extension FluidAudioEouStreamingTranscriber: LocalStreamingTranscriber {
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
        started = true

        await manager.setPartialTranscriptCallback { partial in
            let snapshot = StreamingTranscriptUpdate(
                partialText: partial,
                confirmedText: "",
                latestText: partial,
                isConfirmed: false
            )
            updateHandler(snapshot)
        }

        await manager.setEouCallback { text in
            let snapshot = StreamingTranscriptUpdate(
                partialText: text,
                confirmedText: text,
                latestText: text,
                isConfirmed: true
            )
            updateHandler(snapshot)
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) async throws {
        guard started else { throw TranscriberError.notStarted }
        try await manager.appendAudio(buffer)
        try await manager.processBufferedAudio()
    }

    func stop() async throws -> String {
        guard started else { throw TranscriberError.notStarted }
        started = false
        await manager.injectSilence(0.12)
        try await manager.processBufferedAudio()
        let final = try await manager.finish()
        await manager.reset()
        return final
    }

    func cancel() async {
        started = false
        await manager.reset()
    }
}
