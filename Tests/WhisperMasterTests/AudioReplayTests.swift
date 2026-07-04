import AVFoundation
import XCTest

@testable import WhisperMaster

/// Replays recorded WAV files through the real streaming transcriber so a bug
/// can be reproduced deterministically instead of by re-recording each time.
///
/// Drop `paragraph-N.wav` files into `.context/test-audio/` (see
/// `paragraphs.md`), then run:
///     swift test --filter AudioReplayTests
/// Results are written to `.context/test-audio/results.md` and printed.
///
/// Skips (does not fail) when no recordings are present, so the normal suite is
/// unaffected.
final class AudioReplayTests: XCTestCase {
    /// Same shape a user would type into "Words to get right", so P5's biasing
    /// path is exercised exactly as in the app.
    private let vocabulary = ["Parakeet", "RAG: rack, rag", "Lyzr: laser, lizer", "NVIDIA"]

    func testReplayRecordedParagraphs() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        // Committed regression fixtures first, then any ad-hoc local recordings
        // dropped in the git-ignored scratch dir. Same-named files: fixture wins.
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
        try XCTSkipIf(wavs.isEmpty, "No recordings in \(searchDirs.map(\.path).joined(separator: " or ")) — see paragraphs.md")

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

        // Write results to the git-ignored scratch dir so the tracked fixtures
        // never show up as modified after a run.
        let resultsDir = root.appendingPathComponent(".context/test-audio")
        try? FileManager.default.createDirectory(at: resultsDir, withIntermediateDirectories: true)
        let out = resultsDir.appendingPathComponent("results.md")
        try? report.write(to: out, atomically: true, encoding: .utf8)
        print("[replay] wrote \(out.path)")
        print(report)
    }

    /// Feed the whole file through the streaming path. Windowing keys off
    /// absolute sample position, so one buffer reproduces live streaming exactly.
    private func replay(url: URL, through transcriber: FluidAudioStreamingTranscriber) async throws -> String {
        let file = try AVAudioFile(forReading: url)
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)
        else { throw ReplayError.unreadable(url.lastPathComponent) }
        try file.read(into: buffer)

        try await transcriber.start { _ in }
        try await transcriber.append(buffer)
        return try await transcriber.stop()
    }

    private func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    private enum ReplayError: Error { case unreadable(String) }
}
