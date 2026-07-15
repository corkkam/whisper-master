@preconcurrency import AVFoundation
import CoreAudio
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

    private var rewarmWork: DispatchWorkItem?
    private var deviceListenerBlock: AudioObjectPropertyListenerBlock?
    private static var deviceListAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

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

    /// Warm the capture graph so the first real `start()` doesn't pay the full
    /// cold Core Audio spin-up (measured at ~300-500 ms, which was clipping the
    /// user's first words). Resolves the input format, prepares the engine, and
    /// does a brief IO start/stop to bring the HAL input driver into residency.
    /// Installs **no tap**, so nothing is captured — the mic activates only for
    /// the instant it takes to warm. Best-effort: any failure just means the
    /// first real recording pays the usual cost. No device manipulation, so this
    /// stays clear of the audio-routing hazards in the recording path.
    func prewarm() {
        guard !isCapturing else { return }
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return }
        engine.prepare()
        do {
            try engine.start()
            engine.stop()
        } catch {
            // Warm-up is advisory only.
        }
    }

    /// Keep the warm state fresh: re-warm whenever the audio device topology
    /// changes (e.g. AirPods connect/disconnect), which invalidates the launch-
    /// time warm — the next `start()` would otherwise pay the full cold cost
    /// again. Read-only Core Audio observation; the actual re-warm is debounced
    /// and only runs while idle. Installs the listener once.
    func startAutoRewarm() {
        guard deviceListenerBlock == nil else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.scheduleRewarm()
        }
        deviceListenerBlock = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &Self.deviceListAddress, DispatchQueue.main, block)
    }

    private func scheduleRewarm() {
        // Device changes arrive in bursts; warm once, after the route settles.
        rewarmWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isCapturing,
                  AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            else { return }
            self.prewarm()
        }
        rewarmWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    deinit {
        if let block = deviceListenerBlock {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &Self.deviceListAddress, DispatchQueue.main, block)
        }
    }

    /// Start capturing from the system's current input device.
    ///
    /// We deliberately use the default input rather than pinning a specific
    /// device: macOS keeps the built-in mic as the input even when AirPods are
    /// connected for output (it only switches input if the user explicitly
    /// selects the AirPods mic), so the default is already the right source.
    func start(
        bufferHandler: @escaping BufferHandler,
        levelHandler: @escaping LevelHandler
    ) throws {
        guard !isCapturing else { return }

        self.bufferHandler = bufferHandler
        self.levelHandler = levelHandler

        let inputNode = engine.inputNode
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
