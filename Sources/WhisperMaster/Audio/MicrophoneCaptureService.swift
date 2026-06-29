@preconcurrency import AVFoundation
import AudioToolbox
import Foundation

final class MicrophoneCaptureService {
    enum CaptureError: Error {
        case microphoneUnavailable
        case engineStartFailed
    }

    typealias BufferHandler = @Sendable (AVAudioPCMBuffer) -> Void
    typealias LevelHandler = @Sendable (Float) -> Void

    private let engine = AVAudioEngine()
    private var bufferHandler: BufferHandler?
    private var levelHandler: LevelHandler?
    private var isCapturing = false

    func ensurePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    /// Start capturing.
    ///
    /// By default the system's current input device is used — but when that
    /// device is Bluetooth, recording from it forces the headset into the
    /// low-quality HFP "call" profile (mono, ~8–16 kHz), degrading both its
    /// playback and what we transcribe. So when `avoidBluetoothMic` is on we
    /// bind the engine to the built-in mic instead, keeping the headset in hi-fi
    /// A2DP. A deliberately-chosen USB/studio mic is always respected;
    /// `AudioInputResolver` only redirects away from Bluetooth.
    func start(
        avoidBluetoothMic: Bool = true,
        bufferHandler: @escaping BufferHandler,
        levelHandler: @escaping LevelHandler
    ) throws {
        guard !isCapturing else { return }

        self.bufferHandler = bufferHandler
        self.levelHandler = levelHandler

        let inputNode = engine.inputNode

        // Bind to the built-in mic before reading the format, so the format and
        // tap match the device we'll actually capture from.
        if let deviceID = AudioInputResolver.captureDeviceID(avoidBluetooth: avoidBluetoothMic),
           let audioUnit = inputNode.audioUnit {
            var device = deviceID
            AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &device,
                UInt32(MemoryLayout<AudioDeviceID>.size))
        }

        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            // The input device is mid-route-switch (common right after a
            // Bluetooth device connects). Fail cleanly instead of installing a
            // tap with an invalid format — that raises an Objective-C exception
            // that would otherwise wedge the recording task on "preparing".
            clearHandlers()
            throw CaptureError.microphoneUnavailable
        }

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            guard let copied = Self.copy(buffer: buffer) else { return }
            self.levelHandler?(Self.rmsLevel(from: copied))
            self.bufferHandler?(copied)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            clearHandlers()
            throw CaptureError.engineStartFailed
        }

        isCapturing = true
    }

    func stop() {
        guard isCapturing else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        clearHandlers()
        isCapturing = false
    }

    private func clearHandlers() {
        bufferHandler = nil
        levelHandler = nil
    }

    private static func copy(buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let clone = AVAudioPCMBuffer(
            pcmFormat: buffer.format,
            frameCapacity: buffer.frameCapacity
        ) else {
            return nil
        }

        clone.frameLength = buffer.frameLength

        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)

        if let source = buffer.floatChannelData, let destination = clone.floatChannelData {
            for channel in 0..<channelCount {
                destination[channel].update(from: source[channel], count: frameLength)
            }
            return clone
        }

        if let source = buffer.int16ChannelData, let destination = clone.int16ChannelData {
            for channel in 0..<channelCount {
                destination[channel].update(from: source[channel], count: frameLength)
            }
            return clone
        }

        return nil
    }

    private static func rmsLevel(from buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0 }

        var sumSquares: Float = 0
        for index in 0..<frameLength {
            let sample = channel[index]
            sumSquares += sample * sample
        }

        return sqrtf(sumSquares / Float(frameLength))
    }
}
