import Foundation

/// Installs CoreML model archives from the app's R2 mirror: downloads a single
/// `<archiveName>.zip` and unpacks it into a destination directory. This gives
/// an accurate download percentage (R2 returns a real `Content-Length`) and
/// faster, free-egress transfers than FluidAudio's HuggingFace default.
///
/// On any failure (offline, archive missing) `installIfNeeded` throws and the
/// caller falls back to FluidAudio's own HuggingFace download.
enum ModelInstaller {
    /// Public R2 base holding `<archiveName>.zip` for each model.
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

    /// Download `<archiveName>.zip` from the mirror and unpack it into
    /// `destinationRoot`. Skips the work when `isInstalled()` is already true.
    /// - Parameters:
    ///   - label: human name used in progress text (e.g. "voice engine").
    /// - Returns: `true` if it installed from the mirror, `false` if already present.
    @discardableResult
    static func installIfNeeded(
        archiveName: String,
        destinationRoot: URL,
        label: String,
        isInstalled: @Sendable () -> Bool,
        onProgress: @escaping @Sendable (Progress) -> Void = { _ in }
    ) async throws -> Bool {
        guard !isInstalled() else { return false }

        let archiveURL = mirrorBaseURL.appendingPathComponent("\(archiveName).zip")
        let tempZip = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(archiveName)-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: tempZip) }

        onProgress(Progress(fractionCompleted: 0, detail: "Downloading \(label)…"))
        let downloader = FileDownloader(destination: tempZip) { fraction in
            onProgress(Progress(
                fractionCompleted: fraction,
                detail: "Downloading \(label)… \(Int(fraction * 100))%"
            ))
        }
        try await downloader.download(from: archiveURL)

        onProgress(Progress(fractionCompleted: 1, detail: "Unpacking \(label)…"))
        try await Archive.unzip(tempZip, into: destinationRoot)

        guard isInstalled() else { throw InstallError.incompleteAfterUnpack }
        return true
    }
}

extension ModelInstaller {
    /// Convenience for the selected transcription engine's models.
    @discardableResult
    static func installIfNeeded(
        _ engine: TranscriberEngine,
        onProgress: @escaping @Sendable (Progress) -> Void
    ) async throws -> Bool {
        try await installIfNeeded(
            archiveName: engine.cacheDirectoryName,
            destinationRoot: engine.localModelsRoot,
            label: "voice engine",
            isInstalled: { engine.isInstalled },
            onProgress: onProgress
        )
    }
}
