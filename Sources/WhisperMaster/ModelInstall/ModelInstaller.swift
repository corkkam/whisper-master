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
        string: "https://model.scoopscore.in/models"
    )!

    /// A step of the install, surfaced to the UI.
    struct Progress: Sendable {
        let fractionCompleted: Double
        let detail: String
    }

    enum InstallError: Error {
        case incompleteAfterUnpack
    }

    /// Backoff between mirror attempts (a transient stall usually clears quickly).
    private static let retryBackoffNanoseconds: UInt64 = 1_500_000_000

    /// Download `<archiveName>.zip` from the mirror and unpack it into
    /// `destinationRoot`. Skips the work when `isInstalled()` is already true.
    /// Retries the download+unpack up to `maxAttempts` times before throwing, so
    /// a transient stall doesn't immediately drop the caller to the slow
    /// HuggingFace fallback.
    /// - Parameters:
    ///   - label: human name used in progress text (e.g. "voice engine").
    ///   - maxAttempts: total mirror tries (≥ 1) before giving up.
    /// - Returns: `true` if it installed from the mirror, `false` if already present.
    @discardableResult
    static func installIfNeeded(
        archiveName: String,
        destinationRoot: URL,
        label: String,
        maxAttempts: Int = 2,
        isInstalled: @Sendable () -> Bool,
        onProgress: @escaping @Sendable (Progress) -> Void = { _ in }
    ) async throws -> Bool {
        guard !isInstalled() else { return false }

        let archiveURL = mirrorBaseURL.appendingPathComponent("\(archiveName).zip")

        var attempt = 1
        while true {
            do {
                try await downloadAndUnpack(
                    archiveURL: archiveURL,
                    archiveName: archiveName,
                    destinationRoot: destinationRoot,
                    label: label,
                    isInstalled: isInstalled,
                    onProgress: onProgress
                )
                Log.modelPrep.notice(
                    "Installed \(label, privacy: .public) from R2 mirror (attempt \(attempt))")
                return true
            } catch {
                Log.modelPrep.error(
                    "R2 mirror install of \(label, privacy: .public) failed (attempt \(attempt)/\(maxAttempts)): \(error.localizedDescription, privacy: .public)")
                guard attempt < maxAttempts else { throw error }
                attempt += 1
                try? await Task.sleep(nanoseconds: retryBackoffNanoseconds)
            }
        }
    }

    /// One download+unpack attempt. A fresh temp zip per call keeps retries
    /// independent; `isInstalled()` afterwards guards against a partial unpack.
    private static func downloadAndUnpack(
        archiveURL: URL,
        archiveName: String,
        destinationRoot: URL,
        label: String,
        isInstalled: @Sendable () -> Bool,
        onProgress: @escaping @Sendable (Progress) -> Void
    ) async throws {
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
