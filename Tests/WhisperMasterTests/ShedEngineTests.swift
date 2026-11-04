import XCTest

@testable import WhisperMaster

/// The Shed engine supervisor's pure parts. Nothing here registers a launch agent,
/// runs npm or node, or touches `~/.shed`: the file system is a temp folder or an
/// injected closure.
final class ShedEngineTests: XCTestCase {

    // MARK: Node discovery and versions

    func testNodeVersionParsing() {
        XCTAssertEqual(NodeVersion.parse("v20.11.1\n"), NodeVersion(major: 20, minor: 11, patch: 1))
        XCTAssertEqual(NodeVersion.parse("22"), NodeVersion(major: 22, minor: 0, patch: 0))
        XCTAssertNil(NodeVersion.parse("node: command not found"))
        XCTAssertNil(NodeVersion.parse(""))
        XCTAssertFalse(NodeVersion.parse("v18.19.0")!.isSupported)
        XCTAssertTrue(NodeVersion.parse("v20.0.0")!.isSupported)
    }

    private func locator(
        path: String = "", installed: [String: String], nvm: [String] = []
    ) -> ShedNodeLocator {
        ShedNodeLocator(
            home: "/h", pathEnv: path,
            isExecutable: { installed[$0] != nil },
            listDirectory: { $0 == "/h/.nvm/versions/node" ? nvm : [] },
            versionOf: { installed[$0].flatMap(NodeVersion.parse) })
    }

    func testNodeSearchOrderAndNvmNewestFirst() {
        let l = locator(path: "/a:/opt/homebrew/bin", installed: [:], nvm: ["v18.1.0", "v22.2.0", "v20.9.0"])
        XCTAssertEqual(l.candidates(), [
            "/a/node", "/opt/homebrew/bin/node", "/usr/local/bin/node",
            "/h/.nvm/versions/node/v22.2.0/bin/node", "/h/.nvm/versions/node/v20.9.0/bin/node",
            "/h/.nvm/versions/node/v18.1.0/bin/node",
        ])
    }

    func testAnOldNodeOnPathLosesToANewerOneElsewhere() {
        let l = locator(path: "/usr/bin", installed: ["/usr/bin/node": "v18.0.0", "/opt/homebrew/bin/node": "v22.1.0"])
        XCTAssertEqual(l.locate(), .found(path: "/opt/homebrew/bin/node", version: NodeVersion(major: 22, minor: 1, patch: 0)))
    }

    func testOnlyAnOldNodeIsReportedAsTooOldAndNoNodeAsMissing() {
        XCTAssertEqual(
            locator(installed: ["/usr/local/bin/node": "v16.0.0"]).locate(),
            .tooOld(path: "/usr/local/bin/node", version: NodeVersion(major: 16, minor: 0, patch: 0)))
        XCTAssertEqual(locator(installed: [:]).locate(), .missing)
    }

    // MARK: Port choice

    func testPortChoice() {
        XCTAssertEqual(ShedPort.choose(isInUse: { _ in false }), 4378)
        XCTAssertEqual(ShedPort.choose(isInUse: { $0 == 4378 }), 4380)
        XCTAssertNil(ShedPort.choose(isInUse: { _ in true }))
    }

    // MARK: Launch agent

    func testLaunchAgentPlistContent() throws {
        let data = try ShedLaunchAgent.plist(
            node: "/opt/homebrew/bin/node", engineDir: URL(fileURLWithPath: "/E"),
            dataDir: URL(fileURLWithPath: "/D"), port: 4380, logDir: URL(fileURLWithPath: "/L"), home: "/h")
        let root = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(root["Label"] as? String, "com.whispermaster.shed-engine")
        XCTAssertEqual(root["ProgramArguments"] as? [String], ["/opt/homebrew/bin/node", "/E/server/index.js"])
        XCTAssertEqual(root["WorkingDirectory"] as? String, "/E")
        XCTAssertEqual(root["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(root["KeepAlive"] as? Bool, true)
        XCTAssertEqual(root["StandardOutPath"] as? String, "/L/shed-engine.log")
        XCTAssertEqual(root["StandardErrorPath"] as? String, "/L/shed-engine.err.log")
        let env = try XCTUnwrap(root["EnvironmentVariables"] as? [String: String])
        XCTAssertEqual(env["PORT"], "4380")
        XCTAssertEqual(env["LAYA_DATA_DIR"], "/D")
        XCTAssertTrue(try XCTUnwrap(env["PATH"]).hasPrefix("/h/.local/bin:"))
        XCTAssertTrue(try XCTUnwrap(env["PATH"]).contains("/opt/homebrew/bin"))
        XCTAssertEqual(ShedLaunchAgent.settings(inPlist: data), .init(port: 4380, dataDir: "/D"))
    }

    // MARK: Copy-when-the-version-differs

    private func version(_ hash: String, dirty: Bool = false) -> ShedEngineVersion {
        ShedEngineVersion(commit: "abc1234", dirty: dirty, hash: hash)
    }

    func testCopyRule() {
        XCTAssertFalse(ShedEngineVersion.needsCopy(bundled: version("a"), installed: version("a")))
        XCTAssertTrue(ShedEngineVersion.needsCopy(bundled: version("a"), installed: version("b")))
        XCTAssertTrue(ShedEngineVersion.needsCopy(bundled: version("a"), installed: version("a", dirty: true)))
        XCTAssertTrue(ShedEngineVersion.needsCopy(bundled: version("a"), installed: nil))
        XCTAssertFalse(ShedEngineVersion.needsCopy(bundled: nil, installed: version("a")))
    }

    func testSyncKeepsDependenciesAndTokenAndDropsStaleFiles() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("shed-sync-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        let bundle = tmp.appendingPathComponent("bundle"), dest = tmp.appendingPathComponent("dest")
        for dir in ["bundle/server", "dest/server", "dest/node_modules"] {
            try fm.createDirectory(at: tmp.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        try "new".write(to: bundle.appendingPathComponent("server/index.js"), atomically: true, encoding: .utf8)
        try Data(#"{"commit":"c","dirty":false,"hash":"h"}"#.utf8)
            .write(to: bundle.appendingPathComponent(ShedEngineVersion.fileName))
        try "old".write(to: dest.appendingPathComponent("server/index.js"), atomically: true, encoding: .utf8)
        try "stale".write(to: dest.appendingPathComponent("server/gone.js"), atomically: true, encoding: .utf8)
        try "tok".write(to: dest.appendingPathComponent(".laya-token"), atomically: true, encoding: .utf8)

        try ShedEngineFiles.sync(from: bundle, to: dest)
        XCTAssertEqual(try String(contentsOf: dest.appendingPathComponent("server/index.js")), "new")
        XCTAssertFalse(fm.fileExists(atPath: dest.appendingPathComponent("server/gone.js").path))
        XCTAssertTrue(fm.fileExists(atPath: dest.appendingPathComponent("node_modules").path))
        XCTAssertTrue(fm.fileExists(atPath: dest.appendingPathComponent(".laya-token").path))
        // The version file lands only after npm ci succeeds.
        XCTAssertNil(ShedEngineVersion.read(from: dest))
        try ShedEngineFiles.commitVersion(from: bundle, to: dest)
        XCTAssertEqual(ShedEngineVersion.read(from: dest), ShedEngineVersion(commit: "c", dirty: false, hash: "h"))
    }

    // MARK: Endpoint

    func testEndpointURLsAndToken() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("tok-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try "secret\n".write(to: tmp, atomically: true, encoding: .utf8)
        let e = ShedEndpoint(baseURL: URL(string: "http://127.0.0.1:4378")!, tokenFile: tmp)
        XCTAssertEqual(e.port, 4378)
        XCTAssertEqual(e.readToken(), "secret")
        XCTAssertEqual(e.pageURL().absoluteString, "http://127.0.0.1:4378/")
        XCTAssertEqual(e.pageURL(sessionID: "a b&c").absoluteString, "http://127.0.0.1:4378/?session=a%20b%26c")
    }

    // MARK: Bundle copy exclusions

    /// Runs the real `Scripts/stage-shed-engine.sh` on a fake Shed checkout.
    func testStageScriptCopiesOnlyTheEngineFiles() throws {
        let fm = FileManager.default
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let tmp = fm.temporaryDirectory.appendingPathComponent("shed-stage-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        let src = tmp.appendingPathComponent("src"), dest = tmp.appendingPathComponent("out/ShedEngine")
        let files = [
            "server/index.js", "server/node_modules/x/y.js", "public/app.js", "bin/shed", "package.json",
            "package-lock.json", "LICENSE", ".jev-data/tasks.json", ".laya-token", ".git/HEAD",
            "video/demo.mp4", "site/install.sh", "test/a.test.js", "README.md",
        ]
        for f in files {
            let url = src.appendingPathComponent(f)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "x".write(to: url, atomically: true, encoding: .utf8)
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [repo.appendingPathComponent("Scripts/stage-shed-engine.sh").path, dest.path]
        p.environment = ["SHED_SRC": src.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": tmp.path]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)

        func has(_ rel: String) -> Bool { fm.fileExists(atPath: dest.appendingPathComponent(rel).path) }
        for kept in ["server/index.js", "public/app.js", "bin/shed", "package.json", "package-lock.json", "LICENSE", "ENGINE_VERSION.json"] {
            XCTAssertTrue(has(kept), "\(kept) should be copied")
        }
        for dropped in ["server/node_modules", ".jev-data", ".laya-token", ".git", "video", "site", "test", "README.md"] {
            XCTAssertFalse(has(dropped), "\(dropped) must not be copied")
        }
        let version = try XCTUnwrap(ShedEngineVersion.read(from: dest))
        XCTAssertEqual(version.commit, "unknown")  // the fake checkout is not a git repo
        XCTAssertEqual(version.hash.count, 16)
    }

    func testStageScriptWarnsAndSucceedsWithoutASource() throws {
        let fm = FileManager.default
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let tmp = fm.temporaryDirectory.appendingPathComponent("shed-nosrc-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [repo.appendingPathComponent("Scripts/stage-shed-engine.sh").path, tmp.appendingPathComponent("out").path]
        p.environment = ["SHED_SRC": tmp.appendingPathComponent("missing").path, "PATH": "/usr/bin:/bin"]
        let err = Pipe()
        p.standardError = err; p.standardOutput = Pipe()
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        XCTAssertTrue(String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).contains("warning"))
        XCTAssertFalse(fm.fileExists(atPath: tmp.appendingPathComponent("out").path))
    }
}
