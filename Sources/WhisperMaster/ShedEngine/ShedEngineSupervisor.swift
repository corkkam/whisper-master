import AppKit
import Foundation
import Observation

/// Installs, starts and watches the bundled Shed engine (`Contents/Resources/
/// ShedEngine`). Shed is the engine behind the in-app agent window; the phone app
/// reaches the same HTTP API later.
///
/// **The engine is a launch agent, not a child process.** It must keep running when
/// the app quits so agents keep working, so this type registers
/// `com.whispermaster.shed-engine` and only ever *watches* it. It never starts a
/// second engine when one already answers on 4378 or 4379, and it never touches the
/// separate install's launch agents except in `replaceInstalledWithBundled()`, which
/// only a user's click calls.
///
/// Dormant until `start()` (called after the sign-in gate), so `swift test` and the
/// snapshot renderer never run npm, launchctl or open a socket.
@MainActor
@Observable
final class ShedEngineSupervisor {
    static let shared = ShedEngineSupervisor()
    static let enabledKey = "WhisperMaster.shedEngine.enabled.v1"

    enum Source: Equatable { case none, bundled, installed, devCopy }
    enum State: Equatable {
        case off, notInstalled(String), installing(String), starting, running
        case needsNode(String), failed(String)
    }

    private(set) var state: State = .off
    private(set) var source: Source = .none
    private(set) var port: Int?
    private(set) var version: ShedEngineVersion?
    private var root: URL?

    /// Off by default: turning it on installs npm dependencies and a launch agent.
    var isEnabled: Bool = UserDefaults.standard.bool(forKey: ShedEngineSupervisor.enabledKey) {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled { launch() } else { Task { await turnOff() } }
        }
    }

    /// Non-nil only while the engine answers. This is the one thing other code reads.
    var endpoint: ShedEndpoint? {
        guard state == .running, let port, let root,
            let url = URL(string: "http://127.0.0.1:\(port)")
        else { return nil }
        return ShedEndpoint(baseURL: url, tokenFile: root.appendingPathComponent(".laya-token"))
    }

    let paths = ShedPaths()
    private var started = false
    private var work: Task<Void, Never>?
    private var timer: Timer?
    private let uid = getuid()

    var bundledEngine: URL? { Bundle.main.resourceURL?.appendingPathComponent("ShedEngine") }
    private var bundledVersion: ShedEngineVersion? { bundledEngine.flatMap(ShedEngineVersion.read(from:)) }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkHealth() }
        }
        if isEnabled { launch() }
    }

    private func launch() {
        work?.cancel()
        work = Task { await bringUp() }
    }

    private func bringUp() async {
        guard isEnabled else { return }
        if FileManager.default.fileExists(atPath: paths.plist.path) {
            await adoptOwnAgent()
        } else if let (found, src) = await discoverExternal() {
            adopt(port: found, source: src)
        } else {
            await install(port: nil, dataDir: paths.dataDir)
        }
    }

    /// Our launch agent exists: bring it up to the bundled version if needed, make
    /// sure it is loaded, and wait for it.
    private func adoptOwnAgent() async {
        guard let data = try? Data(contentsOf: paths.plist),
            let settings = ShedLaunchAgent.settings(inPlist: data)
        else { return await install(port: nil, dataDir: paths.dataDir) }
        let installed = ShedEngineVersion.read(from: paths.engineDir)
        if ShedEngineVersion.needsCopy(bundled: bundledVersion, installed: installed) {
            return await install(port: settings.port, dataDir: URL(fileURLWithPath: settings.dataDir))
        }
        adopt(port: settings.port, source: .bundled)
        state = .starting
        if !(await isLoaded()) { _ = await launchctl(["enable", target]); _ = await launchctl(["bootstrap", domain, paths.plist.path]) }
        await waitHealthy()
    }

    private func adopt(port: Int, source: Source) {
        self.port = port
        self.source = source
        switch source {
        case .installed: root = paths.installedRoot
        case .devCopy: root = paths.devRoot
        default: root = paths.engineDir
        }
        version = source == .bundled ? ShedEngineVersion.read(from: paths.engineDir) : nil
        if source != .bundled { state = .running }
    }

    private func discoverExternal() async -> (Int, Source)? {
        for p in ShedPort.discovery where await Self.probe(port: p) {
            return (p, p == 4378 ? .installed : .devCopy)
        }
        return nil
    }

    // MARK: Install

    /// Installs and starts the bundled engine. Everything that can fail before a
    /// launch agent is touched (no bundle, no Node) is checked first.
    private func install(port requested: Int?, dataDir: URL) async {
        guard let bundle = bundledEngine, bundledVersion != nil else {
            state = .notInstalled("This build does not include the engine. Build it with Scripts/bundle.sh and a Shed checkout.")
            return
        }
        guard let node = findNode() else { return }
        state = .installing("Copying the engine")
        let fm = FileManager.default
        do {
            let installed = ShedEngineVersion.read(from: paths.engineDir)
            let reinstall = ShedEngineVersion.needsCopy(bundled: bundledVersion, installed: installed)
                || !fm.fileExists(atPath: paths.engineDir.appendingPathComponent("node_modules").path)
            if reinstall {
                try ShedEngineFiles.sync(from: bundle, to: paths.engineDir)
                state = .installing("Installing dependencies. The first run also downloads a model of about 1.7 GB.")
                let nodeDir = (node as NSString).deletingLastPathComponent
                let (code, out) = await Self.run(
                    nodeDir + "/npm", ["ci", "--omit=dev", "--no-audit", "--no-fund", "--loglevel=error"],
                    env: ["PATH": ShedLaunchAgent.searchPath(nodeDir: nodeDir, home: paths.home), "HOME": paths.home],
                    cwd: paths.engineDir)
                guard code == 0 else { state = .failed("npm ci failed:\n" + Self.tail(out)); return }
                try ShedEngineFiles.commitVersion(from: bundle, to: paths.engineDir)
            }
            guard let chosen = requested ?? ShedPort.choose(isInUse: ShedPort.isInUse) else {
                state = .failed("Ports 4378 and 4380 are both in use.")
                return
            }
            try fm.createDirectory(at: dataDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.createDirectory(at: paths.logDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: paths.plist.deletingLastPathComponent(), withIntermediateDirectories: true)
            try ShedLaunchAgent.plist(
                node: node, engineDir: paths.engineDir, dataDir: dataDir, port: chosen,
                logDir: paths.logDir, home: paths.home
            ).write(to: paths.plist, options: .atomic)
            adopt(port: chosen, source: .bundled)
            state = .starting
            _ = await launchctl(["bootout", target])
            _ = await launchctl(["enable", target])
            let (status, out) = await launchctl(["bootstrap", domain, paths.plist.path])
            guard status == 0 else { state = .failed("launchctl bootstrap failed:\n" + Self.tail(out)); return }
            await waitHealthy()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Sets `.needsNode` and returns nil when no Node 20 or later exists. Node is
    /// never installed for the user.
    private func findNode() -> String? {
        switch ShedNodeLocator.live(home: paths.home).locate() {
        case .found(let path, _): return path
        case .tooOld(_, let v):
            state = .needsNode("Shed needs Node 20 or later. Found Node \(v.major). Update it with: brew upgrade node")
        case .missing:
            state = .needsNode("Shed needs Node 20 or later. Install it with: brew install node")
        }
        return nil
    }

    // MARK: Actions

    func restart() {
        guard source == .bundled else { return }
        state = .starting
        work = Task {
            _ = await launchctl(["kickstart", "-k", target])
            await waitHealthy()
        }
    }

    func openLogs() {
        try? FileManager.default.createDirectory(at: paths.logDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(paths.logDir)
    }

    /// Unregisters the launch agent and removes the engine copy. The data folder
    /// stays, so devices, password and agents survive a reinstall.
    func uninstall() {
        guard source == .bundled else { return }
        work?.cancel()
        work = Task {
            _ = await launchctl(["bootout", target])
            _ = await launchctl(["enable", target])
            try? FileManager.default.removeItem(at: paths.plist)
            try? FileManager.default.removeItem(at: paths.engineDir)
            port = nil; source = .none; root = nil; version = nil
            state = .off
            // Off, so the next launch does not quietly reinstall what was just removed.
            isEnabled = false
        }
    }

    /// Settings → "Replace with the bundled engine". Only a click calls this.
    /// Unregisters (never deletes) the separate install's launch agents, then
    /// starts the bundled engine on the same data folder, so the password, devices
    /// and agents stay.
    func replaceInstalledWithBundled() {
        guard source == .installed else { return }
        work?.cancel()
        work = Task {
            guard bundledEngine != nil, bundledVersion != nil else { return await install(port: 4378, dataDir: paths.installedDataDir) }
            // Check Node before touching anything, so a failure leaves the install running.
            guard findNode() != nil else { return }
            state = .installing("Stopping the installed engine")
            for label in ShedLaunchAgent.installedLabels {
                _ = await launchctl(["bootout", "gui/\(uid)/\(label)"])
                // Without `disable`, the plist still in LaunchAgents starts again at login.
                _ = await launchctl(["disable", "gui/\(uid)/\(label)"])
            }
            for _ in 0..<20 where await Self.probe(port: 4378) { try? await Task.sleep(nanoseconds: 500_000_000) }
            await install(port: 4378, dataDir: paths.installedDataDir)
        }
    }

    private func turnOff() async {
        work?.cancel()
        if source == .bundled {
            _ = await launchctl(["bootout", target])
            _ = await launchctl(["disable", target])
        }
        state = .off
    }

    // MARK: Health

    private func waitHealthy() async {
        guard let port else { return }
        for _ in 0..<60 {
            if Task.isCancelled { return }
            if await Self.probe(port: port) { state = .running; return }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        state = .failed(logTail().isEmpty ? "The engine did not answer on port \(port)." : logTail())
    }

    /// Every 30 seconds. A server that stopped answering is reported, not restarted:
    /// launchd's KeepAlive already restarts ours.
    func checkHealth() async {
        guard isEnabled, let port else { return }
        switch state {
        case .running, .failed, .starting: break
        default: return
        }
        if await Self.probe(port: port) { state = .running }
        else if source == .bundled { state = .failed(logTail().isEmpty ? "The engine stopped answering." : logTail()) }
        else { state = .failed("The engine on port \(port) stopped answering.") }
    }

    func logTail(lines: Int = 8) -> String {
        let text = ["shed-engine.err.log", "shed-engine.log"].compactMap {
            try? String(contentsOf: paths.logDir.appendingPathComponent($0), encoding: .utf8)
        }.joined(separator: "\n")
        return Self.tail(text, lines: lines)
    }

    // MARK: Plumbing

    private var domain: String { "gui/\(uid)" }
    private var target: String { "gui/\(uid)/\(ShedLaunchAgent.label)" }

    private func isLoaded() async -> Bool { await launchctl(["print", target]).0 == 0 }

    @discardableResult
    private func launchctl(_ args: [String]) async -> (Int32, String) { await Self.run("/bin/launchctl", args) }

    nonisolated static func tail(_ text: String, lines: Int = 8) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: true).suffix(lines).joined(separator: "\n")
    }

    /// `GET /api/auth/status` is unauthenticated and its body names `passwordConfigured`,
    /// which tells a Shed server from any other thing that listens on the port.
    nonisolated static func probe(port: Int) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/api/auth/status") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        guard let (data, response) = try? await URLSession.shared.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200,
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return json["passwordConfigured"] != nil
    }

    nonisolated static func run(
        _ exe: String, _ args: [String], env: [String: String]? = nil, cwd: URL? = nil
    ) async -> (Int32, String) {
        await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            if let env { p.environment = env }
            p.currentDirectoryURL = cwd
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            guard (try? p.run()) != nil else { return (-1, "Could not run \(exe)") }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (p.terminationStatus, String(decoding: data, as: UTF8.self))
        }.value
    }
}
