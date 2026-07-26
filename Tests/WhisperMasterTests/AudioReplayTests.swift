import AVFoundation
import FluidAudio
import XCTest

@testable import WhisperMaster

/// Replays recorded audio through the real streaming transcriber so behavior can
/// be reproduced deterministically instead of by re-recording each time. Feeding
/// a file reproduces live streaming exactly — windowing keys off absolute sample
/// position.
///
/// Reference recordings live in `Tests/WhisperMasterTests/Fixtures/audio/`
/// (committed); ad-hoc local ones can be dropped in `.context/test-audio/`.
/// Results are written to `.context/test-audio/`. Skips when no recordings exist.
///     swift test --filter AudioReplayTests
final class AudioReplayTests: XCTestCase {
    private let vocabulary = ["Parakeet", "RAG: rack, rag", "Lyzr: laser, lizer", "NVIDIA"]

    /// Full app pipeline: raw ASR → filler removal → glossary replacement.
    func testReplayRecordedParagraphs() async throws {
        let wavs = try recordings()

        let transcriber = FluidAudioStreamingTranscriber()
        try await transcriber.prepareModels { _ in }

        var report = "# Replay results (raw → filler → vocabulary)\n\n"
        for url in wavs {
            let name = url.lastPathComponent
            let raw = try await replay(url: url, through: transcriber)
            let filtered = FillerWordFilter.clean(raw)
            let final = VocabularyPostProcessor.apply(filtered, glossary: vocabulary)
            report += "## \(name)\n"
            report += "- **raw**   (\(wordCount(raw)) words): \(raw)\n"
            report += "- **final** (\(wordCount(final)) words): \(final)\n\n"
            print("[replay] \(name): raw=\(wordCount(raw))w  final=\(wordCount(final))w")
        }
        writeResults(report, to: "results.md")
    }

    /// The notch's live text comes from the transcriber's **preview** track, and
    /// this is why: the accurate track decodes nothing until it holds
    /// `chunkSeconds + rightContextSeconds` of audio — 13 s as shipped — which is
    /// longer than a typical dictation, so the notch used to stay empty right up
    /// until the key came up.
    ///
    /// Replays a clip far shorter than that floor **in real time** (the fast
    /// as-quick-as-possible feed the other benches use would race the decoders and
    /// prove nothing about latency) and asserts the split *while audio is still
    /// arriving*: the accurate track has streamed nothing, the preview track has
    /// streamed real words, and `stop()` still returns the accurate transcript.
    ///
    /// The accurate track does emit exactly once for a clip this short — but only
    /// from `flushRemaining()` inside `finish()`, i.e. after the key comes up,
    /// which is precisely the "transcript shows up at the very end" complaint. So
    /// the counts are snapshotted *before* `stop()`.
    ///
    /// If someone removes the preview track, this is the test that says the notch
    /// went quiet again.
    func testPreviewTrackStreamsTextOnAClipTooShortForTheAccurateTrack() async throws {
        let floorSeconds = 13.0  // chunkSeconds (11) + rightContextSeconds (2)
        let short = try recordings().first { duration(of: $0) < floorSeconds - 3 }
        try XCTSkipIf(short == nil, "No recording shorter than \(floorSeconds - 3)s to test with")
        let url = short!

        let transcriber = FluidAudioStreamingTranscriber()
        try await transcriber.prepareModels { _ in }

        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let chunkSeconds = 0.1
        let chunkFrames = AVAudioFrameCount(format.sampleRate * chunkSeconds)

        let tally = StreamTally()
        try await transcriber.start { tally.record($0) }
        while file.framePosition < file.length {
            let remaining = AVAudioFrameCount(file.length - file.framePosition)
            let n = min(chunkFrames, remaining)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n) else { break }
            try file.read(into: buffer, frameCount: n)
            try await transcriber.append(buffer)
            // Real-time pacing: this is a latency test, so the audio has to arrive
            // at the speed a microphone delivers it.
            try await Task.sleep(nanoseconds: UInt64(chunkSeconds * 1_000_000_000))
        }

        // Snapshot before stop() — after it, the accurate track's flush lands too.
        let previewWhileSpeaking = tally.previewTexts
        let accurateWhileSpeaking = tally.accurateTexts

        let final = try await transcriber.stop()

        XCTAssertFalse(
            previewWhileSpeaking.isEmpty,
            "The preview track streamed nothing during a \(duration(of: url))s clip — the notch would stay empty while speaking")
        XCTAssertTrue(
            accurateWhileSpeaking.isEmpty,
            "The accurate track unexpectedly streamed mid-dictation on a clip under its \(floorSeconds)s floor: \(accurateWhileSpeaking)")
        XCTAssertFalse(
            final.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "The accurate track must still deliver the real transcript on stop()")

        print("[preview] \(url.lastPathComponent) (\(duration(of: url))s): "
            + "\(previewWhileSpeaking.count) preview updates while speaking, "
            + "\(accurateWhileSpeaking.count) accurate; "
            + "preview=\"\(previewWhileSpeaking.last ?? "")\" final=\"\(final)\"")
    }

    /// Thread-safe split of streaming updates by track — the transcriber calls the
    /// handler from its own tasks.
    private final class StreamTally: @unchecked Sendable {
        private let lock = NSLock()
        private var preview: [String] = []
        private var accurate: [String] = []

        var previewTexts: [String] { lock.withLock { preview } }
        var accurateTexts: [String] { lock.withLock { accurate } }

        func record(_ update: StreamingTranscriptUpdate) {
            let text = TranscriptMerger
                .bestEffort(confirmed: update.confirmedText, volatile: update.partialText)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            lock.withLock {
                if update.isPreview { preview.append(text) } else { accurate.append(text) }
            }
        }
    }

    private func duration(of url: URL) -> Double {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(file.length) / file.fileFormat.sampleRate
    }

    /// A/B the multilingual v3 model against the English-only v2 model on the
    /// same recordings, to decide whether English dictation transcribes cleaner
    /// on v2. Raw ASR only — no post-processing — so it's a fair engine compare.
    func testParakeetV2vsV3() async throws {
        let wavs = try recordings()

        let v3 = FluidAudioStreamingTranscriber(modelVersion: .v3)
        try await v3.prepareModels { _ in }
        let v2 = FluidAudioStreamingTranscriber(modelVersion: .v2)
        try await v2.prepareModels { _ in }

        var report = "# Parakeet v3 (multilingual) vs v2 (English) — raw ASR\n\n"
        for url in wavs {
            let name = url.lastPathComponent
            let rawV3 = try await replay(url: url, through: v3)
            let rawV2 = try await replay(url: url, through: v2)
            report += "## \(name)\n"
            report += "- **v3** (\(wordCount(rawV3)) words): \(rawV3)\n"
            report += "- **v2** (\(wordCount(rawV2)) words): \(rawV2)\n\n"
            print("[v2v3] \(name): v3=\(wordCount(rawV3))w  v2=\(wordCount(rawV2))w")
        }
        writeResults(report, to: "results-v2-vs-v3.md")
    }

    // MARK: - Helpers

    private func recordings() throws -> [URL] {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let searchDirs = [
            root.appendingPathComponent("Tests/WhisperMasterTests/Fixtures/audio"),
            root.appendingPathComponent(".context/test-audio"),
        ]
        let audioExtensions: Set<String> = ["wav", "m4a", "caf", "mp3", "aiff", "aif"]
        var byName: [String: URL] = [:]
        for dir in searchDirs {
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for file in files where audioExtensions.contains(file.pathExtension.lowercased()) {
                if byName[file.lastPathComponent] == nil { byName[file.lastPathComponent] = file }
            }
        }
        let wavs = byName.values.sorted { $0.lastPathComponent < $1.lastPathComponent }
        try XCTSkipIf(wavs.isEmpty, "No recordings found — see Fixtures/audio/paragraphs.md")
        return wavs
    }

    /// Feed the file in ~100 ms chunks, the way the live mic tap does, rather
    /// than one giant buffer — so boundary behavior (final-window handling)
    /// matches real dictation instead of a one-shot dump.
    private func replay(url: URL, through transcriber: FluidAudioStreamingTranscriber) async throws -> String {
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0 else { throw ReplayError.unreadable(url.lastPathComponent) }
        let format = file.processingFormat
        let chunkFrames = AVAudioFrameCount(format.sampleRate * 0.1)

        try await transcriber.start { _ in }
        while file.framePosition < file.length {
            let remaining = AVAudioFrameCount(file.length - file.framePosition)
            let n = min(chunkFrames, remaining)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n) else { break }
            try file.read(into: buffer, frameCount: n)
            try await transcriber.append(buffer)
        }
        return try await transcriber.stop()
    }

    private func writeResults(_ report: String, to filename: String) {
        let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".context/test-audio")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appendingPathComponent(filename)
        try? report.write(to: out, atomically: true, encoding: .utf8)
        print("[replay] wrote \(out.path)\n\(report)")
    }

    private func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    private enum ReplayError: Error { case unreadable(String) }
}
