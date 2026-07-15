import XCTest
@testable import WhisperMaster

final class DiagnosticsTests: XCTestCase {

    // MARK: AudioSignalStats

    func testSignalStatsRmsPeakClip() {
        var stats = AudioSignalStats()
        stats.add(samples: [0.5, -0.5, 0.5, -0.5])
        XCTAssertEqual(stats.rmsMean, 0.5, accuracy: 1e-6)
        XCTAssertEqual(stats.peak, 0.5, accuracy: 1e-6)
        XCTAssertEqual(stats.clippedPct, 0, accuracy: 1e-6)
    }

    func testSignalStatsCounts100PctClipping() {
        var stats = AudioSignalStats()
        stats.add(samples: [1.0, -1.0])
        XCTAssertEqual(stats.rmsMean, 1.0, accuracy: 1e-6)
        XCTAssertEqual(stats.peak, 1.0, accuracy: 1e-6)
        XCTAssertEqual(stats.clippedPct, 100, accuracy: 1e-6)
    }

    func testSignalStatsEmptyIsZero() {
        let stats = AudioSignalStats()
        XCTAssertEqual(stats.rmsMean, 0)
        XCTAssertEqual(stats.clippedPct, 0)
    }

    // MARK: WavEncoder

    func testWavHeaderAndSize() {
        let data = WavEncoder.encode(samples: [1, -1, 100], sampleRate: 16_000)
        XCTAssertEqual(data.count, 44 + 3 * 2)          // header + 3 int16 samples
        XCTAssertEqual(ascii(data, 0, 4), "RIFF")
        XCTAssertEqual(ascii(data, 8, 4), "WAVE")
        XCTAssertEqual(ascii(data, 12, 4), "fmt ")
        XCTAssertEqual(ascii(data, 36, 4), "data")
        XCTAssertEqual(readLE32(data, 24), 16_000)      // sample rate field
        XCTAssertEqual(readLE32(data, 40), 6)           // data chunk size = 3*2
    }

    func testInt16ClampsAndRounds() {
        XCTAssertEqual(WavEncoder.int16(2.0), Int16.max)
        XCTAssertEqual(WavEncoder.int16(-2.0), -Int16.max)
        XCTAssertEqual(WavEncoder.int16(0), 0)
    }

    // MARK: SessionTrace

    func testStageDeltasAreConsecutiveDifferences() {
        let trace = makeTrace(marks: [("armed", 0), ("engineStarted", 50), ("micStarted", 120)])
        let deltas = trace.stageDeltas()
        XCTAssertEqual(deltas, [
            .init(stage: "armed", deltaMs: 0),
            .init(stage: "engineStarted", deltaMs: 50),
            .init(stage: "micStarted", deltaMs: 70),
        ])
    }

    func testTraceJSONRoundTrips() throws {
        let trace = makeTrace(marks: [("armed", 0), ("pasted", 900)])
        let encoded = try JSONEncoder().encode(trace)
        let decoded = try JSONDecoder().decode(SessionTrace.self, from: encoded)
        XCTAssertEqual(decoded, trace)
    }

    // MARK: helpers

    private func makeTrace(marks: [(String, Int)]) -> SessionTrace {
        SessionTrace(
            id: "abc",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            context: .init(appVersion: "1.2.2", engine: "slidingWindow",
                           fillerFilter: true, llmCleanup: false, itn: true,
                           holdToTalk: true, pasteOutcome: "native"),
            timeline: marks.map { SessionTrace.Mark(stage: $0.0, msSinceStart: $0.1) },
            asr: nil, audio: nil,
            text: .init(rawAsr: "raw", stages: [], finalPasted: "final"))
    }

    private func ascii(_ data: Data, _ offset: Int, _ length: Int) -> String {
        String(bytes: data[offset..<offset + length], encoding: .ascii) ?? ""
    }

    private func readLE32(_ data: Data, _ offset: Int) -> UInt32 {
        data[offset..<offset + 4].reversed().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
}
