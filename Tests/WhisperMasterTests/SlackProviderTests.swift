import XCTest

@testable import WhisperMaster

/// The Slack read path: markup the model can read, the ids worth naming, and the
/// scope fallback that keeps a token made from the setup copy readable.
@MainActor
final class SlackProviderTests: XCTestCase {

    func testSlackMarkupReadsAsWords() {
        let names = ["U1": "Sam"]
        XCTAssertEqual(
            SlackProvider.plainText("<@U1> see <#C9|launch> and <https://x.dev/a|the doc> &amp; <!here>",
                                    userNames: names),
            "@Sam see #launch and the doc & @here")
        XCTAssertEqual(SlackProvider.plainText("<@U2> ok"), "@U2 ok", "an unresolved id is kept, not dropped")
        XCTAssertEqual(SlackProvider.plainText("go to <https://x.dev>"), "go to https://x.dev")
        XCTAssertEqual(SlackProvider.plainText("a &lt;b&gt; c"), "a <b> c")
    }

    func testAuthorsAndMentionsAreLookedUpOnce() {
        let messages: [[String: Any]] = [
            ["user": "U1", "text": "ping <@W2> and <@U1|sam>"],
            ["user": "U3", "text": "no mentions"],
            ["bot_id": "B1", "text": "<@U3>"],
        ]
        XCTAssertEqual(SlackProvider.userIDs(in: messages), ["U1", "W2", "U3"])
    }

    /// Slack answers `missing_scope` for the whole call when any requested type lacks
    /// its scope, so the read must be able to fall back to public channels alone.
    func testConversationTypesFallBackToPublicChannels() {
        XCTAssertEqual(SlackProvider.conversationTypeFallbacks.first, "public_channel,private_channel,mpim,im")
        XCTAssertEqual(SlackProvider.conversationTypeFallbacks.last, "public_channel")
    }

    func testMissingScopeIsACredentialProblemNotAnOutage() {
        XCTAssertThrowsError(try ConnectorHTTP.requireSlackOK(["ok": false, "error": "missing_scope", "needed": "im:read"])) {
            XCTAssertEqual($0 as? ConnectorHTTP.Failure, .unauthorized)
        }
        XCTAssertThrowsError(try ConnectorHTTP.requireSlackOK(["ok": false, "error": "channel_not_found"])) {
            XCTAssertEqual($0 as? ConnectorHTTP.Failure, .badStatus(200, "channel_not_found"))
        }
        XCTAssertNoThrow(try ConnectorHTTP.requireSlackOK(["ok": true]))
    }

    /// The setup copy must ask for every scope the provider calls with, or a user who
    /// follows it exactly gets a connector that can read but never post.
    func testSetupCopyNamesTheScopesTheProviderUses() {
        let copy = ConnectorCatalog.descriptor(for: .slack).instructions.joined(separator: " ")
        for scope in ["channels:history", "groups:history", "im:history", "mpim:history",
                      "users:read", "chat:write"] {
            XCTAssertTrue(copy.contains(scope), "Slack setup copy is missing \(scope)")
        }
    }
}
