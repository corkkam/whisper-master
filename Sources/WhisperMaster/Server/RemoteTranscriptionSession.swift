@preconcurrency import AVFoundation
import FluidAudio
import Foundation
import Network

// MARK: - RemoteTranscriptionSession
//
// One live dictation session for a single connected iOS client. Owns its own
// `FluidAudioStreamingTranscriber` (separate from the desktop view model's, the
// same way `AppDelegate.onboardingMic` is a separate capture instance) so a
// remote session never interferes with local recording.
//
// Lifecycle, driven by control frames from the client:
//   startSession → prepareModels (progress relayed) → transcriber.start
//                → stream audio frames into transcriber.append
//   stopSession  → transcriber.stop → final transcript
//   cancelSession / disconnect → transcriber.cancel

actor RemoteTranscriptionSession {
    private let channel: MessageChannel
    /// Reports `true` when this session begins transcribing and `false` when it
    /// stops — the server uses it to count active transcriptions (its load).
    private let onRecordingChange: @Sendable (Bool) -> Void

    /// Created lazily on the first `startSession`, so a connection that only
    /// probes latency (ping/pong) never spins up a transcriber.
    private var transcriber: FluidAudioStreamingTranscriber?

    /// All server→client messages funnel through this stream so they are sent
    /// in order from a single task, regardless of which context produced them
    /// (the transcriber's update callback fires off-actor).
    private var outbound: AsyncStream<ServerControl>.Continuation?
    private var outboundTask: Task<Void, Never>?

    private var isRunning = false

    init(channel: MessageChannel, onRecordingChange: @escaping @Sendable (Bool) -> Void = { _ in }) {
        self.channel = channel
        self.onRecordingChange = onRecordingChange
    }

    /// Reads control/audio frames until the client disconnects, then tears the
    /// session down. Returns when the connection is closed or errors.
    func run() async {
        startOutboundPump()
        do {
            while true {
                let frame = try await channel.receiveFrame()
                switch frame.kind {
                case .control:
                    let control = try ClientControl.decode(frame.payload)
                    try await handle(control)
                case .audio:
                    await handleAudio(frame.payload)
                }
            }
        } catch {
            // Connection closed or malformed frame — fall through to teardown.
        }
        await teardown()
    }

    // MARK: - Control handling

    private func handle(_ control: ClientControl) async throws {
        switch control {
        case .startSession(let config):
            await startSession(config)
        case .stopSession:
            await stopSession()
        case .cancelSession:
            await cancelSession()
        case .ping(let nonce):
            emit(.pong(nonce: nonce))
        }
    }

    private func startSession(_ config: SessionConfig) async {
        guard !isRunning else { return }

        let transcriber = self.transcriber ?? FluidAudioStreamingTranscriber()
        self.transcriber = transcriber

        await transcriber.setVocabulary(config.vocabulary)

        do {
            try await transcriber.prepareModels { [weak self] snapshot in
                guard let self else { return }
                Task { await self.emit(.state(.preparingModels(
                    fraction: snapshot.fractionCompleted,
                    detail: Self.detail(for: snapshot)
                ))) }
            }
        } catch {
            emit(.state(.error(message: "Failed to load models: \(error.localizedDescription)")))
            return
        }

        emit(.state(.ready))

        do {
            try await transcriber.start { [weak self] update in
                guard let self else { return }
                let partial = update.latestText.isEmpty ? update.partialText : update.latestText
                Task {
                    await self.emit(.transcript(
                        partial: partial,
                        confirmed: update.confirmedText,
                        isConfirmed: update.isConfirmed
                    ))
                }
            }
        } catch {
            emit(.state(.error(message: "Failed to start transcription: \(error.localizedDescription)")))
            return
        }

        isRunning = true
        onRecordingChange(true)
        emit(.state(.recording))

        // Load vocabulary biasing in the background — never blocks recording.
        Task { await transcriber.loadVocabularyResources() }
    }

    private func stopSession() async {
        guard isRunning, let transcriber else { return }
        isRunning = false
        onRecordingChange(false)
        do {
            let final = try await transcriber.stop()
            emit(.finalTranscript(text: final))
        } catch {
            emit(.state(.error(message: "Failed to finalize: \(error.localizedDescription)")))
        }
    }

    private func cancelSession() async {
        guard isRunning, let transcriber else { return }
        isRunning = false
        onRecordingChange(false)
        await transcriber.cancel()
    }

    // MARK: - Audio handling

    private func handleAudio(_ pcm: Data) async {
        guard isRunning, let transcriber, let buffer = Self.makeBuffer(from: pcm) else { return }
        try? await transcriber.append(buffer)
    }

    /// Reconstructs an `AVAudioPCMBuffer` from raw little-endian Int16 PCM at the
    /// agreed 16 kHz mono format. FluidAudio resamples/format-converts internally.
    private static func makeBuffer(from pcm: Data) -> AVAudioPCMBuffer? {
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: WireAudioFormat.sampleRate,
                channels: WireAudioFormat.channelCount,
                interleaved: false
            )
        else { return nil }

        let frameCount = pcm.count / MemoryLayout<Int16>.size
        guard
            frameCount > 0,
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)),
            let destination = buffer.int16ChannelData
        else { return nil }

        buffer.frameLength = AVAudioFrameCount(frameCount)
        pcm.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: Int16.self).baseAddress else { return }
            destination[0].update(from: base, count: frameCount)
        }
        return buffer
    }

    // MARK: - Outbound pump

    private func startOutboundPump() {
        let stream = AsyncStream<ServerControl> { continuation in
            self.outbound = continuation
        }
        outboundTask = Task { [channel] in
            for await message in stream {
                try? await channel.send(control: message)
            }
        }
    }

    private func emit(_ message: ServerControl) {
        outbound?.yield(message)
    }

    private func teardown() async {
        if isRunning {
            isRunning = false
            onRecordingChange(false)
            await transcriber?.cancel()
        }
        outbound?.finish()
        outbound = nil
        outboundTask = nil
    }

    // MARK: - Helpers

    private static func detail(for snapshot: DownloadUtils.DownloadProgress) -> String {
        switch snapshot.phase {
        case .listing:
            return "Checking voice engine…"
        case .downloading(let completed, let total):
            return total > 0 ? "Downloading voice engine (\(completed)/\(total))…" : "Downloading voice engine…"
        case .compiling:
            return "Optimizing voice engine…"
        }
    }
}
