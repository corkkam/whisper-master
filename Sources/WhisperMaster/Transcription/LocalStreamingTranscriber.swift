@preconcurrency import AVFoundation
import FluidAudio
import Foundation

struct StreamingTranscriptUpdate: Sendable {
    let partialText: String
    let confirmedText: String
    let latestText: String
    let isConfirmed: Bool
}

protocol LocalStreamingTranscriber: Sendable {
    func prepareModels(
        progress: @escaping @Sendable (DownloadUtils.DownloadProgress) -> Void
    ) async throws

    func start(
        updateHandler: @escaping @Sendable (StreamingTranscriptUpdate) -> Void
    ) async throws

    func append(_ buffer: AVAudioPCMBuffer) async throws
    func stop() async throws -> String
    func cancel() async
}

enum TranscriberEngine: String, CaseIterable, Identifiable {
    case slidingWindow

    var id: String { rawValue }

    var displayName: String { "Heavy" }

    var subtitle: String { "Best accuracy local dictation" }

    var estimatedDownloadSize: String { "~643 MB" }

    var userFacingName: String {
        "\(displayName) (\(estimatedDownloadSize))"
    }

    var cacheDirectoryName: String { "parakeet-tdt-0.6b-v3" }

    var localModelsRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    var localModelURL: URL {
        localModelsRoot.appendingPathComponent(cacheDirectoryName, isDirectory: true)
    }

    /// The compiled CoreML bundles FluidAudio requires to load this engine,
    /// mirroring `ModelNames.ASR.requiredModelsV3` (int8) inside FluidAudio.
    /// Kept here so `isInstalled` can verify a *complete* install.
    var requiredModelComponents: [String] {
        ["Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc", "JointDecisionv3.mlmodelc"]
    }

    /// True only when every required CoreML bundle is present *and* compiled
    /// (each `.mlmodelc` carries its `coremldata.bin`). A missing, empty, or
    /// partially-written folder reads as not installed — so the fast R2 mirror
    /// re-fetches it instead of FluidAudio silently falling back to its slow
    /// HuggingFace download. (A bare folder-exists check let a half-deleted or
    /// interrupted install masquerade as ready.)
    var isInstalled: Bool {
        let fileManager = FileManager.default
        return requiredModelComponents.allSatisfy { component in
            let compiled = localModelURL
                .appendingPathComponent(component, isDirectory: true)
                .appendingPathComponent("coremldata.bin")
            return fileManager.fileExists(atPath: compiled.path)
        }
    }
}
