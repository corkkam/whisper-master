import AVFoundation
import XCTest

@testable import WhisperMaster

final class MeetingTranscriptTests: XCTestCase {
    func testOnlyNewConfirmedWordsBecomeASegment() {
        var transcript = MeetingTranscript()
        transcript.ingest(confirmed: "hello everyone", from: .others, atMs: 12_000)
        transcript.ingest(confirmed: "hello everyone", from: .others, atMs: 13_000)
        transcript.ingest(confirmed: "hello everyone thanks for joining", from: .others, atMs: 24_000)
        XCTAssertEqual(transcript.segments.map(\.text), ["hello everyone", "thanks for joining"])
    }

    func testEachTrackIsDiffedOnItsOwn() {
        var transcript = MeetingTranscript()
        transcript.ingest(confirmed: "can you hear me", from: .me, atMs: 11_000)
        transcript.ingest(confirmed: "yes loud and clear", from: .others, atMs: 12_000)
        transcript.ingest(confirmed: "can you hear me great let us start", from: .me, atMs: 23_000)
        XCTAssertEqual(transcript.segments.map(\.text),
                       ["can you hear me", "yes loud and clear", "great let us start"])
    }

    func testSpeakerLeakIntoTheMicIsDropped() {
        var transcript = MeetingTranscript()
        transcript.ingest(confirmed: "the launch moves to next friday", from: .others, atMs: 30_000)
        // Laptop speakers: the mic hears the same sentence a window later.
        transcript.ingest(confirmed: "the launch moves to next friday", from: .me, atMs: 40_000)
        transcript.ingest(confirmed: "the launch moves to next friday okay that works for me", from: .me, atMs: 52_000)
        XCTAssertEqual(transcript.cleanedSegments.map(\.text),
                       ["the launch moves to next friday", "okay that works for me"])
    }

    func testTheSameWordsLongAfterAreNotEcho() {
        var transcript = MeetingTranscript()
        transcript.ingest(confirmed: "let us ship it on friday", from: .others, atMs: 10_000)
        transcript.ingest(confirmed: "let us ship it on friday", from: .me, atMs: 300_000)
        XCTAssertEqual(transcript.cleanedSegments.count, 2)
    }

    func testRenderedJoinsTurnsAndLabelsSpeakers() {
        var transcript = MeetingTranscript()
        transcript.ingest(confirmed: "first part", from: .others, atMs: 5_000)
        transcript.ingest(confirmed: "first part second part", from: .others, atMs: 16_000)
        transcript.ingest(confirmed: "my answer", from: .me, atMs: 75_000)
        XCTAssertEqual(transcript.rendered(),
                       "[00:05] Others: first part second part\n\n[01:15] You: my answer")
        XCTAssertEqual(transcript.rendered(after: 20_000), "[01:15] You: my answer")
    }

    func testTimestampsPastAnHourShowHours() {
        XCTAssertEqual(MeetingTranscript.timestamp(3_725_000), "1:02:05")
    }
}

final class MeetingNotesGeneratorTests: XCTestCase {
    func testChunksSplitOnTurnsAndCapLongTurns() {
        let turn = { (n: Int) in (0..<n).map { "w\($0)" }.joined(separator: " ") }
        let transcript = [turn(400), turn(400), turn(1500)].joined(separator: "\n\n")
        let chunks = MeetingNotesGenerator.chunks(transcript, maxWords: 700)
        XCTAssertEqual(chunks.map { $0.split(whereSeparator: \.isWhitespace).count }, [400, 400, 700, 700, 100])
    }

    func testBulletsAreNormalisedAndEmptyOnesDropped() {
        XCTAssertEqual(MeetingNotesGenerator.bullets(in: "Here you go:\n* one\n• two\n- \n-three\n- four"),
                       ["- one", "- two", "- four"])
    }

    func testFinalNotesMapThenReduceAndKeepOwnNotesVerbatim() async {
        let calls = CallLog()
        let generator = MeetingNotesGenerator { user, system, _ in
            await calls.record(system)
            if system == MeetingNotesGenerator.reduceSystem { return "## Summary\nShipped." }
            return "- point from \(user.prefix(6))"
        }
        let transcript = (0..<3).map { "[00:0\($0)] Others: " + String(repeating: "word ", count: 500) }
            .joined(separator: "\n\n")
        let notes = await generator.finalNotes(transcript: transcript, ownNotes: "call Priya")
        XCTAssertEqual(notes, "## Summary\nShipped.\n\n## My notes\ncall Priya")
        let systems = await calls.systems
        XCTAssertEqual(systems.filter { $0 == MeetingNotesGenerator.chunkSystem }.count, 3)
        XCTAssertEqual(systems.last, MeetingNotesGenerator.reduceSystem)
    }

    func testAFailedReduceFallsBackToTheMapBullets() async {
        let generator = MeetingNotesGenerator { _, system, _ in
            system == MeetingNotesGenerator.reduceSystem ? nil : "- decided to ship"
        }
        let notes = await generator.finalNotes(transcript: "[00:01] You: we ship", ownNotes: "")
        XCTAssertEqual(notes, "## Key points\n- decided to ship")
    }

    func testNoModelOutputMeansNoNotes() async {
        let generator = MeetingNotesGenerator { _, _, _ in nil }
        let notes = await generator.finalNotes(transcript: "[00:01] You: hi", ownNotes: "")
        XCTAssertNil(notes)
    }
}

private actor CallLog {
    private(set) var systems: [String] = []
    func record(_ system: String) { systems.append(system) }
}

final class MeetingAudioMixTests: XCTestCase {
    /// Two tracks of different length mix into one AAC file as long as the longer
    /// one, and the file plays back as 16 kHz mono.
    func testMixSumsTracksIntoOneFileAsLongAsTheLongest() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        func track(_ name: String, seconds: Double, value: Float) throws -> URL {
            let url = dir.appendingPathComponent(name)
            let file = try AVAudioFile(forWriting: url, settings: MonoResampler.format.settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            let frames = AVAudioFrameCount(seconds * MonoResampler.sampleRate)
            let buffer = AVAudioPCMBuffer(pcmFormat: MonoResampler.format, frameCapacity: frames)!
            buffer.frameLength = frames
            for i in 0..<Int(frames) { buffer.floatChannelData![0][i] = value * sin(Float(i) / 8) }
            try file.write(from: buffer)
            return url
        }
        let me = try track("me.caf", seconds: 1.5, value: 0.3)
        let others = try track("others.caf", seconds: 2.5, value: 0.3)
        let output = dir.appendingPathComponent("mix.m4a")

        let frames = try MeetingAudioRecorder.mix([me, others], to: output)
        XCTAssertEqual(frames, 40_000)
        let mixed = try AVAudioFile(forReading: output)
        XCTAssertEqual(mixed.fileFormat.channelCount, 1)
        XCTAssertEqual(mixed.fileFormat.sampleRate, 16_000)
        // AAC adds priming frames; the length is within a few packets.
        XCTAssertEqual(Double(mixed.length), 40_000, accuracy: 4_096)
    }
}
