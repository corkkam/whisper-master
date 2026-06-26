import Foundation

/// Installs an engine's ASR models from the app's R2 mirror: downloads a
/// single per-engine archive and unpacks it into FluidAudio's models
/// directory. This gives an accurate download percentage (R2 returns a real
/// `Content-Length`) and faster, free-egress transfers than FluidAudio's
/// HuggingFace default.
///
/// On any failure (offline, archive missing) `installIfNeeded` throws and the
/// caller falls back to FluidAudio's own HuggingFace download.
enum ModelInstaller {
    /// Public R2 base holding `<cacheDirectoryName>.zip` for each engine.
    private static let mirrorBaseURL = URL(
        string: "https://pub-033f6365404f4b37ac6c630d4feb0dcd.r2.dev/models"
    )!

    /// A step of the install, surfaced to the UI.
    struct Progress: Sendable {
        let fractionCompleted: Double
        let detail: String
    }

    enum InstallError: Error {
        case incompleteAfterUnpack
    }

    /// Download + unpack the engine's models if they aren't already on disk.
    /// - Returns: `true` if it installed from the mirror, `false` if the
    ///   models were already present.
    @discardableResult
    static func installIfNeeded(
        _ engine: TranscriberEngine,
        onProgress: @escaping @Sendable (Progress) -> Void
    ) async throws -> Bool {
        guard !engine.isInstalled else { return false }

        let archiveURL = mirrorBaseURL.appendingPathComponent("\(engine.cacheDirectoryName).zip")
        let tempZip = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(engine.cacheDirectoryName)-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: tempZip) }

        onProgress(Progress(fractionCompleted: 0, detail: "Downloading voice engine…"))
        let downloader = FileDownloader(destination: tempZip) { fraction in
            onProgress(Progress(
                fractionCompleted: fraction,
                detail: "Downloading voice engine… \(Int(fraction * 100))%"
            ))
        }
        try await downloader.download(from: archiveURL)

        onProgress(Progress(fractionCompleted: 1, detail: "Unpacking voice engine…"))
        try await Archive.unzip(tempZip, into: engine.localModelsRoot)

        guard engine.isInstalled else { throw InstallError.incompleteAfterUnpack }
        return true
    }
}
