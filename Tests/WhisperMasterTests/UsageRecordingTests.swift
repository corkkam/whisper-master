import XCTest

@testable import WhisperMaster

/// What each exit of the finalize contributes to usage, and what the stored file
/// survives. Both are regressions we've already paid for once: assistant captures
/// and empty results used to be missing from the dashboard entirely, and a
/// snapshot the decoder choked on used to be overwritten by the next dictation.
@MainActor
final class UsageRecordingTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-recording-\(UUID()).json")
    }

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-recording-\(UUID())", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func record(
        words: Int,
        app: String = "Notes",
        bundle: String = "com.apple.notes"
    ) -> DictationRecord {
        DictationRecord(
            timestamp: Date(),
            wordCount: words,
            durationSeconds: 10,
            appName: app,
            appBundleID: bundle,
            engineRawValue: "slidingWindow",
            fixes: .zero)
    }

    // MARK: - Every session is recorded, with the kind it turned out to be

    func testAnAssistantSessionIsRecordedAndStaysDistinguishable() {
        let store = UsageStore(fileURL: tempURL(), load: false)
        let session = DictationViewModel.usageRecord(
            kind: .assistant,
            transcript: "what's on my calendar today",
            duration: 30,
            appName: "Slack",
            appBundleID: "com.tinyspeck.slackmacgap",
            engineRawValue: "slidingWindow",
            fixes: .zero)
        store.record(session)

        XCTAssertEqual(session.wordCount, 5)
        XCTAssertEqual(session.kind, .assistant)
        // It reaches every headline number — a chord-armed capture is speaking time.
        XCTAssertEqual(store.totalDictations, 1)
        XCTAssertEqual(store.totalWords, 5)
        XCTAssertEqual(store.currentStreak, 1)
        // …while still being separable from text typed at the cursor.
        XCTAssertEqual(store.recent.last?.kind, .assistant)
    }

    func testAnEmptySessionIsRecordedWithNoWords() {
        let store = UsageStore(fileURL: tempURL(), load: false)
        let session = DictationViewModel.usageRecord(
            kind: .empty,
            transcript: "",
            duration: 4,
            appName: "Notes",
            appBundleID: "com.apple.notes",
            engineRawValue: "slidingWindow",
            fixes: .zero)
        store.record(session)

        XCTAssertEqual(session.wordCount, 0)
        // A miss counts as a session (it's worth inspecting) but adds no words.
        XCTAssertEqual(store.totalDictations, 1)
        XCTAssertEqual(store.totalWords, 0)
        XCTAssertEqual(store.recent.last?.kind, .empty)
    }

    func testAnOrdinaryDictationIsTaggedAsDictation() {
        let session = DictationViewModel.usageRecord(
            kind: .dictation,
            transcript: "three words here",
            duration: 6,
            appName: "Notes",
            appBundleID: "com.apple.notes",
            engineRawValue: "slidingWindow",
            fixes: FixCounts(wordsCorrected: 1, dictionary: 2))
        XCTAssertEqual(session.kind, .dictation)
        XCTAssertEqual(session.wordCount, 3)
        XCTAssertEqual(session.fixes, FixCounts(wordsCorrected: 1, dictionary: 2))
    }

    // MARK: - Forward-compatible decode

    func testASnapshotMissingNewerFieldsLoadsWithoutLosingAnything() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        // A file written by an older build: no `fixes`/`perApp` on the rollup, no
        // `kind` on the records, plus a key only a *newer* build knows about.
        let json = """
            {
              "rollups": {
                "2026-01-02": {
                  "day": "2026-01-02",
                  "words": 120,
                  "dictations": 3,
                  "durationSeconds": 90,
                  "somethingAddedLater": 7
                }
              },
              "recent": [
                {
                  "timestamp": "2026-01-02T10:00:00Z",
                  "wordCount": 100,
                  "durationSeconds": 60,
                  "appName": "Notes",
                  "appBundleID": "com.apple.notes",
                  "engineRawValue": "slidingWindow"
                },
                {
                  "timestamp": "2026-01-02T11:00:00Z",
                  "wordCount": 20,
                  "durationSeconds": 30,
                  "appName": "Notes",
                  "appBundleID": "com.apple.notes",
                  "engineRawValue": "slidingWindow",
                  "kind": "aKindFromTheFuture"
                }
              ],
              "dirtyDays": ["2026-01-02"]
            }
            """
        try json.write(to: url, atomically: true, encoding: .utf8)

        let store = UsageStore(fileURL: url)
        XCTAssertEqual(store.rollups["2026-01-02"]?.words, 120)
        XCTAssertEqual(store.rollups["2026-01-02"]?.dictations, 3)
        XCTAssertEqual(store.rollups["2026-01-02"]?.durationSeconds, 90)
        XCTAssertEqual(store.rollups["2026-01-02"]?.fixes, .zero)
        XCTAssertEqual(store.rollups["2026-01-02"]?.perApp, [:])
        XCTAssertEqual(store.recent.count, 2)
        XCTAssertEqual(store.dirtyDays, ["2026-01-02"])
        // An unknown kind degrades to plain dictation rather than failing the file.
        XCTAssertEqual(store.recent.map(\.kind), [.dictation, .dictation])

        // And the next record adds to that history instead of replacing it.
        store.record(record(words: 5))
        let reloaded = UsageStore(fileURL: url)
        XCTAssertEqual(reloaded.totalWords, 125)
        XCTAssertEqual(reloaded.totalDictations, 4)
        XCTAssertEqual(reloaded.recent.count, 3)
    }

    func testAnUnreadableFileIsNeverOverwrittenByTheNextRecord() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let garbage = "{ this is not a usage snapshot"
        try garbage.write(to: url, atomically: true, encoding: .utf8)

        let store = UsageStore(fileURL: url)
        XCTAssertEqual(store.totalDictations, 0, "nothing decoded, so nothing is loaded")

        store.record(record(words: 5))
        XCTAssertEqual(store.totalWords, 5, "the session still counts in memory")
        XCTAssertEqual(
            try String(contentsOf: url, encoding: .utf8), garbage,
            "the file may hold a whole history — one record must not replace it")
    }

    func testAnEmptyJsonObjectIsTreatedAsUnreadableRatherThanAsAnEmptySnapshot() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try "{}".write(to: url, atomically: true, encoding: .utf8)

        let store = UsageStore(fileURL: url)
        store.record(record(words: 5))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "{}")
    }

    // MARK: - Per-account attribution

    func testARecordGoesToTheAccountThatSpokeItEvenAfterASignIn() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileForUser: (String) -> URL = { dir.appendingPathComponent("\($0).json") }
        let store = UsageStore(fileURL: tempURL(), load: false, fileURLForUser: fileForUser)

        store.activate(userID: "user_a")
        store.record(record(words: 10), owner: "user_a")
        XCTAssertEqual(store.totalWords, 10)

        // Someone else signs in while the finalize is still running.
        store.activate(userID: "user_b")
        store.record(record(words: 7), owner: "user_a")
        XCTAssertEqual(store.totalWords, 0, "B's dashboard must never show A's words")

        let reloadedA = UsageStore(fileURL: fileForUser("user_a"))
        XCTAssertEqual(reloadedA.totalWords, 17, "A's own file gets the words A spoke")
        XCTAssertEqual(reloadedA.totalDictations, 2)
    }

    // MARK: - Sync only clears what it actually sent

    func testADayThatChangedDuringThePushStaysDirty() {
        let store = UsageStore(fileURL: tempURL(), load: false)
        let client = UsageSyncClient(store: store, identity: { nil }, endpoint: nil)
        let today = StreakCalculator.dayKey(for: Date())

        store.record(record(words: 5))
        let posted = store.rollups(for: [today])
        // A dictation lands while the request is in flight (same actor, so the
        // finalize interleaves) — its words were never in the payload.
        store.record(record(words: 3))

        XCTAssertEqual(client.daysStillMatching(posted, of: [today]), [])
        XCTAssertEqual(
            client.daysStillMatching(store.rollups(for: [today]), of: [today]), [today],
            "an untouched day is cleared as before")
        // A day with no rollup at all can't pin the dirty set open.
        XCTAssertEqual(client.daysStillMatching([], of: ["1999-01-01"]), ["1999-01-01"])
    }

    func testARecordFromASessionWithNoAccountIsDroppedNotMisattributed() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = UsageStore(
            fileURL: tempURL(), load: false,
            fileURLForUser: { dir.appendingPathComponent("\($0).json") })

        store.activate(userID: "user_a")
        store.record(record(words: 9), owner: nil)
        XCTAssertEqual(store.totalWords, 0)
        XCTAssertEqual(store.totalDictations, 0)
    }
}
