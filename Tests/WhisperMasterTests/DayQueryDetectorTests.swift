import XCTest

@testable import WhisperMaster

/// The pure wake-phrase gate for "what's my day" queries + the connector catalog /
/// store. No EventKit, no model, no audio.
final class DayQueryDetectorTests: XCTestCase {
    // MARK: - DayQueryDetector

    func testMatchesLeadingWakePhrases() {
        XCTAssertTrue(DayQueryDetector.matches("what's my day"))
        XCTAssertTrue(DayQueryDetector.matches("What's my day?"))
        XCTAssertTrue(DayQueryDetector.matches("what's on my calendar"))
        XCTAssertTrue(DayQueryDetector.matches("hey whisper what's my day"))
        XCTAssertTrue(DayQueryDetector.matches("how's my day looking today")) // prefix match
    }

    func testMatchesLooseQuestionAboutMine() {
        XCTAssertTrue(DayQueryDetector.matches("what do I have on my schedule?"))
        XCTAssertTrue(DayQueryDetector.matches("show me my meetings"))
    }

    func testDoesNotHijackOrdinaryDictation() {
        XCTAssertFalse(DayQueryDetector.matches("please email the team about my day off request"))
        XCTAssertFalse(DayQueryDetector.matches("the meeting went well and we shipped it"))
        XCTAssertFalse(DayQueryDetector.matches("remind me to call mom"))
        XCTAssertFalse(DayQueryDetector.matches(""))
    }

    // MARK: - ConnectorKind catalog

    func testFeaturedConnectorsAreTheFive() {
        XCTAssertEqual(
            ConnectorKind.featured,
            [.gmail, .googleCalendar, .outlook, .slack, .appleCalendar])
    }

    func testFeaturedAndPopularPartitionAllCases() {
        let union = Set(ConnectorKind.featured).union(ConnectorKind.popular)
        XCTAssertEqual(union, Set(ConnectorKind.allCases))
        XCTAssertTrue(Set(ConnectorKind.featured).isDisjoint(with: Set(ConnectorKind.popular)))
    }

    func testCalendarConnectorsUseSystemAuthAndFeedCalendar() {
        for kind in [ConnectorKind.appleCalendar, .googleCalendar, .outlook] {
            XCTAssertEqual(kind.auth, .system, "\(kind) should read via EventKit")
            XCTAssertTrue(kind.feedsCalendar)
        }
        XCTAssertEqual(ConnectorKind.gmail.auth, .oauth)
        XCTAssertEqual(ConnectorKind.slack.auth, .oauth)
        XCTAssertFalse(ConnectorKind.gmail.feedsCalendar)
    }

    // MARK: - ConnectorStore

    @MainActor
    func testStoreEnableDisableRoundTrips() {
        let store = ConnectorStore(load: false)
        XCTAssertFalse(store.isEnabled(.appleCalendar))
        XCTAssertFalse(store.anyCalendarEnabled)

        store.setEnabled(.appleCalendar, true)
        XCTAssertTrue(store.isEnabled(.appleCalendar))
        XCTAssertTrue(store.anyCalendarEnabled)

        store.setEnabled(.slack, true)
        XCTAssertEqual(store.enabledOrdered.first, .slack) // featured order: slack before appleCalendar
        XCTAssertFalse(store.enabledOrdered.contains(.gmail))

        store.setEnabled(.appleCalendar, false)
        XCTAssertFalse(store.anyCalendarEnabled)
    }
}
