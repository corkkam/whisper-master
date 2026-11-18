import XCTest

@testable import WhisperMaster

/// How many tools one local prompt offers, and which ones go first when there are
/// too many.
final class ToolPackRouterTests: XCTestCase {
    private func tool(_ name: String, _ summary: String,
                      access: ToolAccess = .read) -> ToolDescriptor {
        ToolDescriptor(name: name, summary: summary, access: access,
                       capability: nil, targetArg: nil, parameters: [])
    }

    /// Four local tools and sixteen connector tools: twenty, four over the limit.
    private var crowded: [ToolDescriptor] {
        LocalToolCatalog.all + [LocalToolCatalog.readSelection]
            + [tool("list_mail", "List recent or unread email in the user's mailbox."),
               tool("list_calendar_events", "List calendar events for a day.")]
            + (1...14).map { tool("list_widget_\($0)", "List widget \($0) records.") }
    }

    func testAtOrUnderTheLimitNothingChanges() {
        let tools = Array(crowded.prefix(16))
        XCTAssertEqual(ToolPackRouter.pack(tools, spoken: "anything"), tools)
    }

    func testOverTheLimitTheLeastRelevantConnectorToolsGo() {
        let packed = ToolPackRouter.pack(crowded, spoken: "check my emails from Sam")

        XCTAssertEqual(packed.count, 16)
        XCTAssertTrue(packed.contains { $0.name == "list_mail" }, "the tool the words name stays")
        for local in LocalToolCatalog.all + [LocalToolCatalog.readSelection] {
            XCTAssertTrue(packed.contains(local), "\(local.name) is always offered")
        }
        // The rest tie at nothing in common, so the last ones in the list go.
        XCTAssertFalse(packed.contains { $0.name == "list_widget_14" })
        XCTAssertTrue(packed.contains { $0.name == "list_widget_1" })
    }

    func testThePackKeepsTheListsOwnOrder() {
        let packed = ToolPackRouter.pack(crowded, spoken: "what is on my calendar")
        let order = crowded.map(\.name).filter { name in packed.contains { $0.name == name } }
        XCTAssertEqual(packed.map(\.name), order, "local tools stay first, as the prompt wants")
    }

    func testAPluralMeetsItsSingular() {
        XCTAssertTrue(ToolPackRouter.keywords("my emails").contains("email"))
        XCTAssertTrue(ToolPackRouter.keywords("list_calendar_events").contains("event"))
        XCTAssertFalse(ToolPackRouter.keywords("is it on").contains("is"), "short words carry nothing")
    }

    /// Today's catalog never reaches the limit, so nothing is dropped from a real run.
    func testTheShippedCatalogFitsUnderTheLimit() {
        let everything = LocalToolCatalog.all + [LocalToolCatalog.readSelection] + ToolCatalog.all
        XCTAssertLessThanOrEqual(everything.count, ToolPackRouter.limit)
    }
}
