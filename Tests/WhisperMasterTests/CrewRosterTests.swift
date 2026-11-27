import XCTest

@testable import WhisperMaster

/// Writes `<project>/.crew/crew.json` for the roster tests.
func crewWriteRoster(_ project: URL, agents: String) throws {
    let dir = project.appendingPathComponent(".crew", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let json = #"{"version":1,"lead":"lead","agents":[\#(agents)]}"#
    try json.write(to: dir.appendingPathComponent("crew.json"), atomically: true, encoding: .utf8)
}

let crewSampleAgents = """
{"id":"lead","role":"lead","name":"Atlas"},
{"id":"pm","role":"pm","name":"Maya","hue":2},
{"id":"qa","role":"qa","name":"Quinn"},
{"id":"design","role":"design","name":"Iris"},
{"id":"marketing","role":"marketing","name":"Nova"},
{"id":"user","role":"user","name":"Juno"},
{"id":"architect","role":"architect","name":"Theo"},
{"id":"scout","role":"helper","name":"Scout"},
{"id":"c-input","role":"component","name":"Tapper","component_dir":"whisper-master/Sources/WhisperMaster/Input"},
{"id":"c-bare","role":"component"},
{"id":"security","role":"custom","name":"Sentry"},
{"id":"odd","role":"mystery","name":"Odd"}
"""

final class CrewRosterTests: XCTestCase {
    private var project: URL!
    private let roster = CrewRoster()

    override func setUpWithError() throws {
        project = try CrewTestFiles.makeFolder()
        try crewWriteRoster(project, agents: crewSampleAgents)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: project)
    }

    private func identity(_ agent: String) -> AgentFaceIdentity? {
        roster.identity(project: project.path, agent: agent)
    }

    func testEachPersonaRoleMapsToItsFaceRole() {
        let expected: [(String, AgentFaceRole, String)] = [
            ("lead", .lead, "Atlas"), ("pm", .pm, "Maya"), ("qa", .qa, "Quinn"),
            ("design", .design, "Iris"), ("marketing", .marketing, "Nova"),
            ("user", .user, "Juno"), ("architect", .architect, "Theo"),
        ]
        for (id, role, name) in expected {
            XCTAssertEqual(identity(id)?.role, role, id)
            XCTAssertEqual(identity(id)?.name, name, id)
        }
    }

    func testHueFromFileOrFromName() {
        XCTAssertEqual(identity("pm")?.hueIndex, 2)
        XCTAssertEqual(identity("qa")?.hueIndex, AgentFaceIdentity.defaultHueIndex(for: "Quinn"))
    }

    func testComponentUsesItsFolderName() {
        let c = identity("c-input")
        XCTAssertEqual(c?.role, .component)
        XCTAssertEqual(c?.name, "Tapper")
        XCTAssertEqual(c?.componentName, "Input")
    }

    func testComponentWithoutFolderUsesItsName() {
        let c = identity("c-bare")
        XCTAssertEqual(c?.role, .component)
        XCTAssertEqual(c?.name, "c-bare")
        XCTAssertEqual(c?.componentName, "c-bare")
    }

    func testCustomMapsToComponentWithItsNameAsComponent() {
        let c = identity("security")
        XCTAssertEqual(c?.role, .component)
        XCTAssertEqual(c?.componentName, "Sentry")
    }

    func testHelperMapsToNil() {
        XCTAssertNil(identity("scout"))
    }

    func testUnknownRoleStringFallsBackToComponent() {
        XCTAssertEqual(identity("odd")?.role, .component)
    }

    func testUnknownAgentFallsBackToIdAsName() {
        let i = identity("ghost")
        XCTAssertEqual(i?.name, "ghost")
        XCTAssertEqual(i?.role, .component)
    }

    func testUnknownProjectFallsBackToIdAsName() {
        let i = roster.identity(project: "/definitely/not/here", agent: "x")
        XCTAssertEqual(i?.name, "x")
        XCTAssertEqual(i?.role, .component)
        XCTAssertFalse(roster.isLead(project: "/definitely/not/here", agent: "x"))
    }

    func testIsLeadIsTrueOnlyForTheLeadRole() {
        XCTAssertTrue(roster.isLead(project: project.path, agent: "lead"))
        XCTAssertFalse(roster.isLead(project: project.path, agent: "pm"))
        XCTAssertFalse(roster.isLead(project: project.path, agent: "ghost"))
    }

    func testBrokenFileFallsBack() throws {
        let broken = try CrewTestFiles.makeFolder()
        defer { try? FileManager.default.removeItem(at: broken) }
        let dir = broken.appendingPathComponent(".crew")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "{ nope".write(to: dir.appendingPathComponent("crew.json"), atomically: true, encoding: .utf8)
        XCTAssertEqual(roster.identity(project: broken.path, agent: "lead")?.role, .component)
    }

    func testCacheReloadsWhenTheFileChanges() throws {
        XCTAssertEqual(identity("pm")?.name, "Maya")
        try crewWriteRoster(project, agents: #"{"id":"pm","role":"pm","name":"Maya Renamed"}"#)
        XCTAssertEqual(identity("pm")?.name, "Maya Renamed")
        XCTAssertFalse(roster.isLead(project: project.path, agent: "lead"))
    }
}
