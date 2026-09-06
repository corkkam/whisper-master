import XCTest

@testable import WhisperMaster

/// The wire contract with kunai. These matter because the server **self-updates
/// independently of this app**: a field added on that side must never stop an event
/// this side already understands from decoding.
final class KunaiWireTests: XCTestCase {

    private func event(_ json: String) throws -> KunaiWire.Event {
        try JSONDecoder().decode(KunaiWire.Event.self, from: Data(json.utf8))
    }

    func testAnEventTypeWeHaveNoSurfaceForStillDecodes() throws {
        // kunai ships compact, rate_limit and failover frames. None has a notch
        // surface, and every one of them has to decode and be ignored rather than
        // break the stream.
        let decoded = try event(#"{"seq":7,"t":"rate_limit","window":"5h"}"#)
        XCTAssertEqual(decoded.kind, .unknown)
        XCTAssertEqual(decoded.seq, 7)
    }

    func testUnknownFieldsDoNotBreakAFrameWeUnderstand() throws {
        let decoded = try event(
            #"{"seq":3,"t":"user","text":"hi","some_future_field":{"a":[1,2]}}"#)
        XCTAssertEqual(decoded.kind, .user)
        XCTAssertEqual(decoded.text, "hi")
    }

    func testHelloCarriesEpochAndPendingAsks() throws {
        let decoded = try event(
            """
            {"seq":1,"t":"hello","id":"s1","epoch":"e9","cwd":"/x/whisper-master",
             "mode":"acceptEdits","high_seq":12,
             "pending":[{"seq":9,"t":"permission","request_id":"r1","tool_name":"Bash"}]}
            """)
        XCTAssertEqual(decoded.epoch, "e9")
        XCTAssertEqual(decoded.highSeq, 12)
        XCTAssertEqual(decoded.pending?.count, 1)
        XCTAssertEqual(decoded.pending?.first?.requestID, "r1")
    }

    func testToolInputIsReadableWithoutModellingTheTool() throws {
        let decoded = try event(
            #"{"seq":4,"t":"permission","request_id":"r","tool_name":"Bash","input":{"command":"rm -rf build/","timeout":120}}"#)
        XCTAssertEqual(decoded.input?.asJSON.string("command"), "rm -rf build/")
    }

    func testAMalformedFrameDegradesInsteadOfThrowing() throws {
        // No seq at all. It must still decode, and simply never advance the resume
        // mark, rather than taking the socket down.
        let decoded = try event(#"{"t":"delta","text":"partial"}"#)
        XCTAssertEqual(decoded.seq, 0)
        XCTAssertEqual(decoded.kind, .delta)
    }

    // MARK: Commands

    func testPermissionCommandUsesKunaiSpelling() throws {
        let command = KunaiWire.Command.permission(requestID: "r1", allow: true, always: true)
        let json = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(command)) as? [String: Any]
        XCTAssertEqual(json?["t"] as? String, "permission")
        XCTAssertEqual(json?["request_id"] as? String, "r1")
        XCTAssertEqual(json?["behavior"] as? String, "allow")
        XCTAssertEqual(json?["always"] as? Bool, true)
    }

    func testDenyingNeverSendsAlways() throws {
        // `always: false` must be omitted, not sent as false: kunai persists a
        // session rule off this flag and an explicit false on a deny is a different
        // statement from its absence.
        let command = KunaiWire.Command.permission(requestID: "r1", allow: false)
        let json = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(command)) as? [String: Any]
        XCTAssertEqual(json?["behavior"] as? String, "deny")
        XCTAssertNil(json?["always"])
    }

    func testModeCommandSendsTheCLISpellingNotTheLabel() throws {
        let command = KunaiWire.Command.setMode(.auto)
        let json = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(command)) as? [String: Any]
        XCTAssertEqual(json?["mode"] as? String, "acceptEdits")
    }

    func testBypassPermissionsIsNotOfferable() {
        // Deliberately absent: a panel whose consent story is a three-answer card
        // must not also offer one-tap "never ask again", and it could not be undone
        // from the same panel that set it.
        XCTAssertNil(KunaiWire.PermissionMode(rawValue: "bypassPermissions"))
        XCTAssertEqual(KunaiWire.PermissionMode.allCases.count, 3)
    }

    func testAnUnfamiliarModeFallsBackToAsking() {
        // The safe direction: an unrecognised mode must never read as Auto.
        XCTAssertEqual(KunaiWire.PermissionMode(wire: "somethingNew"), .ask)
        XCTAssertEqual(KunaiWire.PermissionMode(wire: nil), .ask)
    }

    // MARK: Session list

    func testSessionMetaToleratesAMissingTitle() throws {
        let meta = try JSONDecoder().decode(
            KunaiWire.SessionMeta.self,
            from: Data(#"{"id":"s1","cwd":"/Users/x/kunai","state":"running"}"#.utf8))
        XCTAssertEqual(meta.title, "")
        XCTAssertEqual(meta.state, "running")
    }
}
