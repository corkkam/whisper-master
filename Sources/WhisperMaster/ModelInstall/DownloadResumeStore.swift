import Foundation

/// Small on-disk bookkeeping for resumable model downloads.
///
/// Two jobs, both needed to survive an app quit or a dropped connection:
///  - **URL → destination map.** A background transfer the system finishes while
///    the app is quit is delivered to the delegate on the *next* launch, before
///    any caller asks for it — so the delegate needs to know where the finished
///    file should go. That mapping is persisted here.
///  - **Resume data.** When a transfer is interrupted mid-flight, URLSession
///    hands back an opaque resume token; stashing it lets the next attempt
///    continue from where it stopped instead of restarting.
///
/// Everything lives under `<root>/.downloads/`. Thread-safe: it's touched from
/// both the URLSession delegate (an arbitrary queue) and the calling code.
final class DownloadResumeStore: @unchecked Sendable {
    private let directory: URL
    private let indexURL: URL
    private let lock = NSLock()

    init(root: URL) {
        directory = root.appendingPathComponent(".downloads", isDirectory: true)
        indexURL = directory.appendingPathComponent("index.json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: - URL → destination

    /// Remember that `url` is being downloaded to `destination`.
    func note(url: URL, destination: URL) {
        lock.lock(); defer { lock.unlock() }
        var index = loadIndex()
        index[url.absoluteString] = destination.path
        saveIndex(index)
    }

    /// Where a finished download of `url` should be moved, if known.
    func destination(for url: URL) -> URL? {
        lock.lock(); defer { lock.unlock() }
        guard let path = loadIndex()[url.absoluteString] else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Drop all record of `url` (mapping + any resume data) — after a successful,
    /// unpacked install there's nothing left to resume.
    func forget(url: URL) {
        lock.lock(); defer { lock.unlock() }
        var index = loadIndex()
        index[url.absoluteString] = nil
        saveIndex(index)
        try? FileManager.default.removeItem(at: resumeURL(for: url))
    }

    // MARK: - Resume data

    func resumeData(for url: URL) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return try? Data(contentsOf: resumeURL(for: url))
    }

    func saveResumeData(_ data: Data, for url: URL) {
        lock.lock(); defer { lock.unlock() }
        try? data.write(to: resumeURL(for: url), options: .atomic)
    }

    func clearResumeData(for url: URL) {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: resumeURL(for: url))
    }

    // MARK: - Internals

    private func resumeURL(for url: URL) -> URL {
        directory.appendingPathComponent("\(stableName(for: url)).resume")
    }

    /// A filesystem-safe, launch-stable name for a URL: its archive's base name
    /// plus a deterministic hash (so two archives sharing a filename can't
    /// collide). `String.hashValue` is per-process-randomized and would break
    /// resume across launches, so we hash explicitly (FNV-1a).
    private func stableName(for url: URL) -> String {
        let base = url.deletingPathExtension().lastPathComponent
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in url.absoluteString.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
        return "\(base)-\(String(hash, radix: 16))"
    }

    private func loadIndex() -> [String: String] {
        guard let data = try? Data(contentsOf: indexURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return dict
    }

    private func saveIndex(_ index: [String: String]) {
        guard let data = try? JSONEncoder().encode(index) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
}
