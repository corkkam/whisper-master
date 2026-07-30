import XCTest

@testable import WhisperMaster

/// Consent and authorization. The headline test here is
/// `testAGrantOnOneInstanceDoesNotAuthoriseAnother` — the cross-instance leak that
/// forced the three-part grant key.
@MainActor
final class ConnectorConsentTests: XCTestCase {
    private let workID = UUID()
    private let personalID = UUID()

    private var sendMessage: ToolDescriptor {
        ToolCatalog.descriptor(named: "send_message")!
    }

    private var listEvents: ToolDescriptor {
        ToolCatalog.descriptor(named: "list_calendar_events")!
    }

    // MARK: - The leak the design exists to prevent

    /// openworker keys grants on `(tool, target)`. With named instances that leaks:
    /// `#general` on Personal Slack and `#general` on Work Slack are different channels
    /// with the same name, and approving one must not authorise the other.
    func testAGrantOnOneInstanceDoesNotAuthoriseAnother() {
        let grants = [Grant(tool: "send_message", instanceID: workID, target: "#general")]

        XCTAssertEqual(
            WriteAuthorizer.authorize(tool: sendMessage, instanceID: workID,
                                      target: "#general", grants: grants),
            .granted)
        XCTAssertEqual(
            WriteAuthorizer.authorize(tool: sendMessage, instanceID: personalID,
                                      target: "#general", grants: grants),
            .needsApproval,
            "a grant on Work must not authorise the same channel name on Personal")
    }

    func testAGrantDoesNotSpreadToAnotherTargetOrTool() {
        let grants = [Grant(tool: "send_message", instanceID: workID, target: "#general")]
        XCTAssertEqual(
            WriteAuthorizer.authorize(tool: sendMessage, instanceID: workID,
                                      target: "#random", grants: grants),
            .needsApproval)
        XCTAssertEqual(
            WriteAuthorizer.authorize(tool: ToolCatalog.descriptor(named: "create_calendar_event")!,
                                      instanceID: workID, target: "#general", grants: grants),
            .needsApproval)
    }

    /// Targets round-trip through speech, so matching is case-insensitive.
    func testTargetMatchingIsCaseInsensitive() {
        let grants = [Grant(tool: "send_message", instanceID: workID, target: "#General")]
        XCTAssertEqual(
            WriteAuthorizer.authorize(tool: sendMessage, instanceID: workID,
                                      target: "#general", grants: grants),
            .granted)
    }

    // MARK: - Fail-closed cases

    func testAWriteWithNoTargetIsRefusedNotAsked() {
        guard case .refused = WriteAuthorizer.authorize(
            tool: sendMessage, instanceID: workID, target: nil, grants: []) else {
            return XCTFail("a write with no target must be refused")
        }
    }

    func testABlankTargetIsRefused() {
        guard case .refused = WriteAuthorizer.authorize(
            tool: sendMessage, instanceID: workID, target: "   ", grants: []) else {
            return XCTFail("a blank target must be refused")
        }
    }

    /// A write tool that declares no `targetArg` could only ever be blanket permission,
    /// so it's refused rather than offered.
    func testAWriteToolWithoutATargetArgIsRefused() {
        let untargeted = ToolDescriptor(
            name: "nuke", summary: "", access: .write,
            capability: .messages, targetArg: nil, parameters: [])
        guard case .refused = WriteAuthorizer.authorize(
            tool: untargeted, instanceID: workID, target: "x", grants: []) else {
            return XCTFail("an untargetable write must be refused")
        }
    }

    func testReadsNeedNoAuthorization() {
        XCTAssertEqual(
            WriteAuthorizer.authorize(tool: listEvents, instanceID: workID,
                                      target: nil, grants: []),
            .granted)
    }

    // MARK: - Grant identity + store

    func testGrantIDIsStableAcrossTargetCasingAndGrantTime() {
        let a = Grant(tool: "send_message", instanceID: workID, target: "#Ops",
                      grantedAt: Date(timeIntervalSince1970: 0))
        let b = Grant(tool: "send_message", instanceID: workID, target: "#ops",
                      grantedAt: Date(timeIntervalSince1970: 999))
        XCTAssertEqual(a.id, b.id, "the same three-part key is the same grant")
    }

    func testAddGrantIsIdempotent() {
        let store = ConnectorInstanceStore(load: false)
        store.persistenceEnabled = false
        store.addGrant(Grant(tool: "send_message", instanceID: workID, target: "#ops"))
        store.addGrant(Grant(tool: "send_message", instanceID: workID, target: "#OPS"))
        XCTAssertEqual(store.grants.count, 1)
    }

    /// A removed connection must not leave live permissions behind.
    func testRemovingAConnectionRevokesItsGrants() {
        let store = ConnectorInstanceStore(load: false)
        store.persistenceEnabled = false
        let slack = store.add(ConnectorInstance(kind: .slack, label: "Work", identity: "acme"))
        let other = store.add(ConnectorInstance(kind: .slack, label: "Personal", identity: "me"))
        store.addGrant(Grant(tool: "send_message", instanceID: slack.id, target: "#ops"))
        store.addGrant(Grant(tool: "send_message", instanceID: other.id, target: "#ops"))

        store.remove(slack.id)
        XCTAssertEqual(store.grants.count, 1)
        XCTAssertEqual(store.grants.first?.instanceID, other.id)
    }

    func testRevokeGrantRemovesExactlyOne() {
        let store = ConnectorInstanceStore(load: false)
        store.persistenceEnabled = false
        let keep = Grant(tool: "send_message", instanceID: workID, target: "#keep")
        let drop = Grant(tool: "send_message", instanceID: workID, target: "#drop")
        store.addGrant(keep)
        store.addGrant(drop)
        store.revokeGrant(id: drop.id)
        XCTAssertEqual(store.grants.map(\.id), [keep.id])
    }

    // MARK: - Approval card copy

    func testApprovalHeadlineNamesTheConnection() {
        let approval = PendingApproval(
            tool: "send_message", instanceID: workID, instanceLabel: "Work",
            target: "#ops", arguments: ["channel": "#ops", "text": "hi"])
        XCTAssertEqual(approval.headline, "Post to #ops on Work")
    }

    /// The card must show the payload, and must not spend a line on the connector
    /// argument that's already in the headline.
    func testApprovalDetailLinesExcludeTheConnectorArgument() {
        let approval = PendingApproval(
            tool: "send_message", instanceID: workID, instanceLabel: "Work",
            target: "#ops",
            arguments: ["channel": "#ops", "text": "ship it", ToolDescriptor.instanceArgument: "Work"])
        let keys = approval.detailLines.map(\.0)
        XCTAssertEqual(keys, ["channel", "text"])
    }

    // MARK: - Coordinator

    func testResolvingAnApprovalReturnsTheOutcomeAndClearsTheCard() async {
        let coordinator = ApprovalCoordinator()
        let approval = PendingApproval(
            tool: "send_message", instanceID: workID, instanceLabel: "Work",
            target: "#ops", arguments: [:])

        let task = Task { await coordinator.request(approval) }
        // Let the request land before answering it.
        while coordinator.pending == nil { await Task.yield() }
        coordinator.resolve(.allowedAlways)

        let outcome = await task.value
        XCTAssertEqual(outcome, .allowedAlways)
        XCTAssertNil(coordinator.pending)
    }

    /// One card at a time: a second request is denied rather than queued behind a card
    /// the user is still reading.
    func testASecondSimultaneousRequestIsDenied() async {
        let coordinator = ApprovalCoordinator()
        let first = PendingApproval(tool: "send_message", instanceID: workID,
                                    instanceLabel: "Work", target: "#a", arguments: [:])
        let second = PendingApproval(tool: "send_message", instanceID: workID,
                                     instanceLabel: "Work", target: "#b", arguments: [:])

        let firstTask = Task { await coordinator.request(first) }
        while coordinator.pending == nil { await Task.yield() }

        let secondOutcome = await coordinator.request(second)
        XCTAssertEqual(secondOutcome, .denied)

        coordinator.resolve(.allowedOnce)
        let firstOutcome = await firstTask.value
        XCTAssertEqual(firstOutcome, .allowedOnce)
    }

    /// Silence is never consent.
    func testUnattendedPolicyDeniesEverything() async {
        let approval = PendingApproval(tool: "send_message", instanceID: workID,
                                       instanceLabel: "Work", target: "#ops", arguments: [:])
        let outcome = await ApprovalCoordinator.denyUnattended(approval)
        XCTAssertEqual(outcome, .denied)
    }

    // MARK: - Catalog integrity

    /// A write tool with no target argument can't be scoped, so it must never ship.
    func testEveryWriteToolDeclaresATargetArgument() {
        for tool in ToolCatalog.all where tool.access == .write {
            XCTAssertNotNil(tool.targetArg, "\(tool.name) is a write with no targetArg")
            XCTAssertTrue(tool.parameters.contains { $0.name == tool.targetArg },
                          "\(tool.name)'s targetArg isn't one of its parameters")
        }
    }
}
