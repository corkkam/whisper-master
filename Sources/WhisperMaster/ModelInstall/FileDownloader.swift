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
    private let requestTimeout: TimeInterval
    private let resourceTimeout: TimeInterval
    private let onProgress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<Void, Error>?

    /// - Parameters:
    ///   - requestTimeout: fail if no data arrives for this long (stall
    ///     detection — resets whenever bytes flow).
    ///   - resourceTimeout: hard ceiling for the whole transfer.
    init(
        destination: URL,
        requestTimeout: TimeInterval = 120,
        resourceTimeout: TimeInterval = 3_600,
        onProgress: @escaping @Sendable (Double) -> Void
    ) {
        self.destination = destination
        self.requestTimeout = requestTimeout
        self.resourceTimeout = resourceTimeout
        self.onProgress = onProgress
    }

    /// Download `url` to the destination, resolving once the file is in place.
    func download(from url: URL) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            // Bound the timeouts: the default resource timeout is 7 days, so a
            // stalled transfer would appear frozen forever instead of failing
            // and letting the caller retry / fall back.
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = requestTimeout
            configuration.timeoutIntervalForResource = resourceTimeout
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
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
