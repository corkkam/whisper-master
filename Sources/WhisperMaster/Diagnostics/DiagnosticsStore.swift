import Foundation

/// On-disk sink for session traces. Writes one JSON + one WAV per session under
/// the app-support Diagnostics folder, appends a compact NDJSON summary line for
/// fast scanning, and prunes old sessions past the retention cap. Local-only.
///
/// `persist` is `nonisolated` and meant to be called off the main actor (the
/// recorder hands it fully-formed values) so writing a few MB of WAV never hitches
/// the UI right after a paste.
struct DiagnosticsStore {
    let root: URL
    let retention: Int

    init(root: URL = DiagnosticsStore.defaultRoot, retention: Int = 100) {
        self.root = root
        self.retention = retention
    }

    static var defaultRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("WhisperMaster/Diagnostics", isDirectory: true)
    }

    private var sessionsDir: URL { root.appendingPathComponent("sessions", isDirectory: true) }
    private var indexFile: URL { root.appendingPathComponent("index.ndjson") }

    /// One-line summary appended to the NDJSON index — the fast scan surface.
    struct Summary: Codable {
        let id: String
        let startedAt: Date
        let totalMs: Int
        let audioDurationMs: Int
        let realTimeFactor: Double
        let rmsMean: Float
        let isBluetooth: Bool
        let wordCount: Int
        let pasteOutcome: String?
        let frontApp: String?
        let focusAtPaste: String?
    }

    func persist(trace: SessionTrace, wav: Data) {
        do {
            try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
            let stem = "\(Self.stamp(trace.startedAt))_\(trace.id.prefix(8))"
            let jsonURL = sessionsDir.appendingPathComponent("\(stem).json")
            let wavURL = sessionsDir.appendingPathComponent("\(stem).wav")

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(trace).write(to: jsonURL)
            try wav.write(to: wavURL)

            appendIndex(summary(for: trace))
            prune()
        } catch {
            // Diagnostics must never disrupt the app — swallow, but leave a trace
            // in the unified log so a missing file has an explanation.
            Log.transcription.error("diagnostics persist failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func summary(for trace: SessionTrace) -> Summary {
        Summary(
            id: trace.id,
            startedAt: trace.startedAt,
            totalMs: trace.timeline.last?.msSinceStart ?? 0,
            audioDurationMs: trace.asr?.audioDurationMs ?? 0,
            realTimeFactor: trace.asr?.realTimeFactor ?? 0,
            rmsMean: trace.audio?.rmsMean ?? 0,
            isBluetooth: trace.audio?.isBluetooth ?? false,
            wordCount: trace.asr?.wordCount ?? 0,
            pasteOutcome: trace.context.pasteOutcome,
            frontApp: trace.context.frontApp,
            focusAtPaste: trace.context.focusAtPaste)
    }

    private func appendIndex(_ summary: Summary) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var line = try? encoder.encode(summary) else { return }
        line.append(0x0A) // newline
        if let handle = try? FileHandle(forWritingTo: indexFile) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: indexFile)
        }
    }

    /// Keep the newest `retention` sessions; delete older JSON+WAV pairs together.
    /// The NDJSON index is a full append-log and intentionally left intact.
    private func prune() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil) else { return }
        let stems = Set(files.filter { $0.pathExtension == "json" }.map { $0.deletingPathExtension().lastPathComponent })
        let sorted = stems.sorted(by: >)   // stem starts with a sortable timestamp → newest first
        for stale in sorted.dropFirst(retention) {
            try? fm.removeItem(at: sessionsDir.appendingPathComponent("\(stale).json"))
            try? fm.removeItem(at: sessionsDir.appendingPathComponent("\(stale).wav"))
        }
    }

    /// Sortable, filename-safe timestamp: 2026-07-09T22-14-03.
    private static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        return f.string(from: date)
    }
}
