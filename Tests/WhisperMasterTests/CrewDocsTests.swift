import XCTest

/// The UI docs must match the Crew code and the test names.
final class CrewDocsTests: XCTestCase {
    private func uiDoc(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent("Sources/WhisperMaster/UI/\(name)"), encoding: .utf8)
    }

    func testClaudeDocSaysTheRailReadsEachProjectRoster() throws {
        let text = try uiDoc("CLAUDE.md")
        XCTAssertFalse(text.contains("never reads a project file"))
        XCTAssertTrue(text.contains("`<project>/.crew/crew.json`"))
    }

    func testInterfaceVerifiedByNamesRealTestClasses() throws {
        let text = try uiDoc("INTERFACE.md")
        XCTAssertFalse(text.contains("NotchQuickActionsTests"), "no test class has that name")
        XCTAssertTrue(text.contains("--filter NotchHoverGestureTests"))
    }

    func testInterfaceHasNoDeadDesignSpecLink() throws {
        let text = try uiDoc("INTERFACE.md")
        XCTAssertFalse(text.contains("docs/07-design-system.md"))
        XCTAssertLessThanOrEqual(text.utf8.count, 5120, "doctor d06 size limit")
    }
}
