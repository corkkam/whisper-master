import XCTest

@testable import WhisperMaster

final class ReminderModelTests: XCTestCase {
    func testRepeatNextDue() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertNil(ReminderRepeat.none.nextDue(after: base))

        let daily = ReminderRepeat.daily.nextDue(after: base)
        XCTAssertEqual(daily, Calendar.current.date(byAdding: .day, value: 1, to: base))

        let weekly = ReminderRepeat.weekly.nextDue(after: base)
        XCTAssertEqual(weekly, Calendar.current.date(byAdding: .weekOfYear, value: 1, to: base))
    }

    func testSoundResolutionFallsBackToDefault() {
        XCTAssertEqual(ReminderSound.resolved("Glass"), "Glass")
        XCTAssertEqual(ReminderSound.resolved("NotARealSound"), ReminderSound.defaultName)
        XCTAssertTrue(ReminderSound.names.contains(ReminderSound.defaultName))
    }

    func testReminderInitSanitizesSound() {
        let r = ReminderItem(title: "x", soundName: "bogus")
        XCTAssertEqual(r.soundName, ReminderSound.defaultName)
    }

    func testIsDueBoundaries() {
        let now = Date()
        XCTAssertTrue(ReminderItem(dueDate: now.addingTimeInterval(-1)).isDue(asOf: now))
        XCTAssertFalse(ReminderItem(dueDate: now.addingTimeInterval(60)).isDue(asOf: now))
        XCTAssertFalse(ReminderItem(dueDate: now, isCompleted: true).isDue(asOf: now))
        XCTAssertFalse(ReminderItem(dueDate: now, deletedAt: now).isDue(asOf: now))
        // Fired for this occurrence → not due again.
        XCTAssertFalse(ReminderItem(dueDate: now.addingTimeInterval(-10), firedAt: now).isDue(asOf: now))
    }

    /// A reminder stored before `completedAt` existed must still decode — the
    /// synthesized conformance only stays safe here because the field is Optional.
    /// If this ever fails, the fix is to hand-write `ReminderItem`'s `Codable` the
    /// way `Note`'s is, not to make the new field non-optional.
    func testALegacyReminderWithNoCompletedAtStillDecodes() throws {
        let json = """
        {"id":"1EEE5C9E-1B1B-4A0A-9F42-000000000001","title":"legacy","body":"",
         "dueDate":700000000,"alertStyle":"notification","soundName":"Glass",
         "repeatRule":"none","isCompleted":true,
         "createdAt":699000000,"updatedAt":699500000}
        """
        let decoded = try JSONDecoder().decode(ReminderItem.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.title, "legacy")
        XCTAssertTrue(decoded.isCompleted)
        XCTAssertNil(decoded.completedAt)
        // With no stamp of its own it still sorts in the archive, by its last write.
        XCTAssertEqual(decoded.archivedAt, decoded.updatedAt)
    }

    func testIsRepeatingMatchesTheRepeatRule() {
        XCTAssertFalse(ReminderItem(repeatRule: .none).isRepeating)
        XCTAssertTrue(ReminderItem(repeatRule: .daily).isRepeating)
        XCTAssertTrue(ReminderItem(repeatRule: .weekly).isRepeating)
    }

    func testDisplayTitleFallbacks() {
        XCTAssertEqual(Note(title: "", body: "first line\nsecond").displayTitle, "first line")
        XCTAssertEqual(Note(title: "  ", body: "   ").displayTitle, "Untitled note")
        XCTAssertEqual(ReminderItem(title: "").displayTitle, "Reminder")
    }
}
