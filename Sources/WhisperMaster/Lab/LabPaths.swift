import Foundation

/// Where the lab finds things on this Mac: the repo checkout that holds the case
/// files and the audio fixtures, and the model directories on disk.
///
/// **The repo path is resolved, never bundled.** The suites are 130 lines of
/// JSONL and seven recordings that already live in the repo; copying them into
/// the app bundle would mean two versions of every case and a build step to keep
/// them equal. This is a dev-build surface running on the machine that built it,
/// so the checkout is simply found — and when it cannot be, the page says so and
/// takes a folder instead of failing quietly.
enum LabPaths {
    /// Set by the user in the lab when the compiled-in path is wrong (a moved
    /// checkout, a build copied to another Mac).
    static let repoOverrideKey = "WhisperMaster.lab.repoPath.v1"

    /// Candidates in priority order: an explicit env var, the folder the user
    /// picked, then the checkout this binary was compiled from.
    static func repoRootCandidates(
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        compiledFrom: String = #filePath
    ) -> [URL] {
        var out: [URL] = []
        if let env = environment["WM_LAB_REPO"], !env.isEmpty {
            out.append(URL(fileURLWithPath: env, isDirectory: true))
        }
        if let picked = defaults.string(forKey: repoOverrideKey), !picked.isEmpty {
            out.append(URL(fileURLWithPath: picked, isDirectory: true))
        }
        if let compiled = repoRoot(containing: compiledFrom) {
            out.append(compiled)
        }
        return out
    }

    /// Walk up from a source file inside `Sources/WhisperMaster/…` to the repo
    /// root. Pure, so the walk is tested without a filesystem.
    static func repoRoot(containing filePath: String) -> URL? {
        let marker = "/Sources/WhisperMaster/"
        guard let range = filePath.range(of: marker) else { return nil }
        return URL(fileURLWithPath: String(filePath[filePath.startIndex ..< range.lowerBound]),
                   isDirectory: true)
    }

    /// A repo root only counts when the cases file is actually in it — a stale
    /// override pointing at a deleted checkout must not read as configured.
    static func isUsableRepoRoot(_ url: URL, fileManager: FileManager = .default) -> Bool {
        fileManager.fileExists(atPath: url.appendingPathComponent("eval/text-cleanup/cases.jsonl").path)
    }

    /// The first candidate that holds the cases file, or nil.
    static func resolvedRepoRoot(
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL? {
        repoRootCandidates(defaults: defaults, environment: environment)
            .first { isUsableRepoRoot($0, fileManager: fileManager) }
    }

    // MARK: - Models on disk

    /// Where MLX's own loader puts a model fetched by Hugging Face id.
    ///
    /// Mirrors `MLXLMCommon.defaultHubApi` — `HubApi(downloadBase: caches)` and
    /// `localRepoLocation` = `<base>/models/<repo id>`. Recomputed here rather
    /// than imported so the lab does not depend on a transitive module; if the
    /// loader ever moves its cache, this is the one place that follows it.
    static func huggingFaceCacheDirectory(for repoID: String) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches.appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(repoID, isDirectory: true)
    }

    /// Where a mirrored model unpacks: beside the shipped ones.
    static func mirrorDirectory(archiveName: String) -> URL {
        CleanupModel.modelsRoot.appendingPathComponent(archiveName, isDirectory: true)
    }

    /// A model is installed when MLX has everything it needs to load it without
    /// the network: the config, a tokenizer, and at least one weights file.
    /// A folder left behind by an interrupted download fails this, which is the
    /// point — a partial install must re-fetch rather than fail at load time.
    static func isInstalled(at directory: URL, fileManager: FileManager = .default) -> Bool {
        let fm = fileManager
        guard fm.fileExists(atPath: directory.appendingPathComponent("config.json").path) else { return false }
        let hasTokenizer = fm.fileExists(atPath: directory.appendingPathComponent("tokenizer.json").path)
            || fm.fileExists(atPath: directory.appendingPathComponent("tokenizer.model").path)
        guard hasTokenizer else { return false }
        let contents = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        return contents.contains { $0.hasSuffix(".safetensors") }
    }

    /// Both places a catalogue entry can be installed, mirror first.
    static func candidateDirectories(for model: LabModel) -> [URL] {
        var out: [URL] = []
        if let archive = model.archiveName { out.append(mirrorDirectory(archiveName: archive)) }
        out.append(huggingFaceCacheDirectory(for: model.huggingFaceId))
        return out
    }

    /// The directory this model would load from right now, or nil when it is not
    /// on this Mac.
    static func installedDirectory(for model: LabModel, fileManager: FileManager = .default) -> URL? {
        candidateDirectories(for: model).first { isInstalled(at: $0, fileManager: fileManager) }
    }

    /// Bytes a model occupies. Walks the directory rather than trusting the
    /// catalogue's estimate, because the estimate is what we say before a
    /// download and this is what it actually cost.
    static func directorySize(_ directory: URL, fileManager: FileManager = .default) -> Int64 {
        guard let walker = fileManager.enumerator(
            at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true, let size = values?.fileSize else { continue }
            total += Int64(size)
        }
        return total
    }

    // MARK: - Run history

    /// Saved runs. Under Application Support beside the app's other stores, not
    /// in the repo: a run is a fact about this Mac, and a dev build installed
    /// from a DMG has no checkout to write into.
    static var runsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("WhisperMaster", isDirectory: true)
            .appendingPathComponent("ModelLab", isDirectory: true)
            .appendingPathComponent("runs", isDirectory: true)
    }
}
