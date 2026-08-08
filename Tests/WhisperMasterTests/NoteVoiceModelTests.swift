import XCTest

@testable import WhisperMaster

/// Covers the note fields added for the sticky canvas — pinning, the spoken
/// transcript, the recording, and the stored tint — plus the pin ordering the canvas
/// and the notch band both read.
@MainActor
final class NoteVoiceModelTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("notes-voice-test-\(UUID()).json")
    }

    private func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    // MARK: - Backward-compatible decoding

    /// **The regression this file exists for.** Notes written before pinning,
    /// transcripts and audio existed carry none of those keys, and the synthesized
    /// `Codable` conformance treats a missing non-optional key as a decode error.
    /// `NotesStore.loadFromDisk` swallows a throw, so getting this wrong doesn't
    /// crash — it silently empties every existing user's notes.
    func testALegacyNoteWithNoneOfTheNewKeysStillDecodes() throws {
        let legacy = """
        {
          "id": "3F2504E0-4F89-11D3-9A0C-0305E82C3301",
          "title": "Wifi",
          "body": "basalt-harbour-19",
          "createdAt": "2026-01-02T03:04:05Z",
          "updatedAt": "2026-01-02T03:04:05Z"
        }
        """
        let note = try decoder().decode(Note.self, from: Data(legacy.utf8))

        XCTAssertEqual(note.title, "Wifi")
        XCTAssertEqual(note.body, "basalt-harbour-19")
        XCTAssertFalse(note.isPinned)
        XCTAssertNil(note.transcript)
        XCTAssertNil(note.audio)
        XCTAssertFalse(note.hasAudio)
        // Absent tint falls back to the deterministic per-id one, not a crash or 0.
        XCTAssertEqual(note.colorIndex, Note.defaultColorIndex(for: note.id))
    }

    func testAFullNoteRoundTrips() throws {
        // Whole-second dates on purpose: the store encodes `.iso8601`, which carries
        // no fractional seconds, so a `Date()` here would come back a few
        // microseconds off and fail an equality check for a reason that has nothing
        // to do with the fields under test.
        let stamp = Date(timeIntervalSince1970: 1_780_000_000)
        let original = Note(
            title: "Parakeet",
            body: "Preview track is 1.5s.",
            createdAt: stamp,
            updatedAt: stamp,
            isPinned: true,
            transcript: "note that the preview track is one point five seconds",
            audio: NoteAudio(fileName: "abc.wav", durationMs: 7_400),
            colorIndex: 3)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoded = try decoder().decode(Note.self, from: try encoder.encode(original))

        XCTAssertEqual(decoded, original)
        XCTAssertTrue(decoded.isPinned)
        XCTAssertEqual(decoded.audio?.durationMs, 7_400)
        XCTAssertEqual(decoded.colorIndex, 3)
    }

    // MARK: - Stored tint

    /// The tint must be stable across processes, which is exactly what
    /// `UUID.hashValue` is not — it's seeded per process, so a hash-derived colour
    /// would reshuffle the whole canvas on every launch.
    func testColorIndexIsDerivedFromTheIDAndStaysInRange() {
        for _ in 0..<200 {
            let id = UUID()
            let index = Note.defaultColorIndex(for: id)
            XCTAssertTrue((0..<Note.paletteSize).contains(index))
            // Same id, same answer — twice, and via a note built from it.
            XCTAssertEqual(index, Note.defaultColorIndex(for: id))
            XCTAssertEqual(Note(id: id).colorIndex, index)
        }
    }

    // MARK: - Transcript vs body

    func testTranscriptIsHiddenWhenItSaysNothingTheBodyDoesnt() {
        // The assistant often leaves the body identical to the capture; showing the
        // same sentence twice under "what I heard" reads as a bug.
        let same = Note(body: "Buy oat milk", transcript: "buy oat milk")
        XCTAssertNil(same.distinctTranscript)

        let differs = Note(body: "Buy oat milk", transcript: "take a note to buy oat milk")
        XCTAssertEqual(differs.distinctTranscript, "take a note to buy oat milk")

        XCTAssertNil(Note(body: "x", transcript: "   ").distinctTranscript)
        XCTAssertNil(Note(body: "x").distinctTranscript)
    }

    // MARK: - Pin ordering

    func testPinnedNotesLeadTheCanvasAheadOfMoreRecentUnpinnedOnes() {
        let store = NotesStore(fileURL: tempURL(), load: false)
        store.persistenceEnabled = false

        let pinned = Note(title: "Pinned", isPinned: true)
        store.upsertNote(pinned)
        // Upserted after, so it is strictly newer by `updatedAt` — recency alone
        // would put it first, and pinning has to beat recency.
        store.upsertNote(Note(title: "Newer"))

        XCTAssertEqual(store.visibleNotes.first?.title, "Pinned")
        XCTAssertEqual(store.pinnedNotes.map(\.title), ["Pinned"])
        XCTAssertEqual(store.unpinnedNotes.map(\.title), ["Newer"])
    }

    func testSetPinnedTogglesAndMarksDirtyForSync() {
        let store = NotesStore(fileURL: tempURL(), load: false)
        store.persistenceEnabled = false
        let note = Note(title: "n")
        store.upsertNote(note)
        store.clearDirty(store.dirtyIDs)

        store.setPinned(note.id, true)
        XCTAssertTrue(store.visibleNotes[0].isPinned)
        XCTAssertTrue(store.dirtyIDs.contains(note.id), "a pin has to sync like any other edit")

        store.setPinned(note.id, false)
        XCTAssertFalse(store.visibleNotes[0].isPinned)
    }

    /// A deleted note must not keep haunting the canvas or the notch band if it is
    /// ever restored by a merge — and its recording is the biggest thing the app
    /// writes, so it goes rather than lingering behind a tombstone.
    func testDeletingANoteUnpinsIt() {
        let store = NotesStore(fileURL: tempURL(), load: false)
        store.persistenceEnabled = false
        let note = Note(title: "n", isPinned: true)
        store.upsertNote(note)

        store.deleteNote(note.id)

        XCTAssertTrue(store.pinnedNotes.isEmpty)
        XCTAssertTrue(store.visibleNotes.isEmpty)
        let stored = store.notes.first { $0.id == note.id }
        XCTAssertNotNil(stored?.deletedAt, "the row stays as a sync tombstone")
        XCTAssertFalse(stored?.isPinned ?? true)
        XCTAssertNil(stored?.audio)
    }

    // MARK: - Duration formatting

    func testRecordingDurationReadsAsMinutesAndSeconds() {
        XCTAssertEqual(StickyNoteCard.duration(0), "0:00")
        XCTAssertEqual(StickyNoteCard.duration(7_400), "0:07")
        XCTAssertEqual(StickyNoteCard.duration(62_000), "1:02")
        XCTAssertEqual(StickyNoteCard.duration(600_000), "10:00")
        // A negative can only come from bad data; it must not format as "-1:-1".
        XCTAssertEqual(StickyNoteCard.duration(-5), "0:00")
    }

    // MARK: - Palette bounds

    /// A note pulled in from a newer build could carry an index past the end of this
    /// build's palette. It has to render in a real colour rather than trap.
    func testStickyPaletteClampsAnOutOfRangeIndex() {
        XCTAssertEqual(Theme.Sticky.fills.count, Note.paletteSize)
        XCTAssertEqual(Theme.Sticky.strokes.count, Note.paletteSize)
        for index in [-9, -1, 0, 4, 5, 99] {
            XCTAssertNotNil(Theme.Sticky.fill(index))
            XCTAssertNotNil(Theme.Sticky.stroke(index))
        }
    }
}
