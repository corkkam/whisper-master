import XCTest

@testable import WhisperMaster

/// Pure, deterministic time parsing — `now` and the calendar are injected so the
/// assertions don't ride the wall clock.
final class RelativeTimeParserTests: XCTestCase {
    /// Fixed reference: Wednesday, 2026-07-15, 10:00 local (a fixed-offset zone so
    /// hour math is unambiguous regardless of the machine's timezone).
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }()

    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 7, day: 15, hour: 10, minute: 0))!
    }

    private func parse(_ phrase: String) -> Date? {
        RelativeTimeParser.parse(phrase, now: now, calendar: calendar)
    }

    private func comps(_ date: Date) -> DateComponents {
        calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    }

    func testRelativeOffsetHours() {
        let d = parse("in 2 hours")
        XCTAssertEqual(comps(d!).day, 15)
        XCTAssertEqual(comps(d!).hour, 12)
    }

    func testRelativeOffsetMinutesWithNumberWord() {
        let d = parse("in fifteen minutes")
        XCTAssertEqual(comps(d!).hour, 10)
        XCTAssertEqual(comps(d!).minute, 15)
    }

    func testClockTimeLaterToday() {
        let d = parse("at 5pm")
        XCTAssertEqual(comps(d!).day, 15)
        XCTAssertEqual(comps(d!).hour, 17)
        XCTAssertEqual(comps(d!).minute, 0)
    }

    func testClockTimeAlreadyPassedRollsToTomorrow() {
        // 9am is before the 10am `now`, so it means tomorrow.
        let d = parse("at 9am")
        XCTAssertEqual(comps(d!).day, 16)
        XCTAssertEqual(comps(d!).hour, 9)
    }

    func testTomorrowMorning() {
        let d = parse("tomorrow morning")
        XCTAssertEqual(comps(d!).day, 16)
        XCTAssertEqual(comps(d!).hour, 9)
    }

    func testTonight() {
        let d = parse("tonight")
        XCTAssertEqual(comps(d!).day, 15)
        XCTAssertEqual(comps(d!).hour, 20)
    }

    func testNoon() {
        let d = parse("at noon")
        XCTAssertEqual(comps(d!).day, 15)
        XCTAssertEqual(comps(d!).hour, 12)
    }

    func testWeekdayNextOccurrence() {
        // Next Monday from Wed the 15th is the 20th.
        let d = parse("monday at 9am")
        XCTAssertEqual(comps(d!).day, 20)
        XCTAssertEqual(comps(d!).hour, 9)
    }

    func testUnparseableReturnsNilSoTheAppAsks() {
        XCTAssertNil(parse("sometime"))
        XCTAssertNil(parse("whenever i get a chance"))
        XCTAssertNil(parse(""))
    }
}
