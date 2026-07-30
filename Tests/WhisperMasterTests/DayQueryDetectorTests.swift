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

    /// Auth method and capabilities moved off `ConnectorKind` onto its descriptor when
    /// a kind stopped being the unit of connection. The calendar kinds are the ones
    /// that read through EventKit, so they carry no credential.
    func testCalendarConnectorsAreSystemBackedAndProvideEvents() {
        for kind in [ConnectorKind.appleCalendar, .googleCalendar, .outlook] {
            let descriptor = ConnectorCatalog.descriptor(for: kind)
            XCTAssertEqual(descriptor.authKind, .none, "\(kind) should read via EventKit")
            XCTAssertTrue(descriptor.capabilities.contains(.events))
        }
        XCTAssertEqual(ConnectorCatalog.descriptor(for: .gmail).authKind, .staticSecret)
        XCTAssertEqual(ConnectorCatalog.descriptor(for: .slack).authKind, .staticSecret)
        XCTAssertFalse(ConnectorCatalog.descriptor(for: .gmail).capabilities.contains(.events))
    }
}
