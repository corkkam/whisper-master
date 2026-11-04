@preconcurrency import AVFoundation

/// Converts whatever a source delivers (48 kHz stereo from a tap, the mic's
/// native rate) to 16 kHz mono Float32 — Parakeet's working format, and the
/// format both meeting tracks are written to disk in, so they line up sample for
/// sample when mixed.
///
/// One per source, because an `AVAudioConverter` keeps filter state between
/// calls; sharing one across two streams would smear them into each other.
final class MonoResampler {
    static let sampleRate: Double = 16_000
    static let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!

    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: Self.format)
            inputFormat = buffer.format
        }
        guard let converter else { return nil }
        let ratio = Self.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: capacity)
        else { return nil }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }
}
