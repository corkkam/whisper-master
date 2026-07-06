import Foundation

/// Downloads a remote file to a stable local destination using a **background**
/// URLSession, so large model archives survive an app quit and resume after a
/// dropped connection instead of restarting from zero.
///
/// The transfer is owned by the system `nsurlsessiond` daemon, not our process,
/// keyed by a fixed session identifier. On relaunch we recreate the session with
/// that same identifier and reattach to any transfer still in flight; if one
/// finished while we were away, the delegate still fires and we move the file
/// into place using the URL→destination map in `DownloadResumeStore`. When a
/// transfer fails with resume data, we persist it so the next attempt continues.
///
/// Singleton — exactly one session per identifier may exist in a process, so the
/// session is created once, eagerly, and reused.
final class BackgroundFileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = BackgroundFileDownloader()

    enum DownloadError: Error { case httpStatus(Int) }

    private let store: DownloadResumeStore
    private let lock = NSLock()
    private var session: URLSession!

    /// The caller currently awaiting each URL (progress sink + continuation). A
    /// completion with no waiter — a transfer that finished while the app was
    /// quit — still moves the file via the store; the waiter is only the awaiter.
    private struct Waiter {
        let onProgress: @Sendable (Double) -> Void
        let continuation: CheckedContinuation<Void, Error>
    }
    private var waiters: [String: Waiter] = [:]

    init(store: DownloadResumeStore? = nil) {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
        self.store = store ?? DownloadResumeStore(root: root)
        super.init()

        let config = URLSessionConfiguration.background(
            withIdentifier: "app.whispermaster.mac.model-downloads")
        config.timeoutIntervalForRequest = 120          // stall detection (resets as bytes flow)
        config.timeoutIntervalForResource = 24 * 3_600  // a paused transfer isn't killed for a day
        config.isDiscretionary = false                  // the user is waiting on the model — start now
        config.sessionSendsLaunchEvents = false
        // Creating the session delivers delegate callbacks for any transfers the
        // daemon finished/continued while we were away, moving finished files
        // into place via the store before any caller asks for them.
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    /// Download `url` to `destination` (a *stable* path — required for resume),
    /// resolving once the file is in place. Reattaches to an in-flight transfer,
    /// resumes from saved resume data, or starts fresh, in that order.
    func download(
        from url: URL,
        to destination: URL,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        store.note(url: url, destination: destination)

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // Register the waiter *before* checking/starting, so a completion
                // that races in right now resolves it rather than being dropped.
                lock.lock()
                waiters[url.absoluteString] = Waiter(onProgress: onProgress, continuation: continuation)
                lock.unlock()

                // Already finished (e.g. completed while the app was quit and the
                // delegate has since moved it into place)?
                if FileManager.default.fileExists(atPath: destination.path) {
                    resolve(url: url, with: .success(()))
                    return
                }
                Task { await self.startOrReattach(url: url) }
            }
        } onCancel: {
            // Leave the transfer running in the daemon; just detach the waiter.
            lock.lock(); waiters[url.absoluteString] = nil; lock.unlock()
        }
    }

    /// Clear the download record after a successful, unpacked install.
    func forget(url: URL) { store.forget(url: url) }

    // MARK: - Task lifecycle

    private func startOrReattach(url: URL) async {
        // A transfer the daemon kept running across launches — let its delegate
        // callbacks drive our waiter rather than starting a duplicate.
        let tasks = await session.allTasks
        let alreadyRunning = tasks.contains {
            ($0 as? URLSessionDownloadTask)?.originalRequest?.url == url && $0.state == .running
        }
        if alreadyRunning { return }

        let task: URLSessionDownloadTask
        if let resumeData = store.resumeData(for: url) {
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            task = session.downloadTask(with: url)
        }
        task.resume()
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0, let url = requestURL(downloadTask) else { return }
        waiter(for: url)?.onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let url = requestURL(downloadTask) else { return }

        // A non-2xx "download" is the server's error body, not our file.
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            resolve(url: url, with: .failure(DownloadError.httpStatus(http.statusCode)))
            return
        }
        guard let destination = store.destination(for: url) else { return }

        // The temp `location` is only valid inside this callback — move now.
        let fm = FileManager.default
        do {
            try? fm.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: destination)
            try fm.moveItem(at: location, to: destination)
            store.clearResumeData(for: url)
            resolve(url: url, with: .success(()))
        } catch {
            resolve(url: url, with: .failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Success is resolved in didFinishDownloadingTo; only surface errors here.
        guard let error, let url = requestURL(task) else { return }
        if let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            store.saveResumeData(resumeData, for: url)
        }
        resolve(url: url, with: .failure(error))
    }

    // MARK: - Helpers

    private func requestURL(_ task: URLSessionTask) -> URL? {
        task.originalRequest?.url ?? task.currentRequest?.url
    }

    private func waiter(for url: URL) -> Waiter? {
        lock.lock(); defer { lock.unlock() }
        return waiters[url.absoluteString]
    }

    private func resolve(url: URL, with result: Result<Void, Error>) {
        lock.lock()
        let waiter = waiters[url.absoluteString]
        waiters[url.absoluteString] = nil
        lock.unlock()
        waiter?.continuation.resume(with: result)
    }
}
