import XCTest

@testable import WhisperMaster

/// Finding the "join the call" link on a calendar invitation.
///
/// The interesting cases are all the *rejections*: an invitation body is full of
/// URLs, and opening the wrong one when the user asked to join a meeting is worse
/// than showing no button at all.
final class ConferenceLinkTests: XCTestCase {
    func testFindsAZoomLinkInTheLocationField() {
        let url = ConferenceLink.find(location: "https://acme.zoom.us/j/9182736450")
        XCTAssertEqual(url?.host, "acme.zoom.us")
    }

    func testFindsAMeetLinkBuriedInTheNotes() {
        let notes = """
            Agenda in the doc.

            Join with Google Meet: https://meet.google.com/abc-defg-hij
            Or dial: +1 555-0100 PIN: 123456#
            """
        XCTAssertEqual(ConferenceLink.find(notes: notes)?.host, "meet.google.com")
    }

    func testTheExplicitURLFieldIsTrustedFirst() {
        // A client that filled the field in meant it; the notes are a haystack.
        let url = ConferenceLink.find(
            url: "https://teams.microsoft.com/l/meetup-join/xyz",
            notes: "See also https://acme.zoom.us/j/1")
        XCTAssertEqual(url?.host, "teams.microsoft.com")
    }

    func testLocationBeatsNotes() {
        let url = ConferenceLink.find(
            location: "https://whereby.com/acme-standup",
            notes: "https://acme.zoom.us/j/1")
        XCTAssertEqual(url?.host, "whereby.com")
    }

    func testASubdomainOfAnAllowlistedHostIsAccepted() {
        XCTAssertNotNil(ConferenceLink.find(location: "https://eu01web.zoom.us/j/1"))
    }

    // MARK: - Rejections

    func testAnUnrelatedLinkInTheNotesIsNotOffered() {
        // The commonest shape of the bug this guards: the first URL in an
        // invitation body is very often not the call.
        let notes = """
            Unsubscribe: https://mail.acme.com/unsubscribe?u=91
            Room booking: https://rooms.acme.com/book/4
            Background reading: https://en.wikipedia.org/wiki/Meeting
            """
        XCTAssertNil(ConferenceLink.find(notes: notes))
    }

    func testALookalikeHostIsRejected() {
        XCTAssertNil(ConferenceLink.find(location: "https://notzoom.us/j/1"))
        XCTAssertNil(ConferenceLink.find(location: "https://zoom.us.evil.example/j/1"))
    }

    func testABareMarketingHostWithNoPathIsRejected() {
        XCTAssertNil(ConferenceLink.find(location: "https://zoom.us"))
        XCTAssertNil(ConferenceLink.find(location: "https://zoom.us/"))
    }

    func testNonWebSchemesAreRejected() {
        // `NSWorkspace.open` will happily launch these, which is exactly why the
        // allowlist is re-applied at the point of opening as well as here.
        XCTAssertFalse(ConferenceLink.isJoinable(URL(string: "file:///etc/passwd")!))
        XCTAssertFalse(ConferenceLink.isJoinable(URL(string: "ftp://acme.zoom.us/j/1")!))
    }

    func testEmptyInputYieldsNothing() {
        XCTAssertNil(ConferenceLink.find())
        XCTAssertNil(ConferenceLink.find(url: "", location: "", notes: ""))
    }

    func testAJoinableLinkFollowedByNoiseIsStillFound() {
        let notes = "Read https://acme.com/doc first, then join https://acme.zoom.us/j/55 at ten."
        XCTAssertEqual(ConferenceLink.find(notes: notes)?.path, "/j/55")
    }
}
