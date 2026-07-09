import AVFoundation

/// Accumulates captured PCM (downmixed to mono 16-bit) and writes it as a WAV on
/// finish. Kept in memory until the session ends — a dictation is short, so a few
/// MB is fine. Stored at the *capture* sample rate, not resampled: the eval
/// replay path resamples a file exactly the way the live mic tap does, so a
/// capture-rate WAV replays faithfully.
final class SessionAudioWriter {
    private var samples: [Int16] = []
    private(set) var sampleRate: Double = 16_000
    private(set) var droppedBuffers = 0

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else {
            droppedBuffers += 1
            return
        }
        sampleRate = buffer.format.sampleRate
        let channelCount = Int(buffer.format.channelCount)
        let length = Int(buffer.frameLength)
        samples.reserveCapacity(samples.count + length)
        for frame in 0..<length {
            var sum: Float = 0
            for channel in 0..<channelCount { sum += channels[channel][frame] }
            samples.append(WavEncoder.int16(sum / Float(channelCount)))
        }
    }

    var durationMs: Int {
        guard sampleRate > 0 else { return 0 }
        return Int(Double(samples.count) / sampleRate * 1000)
    }

    func wavData() -> Data {
        WavEncoder.encode(samples: samples, sampleRate: sampleRate)
    }

    func write(to url: URL) throws {
        try wavData().write(to: url)
    }
}

/// Minimal canonical 16-bit mono PCM WAV encoder. Pure — unit-tested on header
/// bytes and data length.
enum WavEncoder {
    static func int16(_ value: Float) -> Int16 {
        let clamped = max(-1, min(1, value))
        return Int16((clamped * Float(Int16.max)).rounded())
    }

    static func encode(samples: [Int16], sampleRate: Double) -> Data {
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let rate = UInt32(sampleRate)
        let blockAlign = channels * bitsPerSample / 8
        let byteRate = rate * UInt32(blockAlign)
        let dataSize = UInt32(samples.count * 2)

        var data = Data()
        func appendASCII(_ s: String) { data.append(contentsOf: Array(s.utf8)) }
        func appendLE<T: FixedWidthInteger>(_ v: T) {
            withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) }
        }

        appendASCII("RIFF")
        appendLE(UInt32(36) + dataSize)   // chunk size
        appendASCII("WAVE")

        appendASCII("fmt ")
        appendLE(UInt32(16))              // PCM subchunk size
        appendLE(UInt16(1))              // audio format = PCM
        appendLE(channels)
        appendLE(rate)
        appendLE(byteRate)
        appendLE(blockAlign)
        appendLE(bitsPerSample)

        appendASCII("data")
        appendLE(dataSize)
        for sample in samples { appendLE(sample) }
        return data
    }
}
