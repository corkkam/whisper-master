import Foundation

/// Saved bench runs. A run outlives the app that produced it, which is the whole
/// point of the history rail: "did this get worse" is a question about last week,
/// and a rebuild wipes anything held in memory.
///
/// One file per run under Application Support. Not one big index file: a run is
/// appended once and then only read, and a single file means a crashed write
/// takes every past run with it.
@MainActor
final class LabRunStore {
    private let directory: URL
    private let fileManager: FileManager
    /// How many runs to keep. Old runs are pruned oldest-first when a new one
    /// lands, so the folder cannot grow without bound on a machine that benches
    /// every day.
    private let keep: Int

    private(set) var runs: [LabRun] = []

    init(directory: URL = LabPaths.runsDirectory, fileManager: FileManager = .default,
         keep: Int = 40, load: Bool = true) {
        self.directory = directory
        self.fileManager = fileManager
        self.keep = keep
        if load { reload() }
    }

    /// Newest first, which is the order the rail shows.
    func reload() {
        let files = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        runs = files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> LabRun? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                // A run written by an older build simply does not load. It is a
                // dev-only record, and dropping one is better than blocking the
                // page on a migration nobody will write.
                return try? decoder.decode(LabRun.self, from: data)
            }
            .sorted { $0.id > $1.id }
    }

    var nextRunID: Int { (runs.map(\.id).max() ?? 0) + 1 }

    func run(id: Int) -> LabRun? { runs.first { $0.id == id } }

    /// Insert or replace. The runner saves the same run repeatedly as it
    /// progresses, so a run that is killed mid-way still leaves what it had.
    func save(_ run: LabRun) {
        if let index = runs.firstIndex(where: { $0.id == run.id }) {
            runs[index] = run
        } else {
            runs.insert(run, at: 0)
            runs.sort { $0.id > $1.id }
        }
        write(run)
        prune()
    }

    func delete(id: Int) {
        runs.removeAll { $0.id == id }
        try? fileManager.removeItem(at: fileURL(id))
    }

    // MARK: - Disk

    private func fileURL(_ id: Int) -> URL {
        directory.appendingPathComponent("run-\(id).json")
    }

    private func write(_ run: LabRun) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(run) else { return }
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL(run.id), options: .atomic)
    }

    #if DEBUG
    /// Put runs in front of the page without touching the disk — the headless
    /// snapshot renderer's only way to photograph a populated lab. Never writes,
    /// so a design pass cannot leave fake runs in a real install's history.
    func seedForSnapshot(_ seeded: [LabRun]) { runs = seeded }
    #endif

    private func prune() {
        guard runs.count > keep else { return }
        for run in runs.dropFirst(keep) {
            try? fileManager.removeItem(at: fileURL(run.id))
        }
        runs = Array(runs.prefix(keep))
    }
}

/// A lab run in the shape the offline pipeline already reads.
///
/// `eval-score` and the run-history dashboard were written against
/// `EvalRunner`'s `results.json`, so the lab emits exactly that rather than a
/// second format: a run benched in the app can be scored, pushed and diffed by
/// the tools that exist. Extra per-model figures ride along under keys the CLI
/// ignores.
enum LabRunExport {
    static func rows(for result: LabModelResult) -> [[String: Any]] {
        result.cases.map { item in
            var latency: [String: Int] = ["deterministic": 0, "llm": item.latencyMs, "total": item.latencyMs]
            if let asrMs = item.asrMs {
                latency["asr"] = asrMs
                latency["total"] = asrMs + item.latencyMs
            }
            var row: [String: Any] = [
                "id": item.id,
                "target": item.target,
                "input_kind": item.inputKind,
                "deterministic": item.deterministic,
                "llm_output": item.finalOutput,
                "guard": ["accepted": item.guardAccepted],
                "wer": item.wer ?? NSNull(),
                "latency_ms": latency,
                // Lab-only, ignored by eval-score: what the row cost to produce.
                "model": result.modelID,
                "tokens_per_second": item.tokensPerSecond,
            ]
            if item.inputKind == "audio" {
                row["asr_text"] = item.asrText ?? ""
                row["asr_reference"] = item.asrReference ?? ""
            }
            return row
        }
    }

    static func json(for result: LabModelResult) -> Data? {
        try? JSONSerialization.data(withJSONObject: rows(for: result), options: [.prettyPrinted])
    }

    /// Write one file per model beside each other, named for the model, so a run
    /// of four models exports four files the CLI can score one at a time.
    @discardableResult
    static func write(run: LabRun, to directory: URL) -> [URL] {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var written: [URL] = []
        for result in run.models {
            guard let data = json(for: result) else { continue }
            let url = directory.appendingPathComponent("run-\(run.id)-\(result.modelID).json")
            if (try? data.write(to: url, options: .atomic)) != nil { written.append(url) }
        }
        return written
    }
}
