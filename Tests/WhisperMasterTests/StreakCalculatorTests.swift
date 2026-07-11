import XCTest

@testable import WhisperMaster

final class StreakCalculatorTests: XCTestCase {
    /// A fixed UTC gregorian calendar so keys and streak math are deterministic.
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// A date at noon UTC for the given y/m/d (noon avoids any DST edge worry).
    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var comps = DateComponents()
        comps.year = y
        comps.month = m
        comps.day = d
        comps.hour = 12
        return cal.date(from: comps)!
    }

    private func key(_ y: Int, _ m: Int, _ d: Int) -> String {
        StreakCalculator.dayKey(for: date(y, m, d), calendar: cal)
    }

    // MARK: - dayKey

    func testDayKeyFormat() {
        XCTAssertEqual(StreakCalculator.dayKey(for: date(2026, 7, 4), calendar: cal), "2026-07-04")
        XCTAssertEqual(StreakCalculator.dayKey(for: date(2026, 12, 31), calendar: cal), "2026-12-31")
    }

    // MARK: - currentStreak

    func testEmptySetIsZero() {
        XCTAssertEqual(StreakCalculator.currentStreak(activeDays: [], today: date(2026, 7, 10), calendar: cal), 0)
        XCTAssertEqual(StreakCalculator.longestStreak(activeDays: [], calendar: cal), 0)
    }

    func testCurrentStreakTodayOnly() {
        let today = date(2026, 7, 10)
        let active: Set<String> = [key(2026, 7, 10)]
        XCTAssertEqual(StreakCalculator.currentStreak(activeDays: active, today: today, calendar: cal), 1)
    }

    func testCurrentStreakThreeConsecutiveDays() {
        let today = date(2026, 7, 10)
        let active: Set<String> = [key(2026, 7, 10), key(2026, 7, 9), key(2026, 7, 8)]
        XCTAssertEqual(StreakCalculator.currentStreak(activeDays: active, today: today, calendar: cal), 3)
    }

    func testCurrentStreakBrokenByGap() {
        // Active today + a run two days back, with yesterday missing → only today counts.
        let today = date(2026, 7, 10)
        let active: Set<String> = [key(2026, 7, 10), key(2026, 7, 8), key(2026, 7, 7)]
        XCTAssertEqual(StreakCalculator.currentStreak(activeDays: active, today: today, calendar: cal), 1)
    }

    func testCurrentStreakStaysAliveWhenActiveYesterdayNotToday() {
        // Active yesterday but not today — the streak hasn't lapsed yet.
        let today = date(2026, 7, 10)
        let active: Set<String> = [key(2026, 7, 9), key(2026, 7, 8)]
        XCTAssertEqual(StreakCalculator.currentStreak(activeDays: active, today: today, calendar: cal), 2)
    }

    func testCurrentStreakZeroWhenOnlyThreeDaysAgo() {
        // Gap on both yesterday and today → streak has lapsed.
        let today = date(2026, 7, 10)
        let active: Set<String> = [key(2026, 7, 7)]
        XCTAssertEqual(StreakCalculator.currentStreak(activeDays: active, today: today, calendar: cal), 0)
    }

    // MARK: - longestStreak

    func testLongestStreakSingleDay() {
        let active: Set<String> = [key(2026, 7, 4)]
        XCTAssertEqual(StreakCalculator.longestStreak(activeDays: active, calendar: cal), 1)
    }

    func testLongestStreakRunOfFiveSurroundedByGaps() {
        let active: Set<String> = [
            key(2026, 7, 1), // isolated, gap after
            key(2026, 7, 10), key(2026, 7, 11), key(2026, 7, 12), key(2026, 7, 13), key(2026, 7, 14), // run of 5
            key(2026, 7, 20), // isolated
        ]
        XCTAssertEqual(StreakCalculator.longestStreak(activeDays: active, calendar: cal), 5)
    }

    func testLongestStreakTwoSeparateRunsPicksLonger() {
        let active: Set<String> = [
            key(2026, 7, 1), key(2026, 7, 2), key(2026, 7, 3), // run of 3
            key(2026, 7, 10), key(2026, 7, 11), key(2026, 7, 12), key(2026, 7, 13), // run of 4
        ]
        XCTAssertEqual(StreakCalculator.longestStreak(activeDays: active, calendar: cal), 4)
    }
}
