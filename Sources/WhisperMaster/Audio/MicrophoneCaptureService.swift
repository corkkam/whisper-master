@preconcurrency import AVFoundation
import CoreAudio
import Foundation

/// Microphone capture for dictation: one `AVAudioEngine`, a tap on the system
/// default input, no device manipulation anywhere in the recording path (see the
/// **Microphone capture** section of `CLAUDE.md` — programmatically juggling audio
/// devices was tried three times and hung Core Audio; don't).
///
/// **What it does defend against is the route changing underneath it.** Plugging in
/// an external speaker, switching output in Sound settings, or connecting AirPods
/// makes `AVAudioEngine` post `AVAudioEngineConfigurationChange`: the engine stops
/// itself and its IO nodes re-derive their formats from the *new* device set.
/// Anything that then touches the old graph — installing a tap with the format read
/// a moment earlier, or starting an engine built against devices that no longer
/// exist — raises an Objective-C exception (`required condition is false: …`), which
/// is an `abort()` no Swift `try` can catch. That is the "crashes sometimes with an
/// external speaker while using the built-in mic" report: a mismatched input/output
/// pair is exactly the case that renegotiates the graph. Three defences, in order:
///
/// 1. **Observe the change** (`handleConfigurationChange`) and rebuild the engine on
///    the current devices, re-tapping a live recording rather than leaving a stale
///    graph to be reused later.
/// 2. **Never hand `installTap` a format we captured earlier** — passing `nil` makes
///    the node use whatever format it holds *now*, so the equality assertion that
///    fires on a mid-flight route change has nothing to trip on. The formats are
///    still read first, to *reject* a graph that is visibly mid-renegotiation.
/// 3. **Retry a failed start once on a fresh engine.** A start that fails because the
///    input and output devices disagree usually succeeds on an engine built after the
///    route settles.
final class MicrophoneCaptureService {
    enum CaptureError: LocalizedError {
        case microphoneUnavailable
        case engineStartFailed
        /// The audio route changed under a live recording and the capture graph
        /// couldn't be rebuilt on the new devices.
        case captureInterrupted

        var errorDescription: String? {
            switch self {
            case .microphoneUnavailable:
                return "The microphone isn't available right now."
            case .engineStartFailed:
                return "Couldn't start the microphone."
            case .captureInterrupted:
                return "The audio device changed while recording."
            }
        }
    }

    typealias BufferHandler = @Sendable (AVAudioPCMBuffer) -> Void
    typealias LevelHandler = @Sendable (Float) -> Void

    /// Rebuilt (never mutated in place) when a route change invalidates the graph,
    /// which is why this is a `var` — the *device* is still never touched.
    private var engine = AVAudioEngine()
    private var bufferHandler: BufferHandler?
    private var levelHandler: LevelHandler?
    private var isCapturing = false

    /// Called when a route change ended a live capture that couldn't be recovered,
    /// so the owner can fail the session honestly instead of recording silence.
    /// Set once by the owner; invoked on the main queue.
    var onCaptureLost: (() -> Void)?

    private var rewarmWork: DispatchWorkItem?
    /// Coalesces the burst of `AVAudioEngineConfigurationChange` notifications a
    /// single route change emits into one deferred rebuild, and — the load-bearing
    /// part — moves the engine *drop* off the notification callout (see
    /// `handleConfigurationChange`).
    private var configChangeWork: DispatchWorkItem?
    private var deviceListenerBlock: AudioObjectPropertyListenerBlock?
    private var configObserver: NSObjectProtocol?
    /// True for the duration of a warm-up start/stop.
    private var isPrewarming = false
    /// When the last warm-up finished. A configuration change we provoked ourselves
    /// is delivered **asynchronously**, so a plain "am I warming right now" flag
    /// can't catch it — by the time the notification lands the warm is long over.
    /// Without this window, rebuild → warm → notification → rebuild → warm is an
    /// engine-rebuild loop that runs forever at the re-warm cadence.
    private var prewarmEndedAt: TimeInterval?
    /// How long after a warm a configuration change is treated as self-inflicted.
    /// Short, because the cost of swallowing a real one is only that an idle graph
    /// stays stale — and `start()` rebuilds and retries anyway.
    private static let prewarmQuietWindow: TimeInterval = 0.5
    /// How long to wait after a configuration change before acting on it. Two jobs:
    /// coalesce the burst of notifications a single route change (AirPods/Bluetooth
    /// connect, external speaker) emits into one rebuild, and — the reason this
    /// exists — get the engine *drop* out of the synchronous notification callout.
    /// Releasing the old `AVAudioEngine` from inside the callout tears down its IO
    /// unit while AVFAudio is still mid-reconfiguring that same unit for the change
    /// the notification announced, so its internal HAL property listener fires
    /// against a half-freed unit — the `AVAudioIOUnit` use-after-free crash. Kept
    /// below `prewarmQuietWindow` so a self-inflicted change is still recognised.
    private static let configChangeSettleDelay: TimeInterval = 0.15
    /// Bounded budget for mid-recording graph rebuilds. A route that keeps flapping
    /// ends the session honestly instead of being rebuilt on every notification for as
    /// long as it lasts (pure + tested — see `CaptureRecoveryBudget`).
    private var recoveryBudget = CaptureRecoveryBudget()
    private static var deviceListAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    init() {
        observeConfigurationChanges()
    }

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
        guard !isCapturing, !isPrewarming else { return }
        guard settledInputFormat() != nil else { return }
        isPrewarming = true
        defer {
            isPrewarming = false
            prewarmEndedAt = ProcessInfo.processInfo.systemUptime
        }
        engine.prepare()
        do {
            try engine.start()
            engine.stop()
        } catch {
            // Warm-up is advisory only. The engine may have been built against a
            // device set that has since changed; drop it so the next start builds
            // a fresh one rather than retrying the same broken graph.
            rebuildEngine()
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
        rewarmWork?.cancel()
        configChangeWork?.cancel()
        if let block = deviceListenerBlock {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &Self.deviceListAddress, DispatchQueue.main, block)
        }
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
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

        // A rebuild deferred from a route change before this session must not land
        // underneath the fresh capture we're about to arm.
        configChangeWork?.cancel()

        // Each session gets its own recovery budget — a flap during the last one
        // must not spend this one's.
        recoveryBudget.reset()

        self.bufferHandler = bufferHandler
        self.levelHandler = levelHandler

        do {
            try installTapAndStart()
        } catch {
            // A graph built against a device set that has since changed is the
            // usual reason this fails — most visibly when the output device isn't
            // the one the input lives on. Rebuild on the *current* devices and try
            // once more before giving up.
            Log.app.notice("Mic start failed; rebuilding the capture graph and retrying")
            rebuildEngine()
            do {
                try installTapAndStart()
            } catch {
                clearHandlers()
                throw error
            }
        }

        isCapturing = true
    }

    func stop() {
        guard isCapturing else { return }
        configChangeWork?.cancel()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        clearHandlers()
        isCapturing = false
    }

    // MARK: - Graph

    /// Install the tap and start the engine, using the handlers already stored.
    /// The one place the graph is armed — `start()` and the route-change recovery
    /// both go through here, so they can't drift apart.
    private func installTapAndStart() throws {
        let inputNode = engine.inputNode
        guard settledInputFormat() != nil else {
            // The input device is mid-route-switch (common right after a Bluetooth
            // device connects, or while an external output is being wired up).
            // Fail cleanly instead of installing a tap against a format the node is
            // about to change — that raises an Objective-C exception, which aborts
            // the process rather than surfacing as a Swift error.
            throw CaptureError.microphoneUnavailable
        }

        inputNode.removeTap(onBus: 0)
        // `format: nil` — the node uses the format it holds *now*. Handing it a
        // format read even a moment earlier is what trips
        // `required condition is false: format.sampleRate == hwFormat.sampleRate`
        // when a route change lands in between.
        inputNode.installTap(onBus: 0, bufferSize: 2048, format: nil) { [weak self] buffer, _ in
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
            Log.app.error("AVAudioEngine start failed: \(error.localizedDescription, privacy: .public)")
            throw CaptureError.engineStartFailed
        }
    }

    /// The input node's format, but only once the node's own two views of it agree.
    ///
    /// `inputFormat` is what the hardware delivers and `outputFormat` is what the
    /// node hands the graph; for an input node they normally match exactly, and when
    /// they don't the device is mid-renegotiation — the state in which touching the
    /// graph aborts the process. `nil` means "not settled, don't touch it".
    private func settledInputFormat() -> AVAudioFormat? {
        let inputNode = engine.inputNode
        let output = inputNode.outputFormat(forBus: 0)
        let hardware = inputNode.inputFormat(forBus: 0)
        guard output.sampleRate > 0, output.channelCount > 0,
              hardware.sampleRate > 0, hardware.channelCount > 0,
              output.sampleRate == hardware.sampleRate,
              output.channelCount == hardware.channelCount
        else { return nil }
        return output
    }

    /// Drop the current engine and build a fresh one on the current device set.
    /// Cheap (no HAL start) and the only reliable way to shed a graph that
    /// `AVAudioEngine` has already invalidated — `reset()` keeps the stale IO
    /// formats. The tap handlers are left alone; the caller decides whether to
    /// re-arm them.
    private func rebuildEngine() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine = AVAudioEngine()
        // The notification is per-engine, so it has to follow the new object.
        observeConfigurationChanges()
    }

    /// Whether a configuration change arriving now is close enough to our own last
    /// warm-up to be treated as self-inflicted.
    private var isWithinPrewarmQuietWindow: Bool {
        guard let prewarmEndedAt else { return false }
        return ProcessInfo.processInfo.systemUptime - prewarmEndedAt < Self.prewarmQuietWindow
    }

    /// Tear the capture down and tell the owner, without going through `stop()` —
    /// which the owner's failure path will also call, and which must stay a no-op by
    /// then rather than a second teardown.
    private func abandonCapture() {
        configChangeWork?.cancel()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        clearHandlers()
        isCapturing = false
        onCaptureLost?()
    }

    private func observeConfigurationChanges() {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
        }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    /// The audio route changed: an external speaker was plugged in, the default
    /// output moved, AirPods connected. `AVAudioEngine` has already stopped itself
    /// and invalidated its IO formats by the time this runs.
    ///
    /// Delivered on the main queue (the observer's queue), which is also where
    /// `start`/`stop` are called from, so this can't interleave with them.
    ///
    /// **We do not rebuild here — we schedule it.** Releasing the old
    /// `AVAudioEngine` synchronously in this callout drops its IO unit while
    /// AVFAudio is still reconfiguring that same unit for the change this
    /// notification announced; the unit's internal HAL property listener then fires
    /// against a half-freed object, which is the `AVAudioIOUnit` use-after-free
    /// crash (a `sampleRate` message to a freed default-device aggregate). Deferring
    /// by `configChangeSettleDelay` gets the drop off the callout so AVFAudio
    /// finishes its own reconfiguration first, and coalesces the burst of
    /// notifications a single connect/disconnect emits into one rebuild instead of
    /// dropping an engine per notification while the route is still in motion.
    private func handleConfigurationChange() {
        configChangeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.performConfigurationChange()
        }
        configChangeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.configChangeSettleDelay, execute: work)
    }

    /// The deferred body of `handleConfigurationChange`, run on the main queue once
    /// the route has settled and AVFAudio's own reconfiguration is done.
    private func performConfigurationChange() {
        // Our own warm-up can provoke one of these, synchronously or a beat later;
        // acting on it would rebuild the graph we just warmed, warm again, and loop.
        guard !isPrewarming, !isWithinPrewarmQuietWindow else { return }

        guard isCapturing else {
            // Idle: shed the invalidated graph now, and re-warm once the route
            // settles so the next push-to-talk is still fast.
            rebuildEngine()
            scheduleRewarm()
            return
        }

        guard recoveryBudget.allowAttempt(now: ProcessInfo.processInfo.systemUptime) else {
            // The route is flapping. Rebuilding on every notification for as long as
            // that lasts would be a loop, so end the session and say so.
            Log.app.error("Audio route kept changing mid-recording; giving up on this session")
            abandonCapture()
            return
        }

        Log.app.notice("Audio route changed mid-recording; rebuilding the capture graph")
        // Keep the handlers — the session is still live and the words still matter.
        rebuildEngine()
        do {
            try installTapAndStart()
        } catch {
            // Can't record on the new route. End cleanly and say so, rather than
            // leaving a dead graph feeding silence into a "recording" session.
            Log.app.error("Capture lost after an audio route change")
            abandonCapture()
        }
    }

    private func clearHandlers() {
        bufferHandler = nil
        levelHandler = nil
    }

    private static func copy(buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        // `AVAudioPCMBuffer(pcmFormat:frameCapacity:)` raises an Objective-C
        // exception (not a nil return) on a zero capacity or a channel-less format,
        // both of which a tap can deliver while a device is being swapped out.
        guard buffer.frameCapacity > 0, buffer.format.channelCount > 0 else { return nil }
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
