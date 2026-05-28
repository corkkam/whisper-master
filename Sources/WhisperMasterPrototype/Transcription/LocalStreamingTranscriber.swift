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
    case eouStreaming
    case slidingWindow

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .eouStreaming:
            return "Light"
        case .slidingWindow:
            return "Heavy"
        }
    }

    var subtitle: String {
        switch self {
        case .eouStreaming:
            return "Fast local dictation"
        case .slidingWindow:
            return "Best accuracy local dictation"
        }
    }

    var estimatedDownloadSize: String {
        switch self {
        case .eouStreaming:
            return "~250 MB"
        case .slidingWindow:
            return "~643 MB"
        }
    }

    var userFacingName: String {
        "\(displayName) (\(estimatedDownloadSize))"
    }

    var cacheDirectoryName: String {
        switch self {
        case .eouStreaming:
            return "parakeet-eou-streaming"
        case .slidingWindow:
            return "parakeet-tdt-0.6b-v3"
        }
    }

    var localModelsRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    var localModelURL: URL {
        localModelsRoot.appendingPathComponent(cacheDirectoryName, isDirectory: true)
    }

    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: localModelURL.path)
    }
}
