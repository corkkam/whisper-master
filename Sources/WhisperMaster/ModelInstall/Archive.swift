import Foundation

/// Zip extraction via `ditto`, which round-trips the archives produced by
/// `ditto -c -k` (how the model archives are packed). Runs the process
/// asynchronously so the caller's task isn't blocked while unpacking.
enum Archive {
    enum ArchiveError: Error {
        case extractionFailed(status: Int32)
    }

    /// Extract `zip` into `directory`, creating the directory if needed.
    static func unzip(_ zip: URL, into directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path, directory.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { process in
                if process.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: ArchiveError.extractionFailed(status: process.terminationStatus))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
