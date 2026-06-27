import Foundation

/// Downloads a remote file to a local destination, reporting fractional
/// progress. Backed by a `URLSession` download task so large files stream to
/// disk rather than buffering in memory, and a correct `Content-Length`
/// (which the R2 mirror provides) yields an accurate percentage.
final class FileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    enum DownloadError: Error {
        case httpStatus(Int)
    }

    private let destination: URL
    private let onProgress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<Void, Error>?

    init(destination: URL, onProgress: @escaping @Sendable (Double) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
    }

    /// Download `url` to the destination, resolving once the file is in place.
    func download(from url: URL) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            session.downloadTask(with: url).resume()
        }
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        defer { session.finishTasksAndInvalidate() }

        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            finish(.failure(DownloadError.httpStatus(http.statusCode)))
            return
        }

        let fileManager = FileManager.default
        do {
            try? fileManager.removeItem(at: destination)
            try fileManager.moveItem(at: location, to: destination)
            finish(.success(()))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Success is resolved in didFinishDownloadingTo; only surface errors here.
        guard let error else { return }
        session.finishTasksAndInvalidate()
        finish(.failure(error))
    }

    // MARK: - Helpers

    private func finish(_ result: Result<Void, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}
