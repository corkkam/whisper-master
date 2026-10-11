import CryptoKit
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
    ///
    /// Not `private`, so `DistributionHostTests` can hold this and the Sparkle feed
    /// host together — they must name the same bucket, and when they didn't, model
    /// archives 404'd with nothing anywhere reporting it.
    static let mirrorBaseURL = URL(
        string: "https://dl.corkkam.com/models"
    )!

    /// A step of the install, surfaced to the UI.
    struct Progress: Sendable {
        let fractionCompleted: Double
        let detail: String
    }

    enum InstallError: Error {
        case incompleteAfterUnpack
        /// The downloaded archive's SHA-256 did not match the pin baked into the
        /// signed bundle (`ModelChecksums`). Treated as a failed download.
        case checksumMismatch
        /// No hash is pinned for this archive, so its bytes cannot be trusted.
        /// Refused rather than installed: an archive nobody pinned is a publish
        /// step that was skipped, and installing it anyway is how an unsigned
        /// bucket write becomes CoreML/MLX code on a user's Mac.
        case unpinnedArchive
    }

    /// The pure verification decision for a downloaded archive, factored out so it
    /// is testable without the download machinery.
    enum ChecksumVerdict: Equatable {
        /// A pin exists and the file's hash matches it.
        case verified
        /// No hash is pinned for this archive. Never unpack: the caller fails the
        /// attempt exactly as for a mismatch.
        case unpinned
        /// A pin exists and disagrees — a tampered or corrupt mirror. Never unpack.
        case mismatch
    }

    /// Compare a computed lowercase-hex digest to the pin baked into the signed
    /// bundle. Case-insensitive; a missing pin is `.unpinned`, which fails closed.
    static func verifyChecksum(archiveName: String, actualHex: String) -> ChecksumVerdict {
        guard let expected = ModelChecksums.sha256[archiveName] else { return .unpinned }
        return actualHex.caseInsensitiveCompare(expected) == .orderedSame ? .verified : .mismatch
    }

    /// Streaming SHA-256 of a file, read in bounded 1 MiB chunks so a multi-GB
    /// archive is never loaded into memory whole. Lowercase hex.
    static func sha256(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: sha256ChunkByteCount), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static let sha256ChunkByteCount = 1 << 20  // 1 MiB

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

    /// One download+unpack attempt. Downloads to a **stable** path under
    /// `<destinationRoot>/.downloads/` (resume needs a fixed destination, unlike
    /// the old random temp zip) via the background downloader, so an interrupted
    /// transfer resumes instead of restarting. `isInstalled()` afterwards guards
    /// against a partial unpack.
    private static func downloadAndUnpack(
        archiveURL: URL,
        archiveName: String,
        destinationRoot: URL,
        label: String,
        isInstalled: @Sendable () -> Bool,
        onProgress: @escaping @Sendable (Progress) -> Void
    ) async throws {
        let archiveZip = destinationRoot
            .appendingPathComponent(".downloads", isDirectory: true)
            .appendingPathComponent("\(archiveName).zip")

        onProgress(Progress(fractionCompleted: 0, detail: "Downloading \(label)…"))
        try await BackgroundFileDownloader.shared.download(from: archiveURL, to: archiveZip) { fraction in
            // Detail is just the message; every view renders the percentage
            // itself from `fractionCompleted`, so baking it in here duplicated
            // it ("Downloading voice engine… 40% 40%").
            onProgress(Progress(fractionCompleted: fraction, detail: "Downloading \(label)…"))
        }

        // Verify the bytes against the hash pinned inside the signed bundle before
        // unpacking anything: the R2 archives are unsigned (unlike the Sparkle
        // appcast), and CoreML/MLX weights are code-adjacent, so a swapped archive
        // must never reach `Archive.unzip`.
        onProgress(Progress(fractionCompleted: 1, detail: "Verifying \(label)…"))
        let actualHex = try sha256(ofFileAt: archiveZip)
        switch verifyChecksum(archiveName: archiveName, actualHex: actualHex) {
        case .verified:
            break
        case .unpinned:
            try? FileManager.default.removeItem(at: archiveZip)
            BackgroundFileDownloader.shared.forget(url: archiveURL)
            Log.modelPrep.error(
                "No pinned SHA-256 for archive \(archiveName, privacy: .public) — refusing to unpack \(label, privacy: .public). Pin it in ModelChecksums.")
            throw InstallError.unpinnedArchive
        case .mismatch:
            // Tampered or corrupt mirror: drop the bad bytes and the resume token so
            // a retry re-downloads fresh instead of resuming the same file, then fail
            // this attempt so the caller retries and ultimately falls back to HF.
            try? FileManager.default.removeItem(at: archiveZip)
            BackgroundFileDownloader.shared.forget(url: archiveURL)
            Log.modelPrep.error(
                "SHA-256 mismatch for \(label, privacy: .public) archive \(archiveName, privacy: .public): expected \(ModelChecksums.sha256[archiveName] ?? "?", privacy: .public), got \(actualHex, privacy: .public) — refusing to unpack")
            throw InstallError.checksumMismatch
        }

        onProgress(Progress(fractionCompleted: 1, detail: "Unpacking \(label)…"))
        try await Archive.unzip(archiveZip, into: destinationRoot)

        guard isInstalled() else { throw InstallError.incompleteAfterUnpack }

        // Installed and validated — drop the zip and the resume bookkeeping.
        try? FileManager.default.removeItem(at: archiveZip)
        BackgroundFileDownloader.shared.forget(url: archiveURL)
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
