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

    func testDisplayTitleFallbacks() {
        XCTAssertEqual(Note(title: "", body: "first line\nsecond").displayTitle, "first line")
        XCTAssertEqual(Note(title: "  ", body: "   ").displayTitle, "Untitled note")
        XCTAssertEqual(ReminderItem(title: "").displayTitle, "Reminder")
    }
}
