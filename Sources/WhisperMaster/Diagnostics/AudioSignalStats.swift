import AVFoundation

/// Running signal statistics over captured PCM — RMS level, peak, and the
/// fraction of clipped samples. Accumulates across a session; read the computed
/// properties at the end. Pure math, so it's unit-tested via `add(samples:)`.
struct AudioSignalStats {
    private(set) var frameCount = 0
    private var sumSquares = 0.0
    private(set) var peak: Float = 0
    private var clippedFrames = 0

    /// Near-full-scale samples count as clipped.
    private static let clipThreshold: Float = 0.999

    /// Core accumulator over raw mono samples — the unit-testable path.
    mutating func add(samples: [Float]) {
        for sample in samples {
            let magnitude = abs(sample)
            sumSquares += Double(sample) * Double(sample)
            if magnitude > peak { peak = magnitude }
            if magnitude >= Self.clipThreshold { clippedFrames += 1 }
        }
        frameCount += samples.count
    }

    /// Fold in a capture buffer (first channel — capture is effectively mono).
    mutating func add(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let length = Int(buffer.frameLength)
        add(samples: Array(UnsafeBufferPointer(start: channel, count: length)))
    }

    var rmsMean: Float {
        guard frameCount > 0 else { return 0 }
        return Float((sumSquares / Double(frameCount)).squareRoot())
    }

    var clippedPct: Float {
        guard frameCount > 0 else { return 0 }
        return Float(clippedFrames) / Float(frameCount) * 100
    }
}
