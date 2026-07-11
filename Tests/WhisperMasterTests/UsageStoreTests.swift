import XCTest

@testable import WhisperMaster

@MainActor
final class UsageStoreTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-test-\(UUID()).json")
    }

    private func record(
        words: Int,
        duration: Double = 10,
        app: String,
        bundle: String,
        timestamp: Date = Date(),
        fixes: FixCounts = .zero
    ) -> DictationRecord {
        DictationRecord(
            timestamp: timestamp,
            wordCount: words,
            durationSeconds: duration,
            appName: app,
            appBundleID: bundle,
            engineRawValue: "slidingWindow",
            fixes: fixes)
    }

    func testPerUserFileURLsAreDistinctAndSanitized() {
        let a = UsageStore.fileURL(forUserID: "user_ABC123")
        let b = UsageStore.fileURL(forUserID: "user_XYZ789")
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a.lastPathComponent, "user_ABC123.json")
        // Path-hostile characters are replaced so an id can never escape the dir.
        let dirty = UsageStore.fileURL(forUserID: "../../etc/passwd")
        XCTAssertEqual(dirty.lastPathComponent, "______etc_passwd.json")
        XCTAssertFalse(dirty.path.contains(".."))
    }

    func testPersistenceCanBeDisabled() {
        let url = tempURL()
        let store = UsageStore(fileURL: url, load: false)
        store.persistenceEnabled = false
        store.record(record(words: 10, app: "Notes", bundle: "com.apple.notes"))
        XCTAssertEqual(store.totalWords, 10)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testTotalsAcrossTwoApps() {
        let store = UsageStore(fileURL: tempURL(), load: false)
        store.record(record(words: 10, app: "Notes", bundle: "com.apple.notes",
                             fixes: FixCounts(wordsCorrected: 2, dictionary: 1)))
        store.record(record(words: 30, app: "Notes", bundle: "com.apple.notes",
                             fixes: FixCounts(wordsCorrected: 1, dictionary: 0)))
        store.record(record(words: 20, app: "Safari", bundle: "com.apple.safari",
                             fixes: FixCounts(wordsCorrected: 0, dictionary: 3)))

        XCTAssertEqual(store.totalWords, 60)
        XCTAssertEqual(store.totalDictations, 3)
        XCTAssertEqual(store.totalFixes.wordsCorrected, 3)
        XCTAssertEqual(store.totalFixes.dictionary, 4)
        XCTAssertEqual(store.totalFixes.total, 7)
        XCTAssertEqual(store.wordsToday, 60)
        XCTAssertEqual(store.totalAppsUsed, 2)
    }

    func testTopAppsOrderingAndShare() {
        let store = UsageStore(fileURL: tempURL(), load: false)
        store.record(record(words: 10, app: "Notes", bundle: "com.apple.notes"))
        store.record(record(words: 30, app: "Notes", bundle: "com.apple.notes"))
        store.record(record(words: 20, app: "Safari", bundle: "com.apple.safari"))

        let top = store.topApps()
        XCTAssertEqual(top.count, 2)
        // Ordered by words descending: Notes (40) then Safari (20).
        XCTAssertEqual(top[0].bundleID, "com.apple.notes")
        XCTAssertEqual(top[0].usage.words, 40)
        XCTAssertEqual(top[1].bundleID, "com.apple.safari")
        XCTAssertEqual(top[1].usage.words, 20)
        // Shares of the two covered apps sum to ~1.0 (they cover every word).
        XCTAssertEqual(top[0].share + top[1].share, 1.0, accuracy: 0.0001)
        XCTAssertEqual(top[0].share, 40.0 / 60.0, accuracy: 0.0001)
    }

    func testDirtyDaysTrackedAndCleared() {
        let store = UsageStore(fileURL: tempURL(), load: false)
        store.record(record(words: 5, app: "Notes", bundle: "com.apple.notes"))
        let todayKey = StreakCalculator.dayKey(for: Date())
        XCTAssertTrue(store.dirtyDays.contains(todayKey))

        store.clearDirty([todayKey])
        XCTAssertFalse(store.dirtyDays.contains(todayKey))
    }

    func testPersistenceRoundTrip() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = UsageStore(fileURL: url)  // load:true default; record persists synchronously
        store.record(record(words: 42, app: "Notes", bundle: "com.apple.notes",
                             fixes: FixCounts(wordsCorrected: 3, dictionary: 2)))

        let reloaded = UsageStore(fileURL: url)  // second instance reads from disk
        XCTAssertEqual(reloaded.totalWords, 42)
        XCTAssertEqual(reloaded.totalDictations, 1)
        XCTAssertEqual(reloaded.totalFixes, FixCounts(wordsCorrected: 3, dictionary: 2))
        let todayKey = StreakCalculator.dayKey(for: Date())
        XCTAssertEqual(reloaded.rollups[todayKey]?.words, 42)
    }

    func testRecentWpm() {
        let store = UsageStore(fileURL: tempURL(), load: false)
        // 100 words in 60 s → 100 wpm.
        store.record(record(words: 100, duration: 60, app: "Notes", bundle: "com.apple.notes"))
        XCTAssertEqual(store.recentWpm, 100)
    }

    func testSubSecondDictationContributesNothingToWpm() {
        let store = UsageStore(fileURL: tempURL(), load: false)
        // A 0.3 s clip is excluded from the wpm window (and its own wpm is 0).
        store.record(record(words: 2, duration: 0.3, app: "Notes", bundle: "com.apple.notes"))
        XCTAssertEqual(store.recentWpm, 0)
    }

    func testWordsOnDayKey() {
        let store = UsageStore(fileURL: tempURL(), load: false)
        store.record(record(words: 15, app: "Notes", bundle: "com.apple.notes"))
        let todayKey = StreakCalculator.dayKey(for: Date())
        XCTAssertEqual(store.words(onDayKey: todayKey), 15)
        XCTAssertEqual(store.words(onDayKey: "1999-01-01"), 0)
    }

    func testStreaksReflectTodayActivity() {
        let store = UsageStore(fileURL: tempURL(), load: false)
        store.record(record(words: 5, app: "Notes", bundle: "com.apple.notes"))
        XCTAssertEqual(store.currentStreak, 1)
        XCTAssertEqual(store.longestStreak, 1)
    }
}
