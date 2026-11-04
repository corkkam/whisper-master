import Darwin
import Foundation

/// Where the Shed engine answers, and where its master token lives.
///
/// **The one type the rest of the app reads.** The notch client and the in-app
/// session window both take the engine's address from `ShedEngineSupervisor.shared
/// .endpoint` and never guess a port. The token is read from disk on demand, never
/// cached: the engine writes `<engine folder>/.laya-token` on its first boot, and a
/// Replace or an Uninstall can change the file under a running app.
struct ShedEndpoint: Equatable, Sendable {
    let baseURL: URL
    let tokenFile: URL

    var port: Int { baseURL.port ?? 80 }

    func readToken() -> String? {
        guard let text = try? String(contentsOf: tokenFile, encoding: .utf8) else { return nil }
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    /// `/` for the session list, `/?session=<id>` for one session. Shed's
    /// `openFromUrl` reads exactly that query parameter on load.
    func pageURL(sessionID: String? = nil) -> URL {
        var parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) ?? URLComponents()
        parts.path = "/"
        if let sessionID, !sessionID.isEmpty {
            parts.queryItems = [URLQueryItem(name: "session", value: sessionID)]
        }
        return parts.url ?? baseURL
    }
}

/// `node -v` output, e.g. `v20.11.1`.
struct NodeVersion: Comparable, Equatable, Sendable {
    let major: Int
    let minor: Int
    let patch: Int

    static let minimumMajor = 20
    var isSupported: Bool { major >= Self.minimumMajor }

    static func parse(_ text: String) -> NodeVersion? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") { s.removeFirst() }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard let first = parts.first, let major = first else { return nil }
        let minor = parts.count > 1 ? parts[1] : 0
        let patch = parts.count > 2 ? parts[2] : 0
        guard let minor, let patch else { return nil }
        return NodeVersion(major: major, minor: minor, patch: patch)
    }

    static func < (a: NodeVersion, b: NodeVersion) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }
}

/// Finds a Node binary. A GUI app inherits a bare `PATH`, so the usual install
/// locations are searched as well. The file system is injected so tests never run
/// a real `node`.
struct ShedNodeLocator {
    var home: String
    var pathEnv: String
    var isExecutable: (String) -> Bool
    var listDirectory: (String) -> [String]
    var versionOf: (String) -> NodeVersion?

    enum Result: Equatable {
        case found(path: String, version: NodeVersion)
        case tooOld(path: String, version: NodeVersion)
        case missing
    }

    func candidates() -> [String] {
        var dirs = pathEnv.split(separator: ":").map(String.init).filter { !$0.isEmpty }
        dirs += ["/opt/homebrew/bin", "/usr/local/bin"]
        let nvmRoot = home + "/.nvm/versions/node"
        let nvm = listDirectory(nvmRoot)
            .sorted { (NodeVersion.parse($0) ?? .init(major: 0, minor: 0, patch: 0))
                > (NodeVersion.parse($1) ?? .init(major: 0, minor: 0, patch: 0)) }
            .map { "\(nvmRoot)/\($0)/bin" }
        dirs += nvm
        var seen = Set<String>()
        return dirs.filter { seen.insert($0).inserted }.map { $0 + "/node" }
    }

    func locate() -> Result {
        var old: Result?
        for path in candidates() where isExecutable(path) {
            guard let version = versionOf(path) else { continue }
            if version.isSupported { return .found(path: path, version: version) }
            if old == nil { old = .tooOld(path: path, version: version) }
        }
        return old ?? .missing
    }

    static func live(home: String = NSHomeDirectory()) -> ShedNodeLocator {
        ShedNodeLocator(
            home: home,
            pathEnv: ProcessInfo.processInfo.environment["PATH"] ?? "",
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0) },
            listDirectory: { (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? [] },
            versionOf: { path in
                let p = Process()
                p.executableURL = URL(fileURLWithPath: path)
                p.arguments = ["-v"]
                let out = Pipe()
                p.standardOutput = out
                p.standardError = Pipe()
                guard (try? p.run()) != nil else { return nil }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                return NodeVersion.parse(String(decoding: data, as: UTF8.self))
            })
    }
}

enum ShedPort {
    static let preferred = 4378
    static let fallback = 4380
    /// The ports an already-running Shed is looked for on: the installed copy, then
    /// the development copy. Same order the notch client uses.
    static let discovery = [4378, 4379]

    static func choose(isInUse: (Int) -> Bool) -> Int? {
        if !isInUse(preferred) { return preferred }
        if !isInUse(fallback) { return fallback }
        return nil
    }

    /// True when something already listens on loopback at `port`.
    static func isInUse(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return true }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result != 0
    }
}

/// `ENGINE_VERSION.json`, written by `Scripts/stage-shed-engine.sh`.
struct ShedEngineVersion: Codable, Equatable, Sendable {
    let commit: String
    let dirty: Bool
    let hash: String

    var label: String { "\(commit)\(dirty ? "-dirty" : "")+\(hash.prefix(8))" }
    static let fileName = "ENGINE_VERSION.json"

    static func read(from folder: URL) -> ShedEngineVersion? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(fileName)) else { return nil }
        return try? JSONDecoder().decode(ShedEngineVersion.self, from: data)
    }

    /// The copy rule: only a bundle that carries a version, and differs from what is
    /// installed, replaces the installed copy.
    static func needsCopy(bundled: ShedEngineVersion?, installed: ShedEngineVersion?) -> Bool {
        bundled != nil && bundled != installed
    }
}

enum ShedEngineFiles {
    /// Survive a copy: dependencies (reinstalled only on a version change) and the
    /// master token the engine wrote. The data folder lives elsewhere entirely.
    static let preserved: Set<String> = ["node_modules", ".laya-token", ShedEngineVersion.fileName]

    /// Mirrors `bundle` into `dest`. The version file is NOT copied here: it is
    /// written last, after `npm ci` succeeds, so an interrupted install retries.
    static func sync(from bundle: URL, to dest: URL, fm: FileManager = .default) throws {
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        for name in try fm.contentsOfDirectory(atPath: dest.path) where !preserved.contains(name) {
            try fm.removeItem(at: dest.appendingPathComponent(name))
        }
        for name in try fm.contentsOfDirectory(atPath: bundle.path) where name != ShedEngineVersion.fileName {
            try fm.copyItem(at: bundle.appendingPathComponent(name), to: dest.appendingPathComponent(name))
        }
    }

    static func commitVersion(from bundle: URL, to dest: URL, fm: FileManager = .default) throws {
        let target = dest.appendingPathComponent(ShedEngineVersion.fileName)
        try? fm.removeItem(at: target)
        try fm.copyItem(at: bundle.appendingPathComponent(ShedEngineVersion.fileName), to: target)
    }
}

struct ShedPaths {
    var home: String = NSHomeDirectory()
    var support: URL { URL(fileURLWithPath: home + "/Library/Application Support/WhisperMaster") }
    var engineDir: URL { support.appendingPathComponent("ShedEngine") }
    var dataDir: URL { support.appendingPathComponent("ShedData") }
    var logDir: URL { URL(fileURLWithPath: home + "/Library/Logs/WhisperMaster") }
    var plist: URL { URL(fileURLWithPath: home + "/Library/LaunchAgents/\(ShedLaunchAgent.label).plist") }
    /// The separate install made by Shed's own `install.sh`.
    var installedRoot: URL { URL(fileURLWithPath: home + "/.shed/app") }
    var installedDataDir: URL { installedRoot.appendingPathComponent(".jev-data") }
    var devRoot: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHED_SRC"] ?? home + "/code/shed")
    }
}

enum ShedLaunchAgent {
    static let label = "com.whispermaster.shed-engine"
    /// The launch agents of the separate install that "Replace" unregisters.
    static let installedLabels = ["dev.shed.server", "dev.shed.tunnel"]

    /// A GUI app's own PATH is nearly empty. Shed spawns `claude` and `codex`, so the
    /// agent gets the directories those usually live in.
    static func searchPath(nodeDir: String, home: String) -> String {
        [home + "/.local/bin", home + "/.claude/local", home + "/.npm-global/bin", home + "/.bun/bin",
         nodeDir, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            .joined(separator: ":")
    }

    static func plist(node: String, engineDir: URL, dataDir: URL, port: Int, logDir: URL, home: String) throws -> Data {
        let dict: [String: Any] = [
            "Label": label,
            "ProgramArguments": [node, engineDir.appendingPathComponent("server/index.js").path],
            "WorkingDirectory": engineDir.path,
            "EnvironmentVariables": [
                "HOME": home,
                "PATH": searchPath(nodeDir: (node as NSString).deletingLastPathComponent, home: home),
                "PORT": String(port),
                "LAYA_DATA_DIR": dataDir.path,
            ],
            "RunAtLoad": true,
            "KeepAlive": true,
            "StandardOutPath": logDir.appendingPathComponent("shed-engine.log").path,
            "StandardErrorPath": logDir.appendingPathComponent("shed-engine.err.log").path,
        ]
        return try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
    }

    struct Settings: Equatable {
        let port: Int
        let dataDir: String
    }

    static func settings(inPlist data: Data) -> Settings? {
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let env = root["EnvironmentVariables"] as? [String: String],
            let port = env["PORT"].flatMap(Int.init), let dir = env["LAYA_DATA_DIR"]
        else { return nil }
        return Settings(port: port, dataDir: dir)
    }
}
