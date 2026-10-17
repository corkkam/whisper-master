import XCTest

@testable import WhisperMaster

/// Call detection is a debounced state machine over polled mic evidence. Pure and
/// clock-injected, so both debounces are pinned here rather than on a live call.
final class CallDetectorTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_770_000_000)

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private func mic(_ ids: String..., playing: [String] = [], titles: [String: [String]] = [:],
                     calendar: String? = nil) -> CallEvidence {
        CallEvidence(micBundleIDs: ids, browserTitles: titles, calendarTitle: calendar, outputBundleIDs: playing)
    }

    // MARK: - What counts as a call

    func testANativeCallAppOnTheMicIsACall() {
        let call = CallDetector.call(in: mic("com.tinyspeck.slackmacgap", playing: ["com.tinyspeck.slackmacgap"]))
        XCTAssertEqual(call?.name, "Slack huddle")
        XCTAssertEqual(call?.bundleFamily, "com.tinyspeck.slackmacgap")
    }

    func testRecordingAVoiceMessageIsNotACall() {
        // Slack, WhatsApp and Telegram hold the mic for a voice message as long as
        // the user talks, but play nothing while they do.
        XCTAssertNil(CallDetector.call(in: mic("com.tinyspeck.slackmacgap")))
        XCTAssertNil(CallDetector.call(in: mic("net.whatsapp.WhatsApp", playing: ["com.apple.Music"])))
        // A call plays the other side, often from a helper process.
        XCTAssertEqual(CallDetector.call(in: mic(
            "net.whatsapp.WhatsApp", playing: ["net.whatsapp.WhatsApp.helper"]))?.name, "WhatsApp call")
        // Apps with no voice messages need no output to count.
        XCTAssertEqual(CallDetector.call(in: mic("us.zoom.xos"))?.name, "Zoom")
    }

    func testAVoiceMessageNeverStartsACallHoweverLongItRuns() {
        var detector = CallDetector()
        for second in stride(from: 0.0, through: 60, by: 2) {
            XCTAssertNil(detector.update(mic("com.tinyspeck.slackmacgap"), now: at(second)))
        }
        XCTAssertNil(detector.active)
    }

    func testAHelperProcessCountsForItsApp() {
        XCTAssertEqual(CallDetector.call(in: mic("us.zoom.xos.ZoomAudioDevice"))?.name, "Zoom")
    }

    func testAnUnknownAppOnTheMicIsNotACall() {
        XCTAssertNil(CallDetector.call(in: mic("com.apple.VoiceMemos")))
    }

    func testABrowserIsACallOnlyWhenATitleNamesAMeeting() {
        XCTAssertNil(CallDetector.call(in: mic(
            "com.google.Chrome.helper", titles: ["com.google.Chrome": ["Inbox - Gmail"]])))
        let call = CallDetector.call(in: mic(
            "com.google.Chrome.helper", titles: ["com.google.Chrome": ["Meet - abc-defg-hij"]]))
        XCTAssertEqual(call?.name, "Google Meet")
        XCTAssertEqual(call?.bundleFamily, "com.google.Chrome")
    }

    func testABrowserOnTheMicDuringACalendarMeetingIsThatMeeting() {
        let call = CallDetector.call(in: mic("com.apple.Safari", calendar: "Design review"))
        XCTAssertEqual(call?.name, "Browser call")
        XCTAssertEqual(call?.calendarTitle, "Design review")
    }

    func testANativeAppOutranksABrowser() {
        let call = CallDetector.call(in: mic(
            "com.google.Chrome", "com.microsoft.teams2",
            titles: ["com.google.Chrome": ["Meet - x"]]))
        XCTAssertEqual(call?.name, "Microsoft Teams")
    }

    func testAnIgnoredAppIsNeverOffered() {
        XCTAssertNil(CallDetector.call(
            in: mic("com.tinyspeck.slackmacgap"), ignoring: ["com.tinyspeck.slackmacgap"]))
    }

    // MARK: - Debounce

    func testStartWaitsForTheMicToStayHeld() {
        var detector = CallDetector()
        XCTAssertNil(detector.update(mic("us.zoom.xos"), now: at(0)))
        XCTAssertNil(detector.update(mic("us.zoom.xos"), now: at(2)))
        guard case .started(let call)? = detector.update(mic("us.zoom.xos"), now: at(3)) else {
            return XCTFail("expected a start after the hold")
        }
        XCTAssertEqual(call.name, "Zoom")
        // Announced once, not on every poll after.
        XCTAssertNil(detector.update(mic("us.zoom.xos"), now: at(5)))
    }

    func testAShortMicGrabNeverStartsACall() {
        var detector = CallDetector()
        XCTAssertNil(detector.update(mic("us.zoom.xos"), now: at(0)))
        XCTAssertNil(detector.update(mic(), now: at(2)))
        XCTAssertNil(detector.update(mic("us.zoom.xos"), now: at(4)))
        // The hold restarted at 4 s, so 6 s is still too soon.
        XCTAssertNil(detector.update(mic("us.zoom.xos"), now: at(6)))
    }

    func testABriefDropDoesNotEndTheCall() {
        var detector = startedDetector()
        XCTAssertNil(detector.update(mic(), now: at(10)))
        XCTAssertNil(detector.update(mic(), now: at(20)))
        XCTAssertNil(detector.update(mic("us.zoom.xos"), now: at(22)))
        // The drop timer reset when the mic came back.
        XCTAssertNil(detector.update(mic(), now: at(30)))
        XCTAssertNil(detector.update(mic(), now: at(40)))
    }

    func testTheCallEndsAfterTheMicStaysFree() {
        var detector = startedDetector()
        XCTAssertNil(detector.update(mic(), now: at(10)))
        XCTAssertEqual(detector.update(mic(), now: at(25)), .ended)
        XCTAssertNil(detector.active)
    }

    func testAnotherAppTakingTheMicEndsTheFirstCall() {
        var detector = startedDetector()
        XCTAssertNil(detector.update(mic("com.tinyspeck.slackmacgap"), now: at(10)))
        XCTAssertEqual(detector.update(mic("com.tinyspeck.slackmacgap"), now: at(25)), .ended)
    }

    func testAnotherCallAppListedFirstDoesNotHideTheCall() {
        var detector = startedDetector()
        let both = mic("com.microsoft.teams2", "us.zoom.xos")
        XCTAssertNil(detector.update(both, now: at(10)))
        XCTAssertNil(detector.update(both, now: at(40)))
        XCTAssertEqual(detector.active?.name, "Zoom")
    }

    func testSwitchingAwayFromTheMeetingTabDoesNotEndTheCall() {
        var detector = CallDetector()
        let meet = mic("com.google.Chrome.helper", titles: ["com.google.Chrome": ["Meet - abc-defg-hij"]])
        _ = detector.update(meet, now: at(0))
        XCTAssertEqual(detector.update(meet, now: at(3)), .started(
            DetectedCall(name: "Google Meet", bundleFamily: "com.google.Chrome", calendarTitle: nil)))
        // The front tab is a doc now; Chrome still holds the mic for the call.
        let docs = mic("com.google.Chrome.helper", titles: ["com.google.Chrome": ["Q3 plan - Google Docs"]])
        XCTAssertNil(detector.update(docs, now: at(10)))
        XCTAssertNil(detector.update(docs, now: at(60)))
        // And coming back to the tab is the same meeting, not a second offer.
        XCTAssertNil(detector.update(meet, now: at(62)))
        XCTAssertNotNil(detector.active)
    }

    func testACallOutlivesItsCalendarEvent() {
        var detector = CallDetector()
        let during = mic("com.apple.WebKit.GPU", calendar: "Design review")
        _ = detector.update(during, now: at(0))
        guard case .started? = detector.update(during, now: at(3)) else {
            return XCTFail("expected a start from the calendar meeting")
        }
        // The event ended but the meeting ran over: Safari still holds the mic.
        let after = mic("com.apple.WebKit.GPU")
        XCTAssertNil(detector.update(after, now: at(10)))
        XCTAssertNil(detector.update(after, now: at(60)))
        // It ends when the browser lets go.
        XCTAssertNil(detector.update(mic(), now: at(62)))
        XCTAssertEqual(detector.update(mic(), now: at(77)), .ended)
    }

    private func startedDetector() -> CallDetector {
        var detector = CallDetector()
        _ = detector.update(mic("us.zoom.xos"), now: at(0))
        _ = detector.update(mic("us.zoom.xos"), now: at(3))
        XCTAssertNotNil(detector.active)
        return detector
    }

    // MARK: - Calendar title

    func testTheLatestStartedCalendarEventNamesTheMeeting() {
        func event(_ title: String, start: TimeInterval, end: TimeInterval, allDay: Bool = false) -> DayEvent {
            DayEvent(id: title, title: title, start: at(start), end: at(end), isAllDay: allDay,
                     calendarTitle: "Work", sourceTitle: "Google", instanceLabel: "Work", joinURL: nil)
        }
        let events = [
            event("Focus", start: -3600, end: 3600),
            event("Standup", start: -60, end: 900),
            event("Holiday", start: -86_400, end: 86_400, allDay: true),
            event("Later", start: 600, end: 1200),
        ]
        XCTAssertEqual(MeetingController.calendarMeetingTitle(in: events, at: t0), "Standup")
        XCTAssertNil(MeetingController.calendarMeetingTitle(in: [events[3]], at: t0))
    }
}
