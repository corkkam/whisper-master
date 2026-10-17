@preconcurrency import AVFoundation
import Foundation
import Observation

/// One audio source of a meeting: its buffers go, in order, through a resampler
/// into the recording and into a transcriber of its own.
///
/// **Its own transcriber, not the dictation one.** Push-to-talk keeps working
/// during a meeting, and `FluidAudioStreamingTranscriber` holds one session at a
/// time. Each stream loads Parakeet from disk once; it never downloads (the
/// session checks `TranscriberEngine.isInstalled` first).
///
/// Buffers go through an `AsyncStream` with **one** consumer, not a `Task` per
/// buffer: per-buffer tasks are not ordered, and out-of-order audio is garbage to
/// both the encoder and the recognizer.
final class MeetingAudioStream: @unchecked Sendable {
    let speaker: MeetingSpeaker
    private let transcriber = FluidAudioStreamingTranscriber()
    private let buffers: AsyncStream<AVAudioPCMBuffer>
    private let continuation: AsyncStream<AVAudioPCMBuffer>.Continuation
    private var consumer: Task<Void, Never>?

    init(speaker: MeetingSpeaker) {
        self.speaker = speaker
        (buffers, continuation) = AsyncStream.makeStream(of: AVAudioPCMBuffer.self)
    }

    func start(recorder: MeetingAudioRecorder,
               onConfirmed: @escaping @Sendable (String) -> Void) async throws {
        try await transcriber.prepareModels(progress: { _ in })
        try await transcriber.start { update in onConfirmed(update.confirmedText) }
        let speaker = speaker
        let transcriber = transcriber
        let buffers = buffers
        consumer = Task.detached(priority: .userInitiated) {
            let resampler = MonoResampler()
            for await buffer in buffers {
                guard let mono = resampler.convert(buffer) else { continue }
                recorder.append(mono, speaker: speaker)
                try? await transcriber.append(mono)
            }
        }
    }

    /// Called from the capture thread. Never blocks.
    func feed(_ buffer: AVAudioPCMBuffer) {
        continuation.yield(buffer)
    }

    /// Drain what is queued, then return the engine's final transcript.
    func finish() async -> String {
        continuation.finish()
        await consumer?.value
        return (try? await transcriber.stop()) ?? ""
    }

    func cancel() async {
        continuation.finish()
        consumer?.cancel()
        await transcriber.cancel()
    }
}

/// A meeting being recorded: the mic as "You", the call app as "Others".
///
/// Owned by `MeetingController`; the live window observes it.
@MainActor
@Observable
final class MeetingSession {
    enum StartError: LocalizedError {
        case microphoneDenied
        case engineNotInstalled

        var errorDescription: String? {
            switch self {
            case .microphoneDenied: return "Allow microphone access to take meeting notes."
            case .engineNotInstalled: return "The voice engine is still installing. Try again when it is ready."
            }
        }
    }

    let call: DetectedCall
    let startedAt: Date
    private(set) var transcript = MeetingTranscript()
    /// Bullets the notes model wrote during the meeting, oldest first.
    private(set) var liveNotes: [String] = []
    /// What the user types in the live window. Kept verbatim in the final note.
    var ownNotes: String = ""
    /// False when the call audio could not be captured (no consent, macOS older
    /// than 14.2). The meeting still records the mic.
    private(set) var capturesCallAudio = false
    private(set) var micLost = false

    private let recorder = MeetingAudioRecorder()
    private let mic = MicrophoneCaptureService()
    private let micStream = MeetingAudioStream(speaker: .me)
    private let callStream = MeetingAudioStream(speaker: .others)
    private var tap: AnyObject?
    private var liveNotesTask: Task<Void, Never>?
    private var liveNotesCursorMs = 0

    /// How often the running notes are refreshed.
    static let liveNotesInterval: TimeInterval = 180

    init(call: DetectedCall, now: Date = Date()) {
        self.call = call
        self.startedAt = now
    }

    var elapsedMs: Int { Int(Date().timeIntervalSince(startedAt) * 1000) }

    func start() async throws {
        guard await mic.ensurePermission() else { throw StartError.microphoneDenied }
        guard TranscriberEngine.slidingWindow.isInstalled else { throw StartError.engineNotInstalled }

        try await micStream.start(recorder: recorder) { [weak self] text in
            Task { @MainActor in self?.ingest(text, from: .me) }
        }
        let micStream = micStream
        mic.onCaptureLost = { [weak self] in Task { @MainActor in self?.micLost = true } }
        try mic.start(bufferHandler: { micStream.feed($0) }, levelHandler: { _ in })

        if #available(macOS 14.2, *) {
            do {
                try await callStream.start(recorder: recorder) { [weak self] text in
                    Task { @MainActor in self?.ingest(text, from: .others) }
                }
                let tap = SystemAudioTap()
                let callStream = callStream
                try tap.start(bundleFamily: call.bundleFamily) { callStream.feed($0) }
                self.tap = tap
                capturesCallAudio = true
            } catch {
                Log.meetings.error("call audio unavailable: \(error.localizedDescription, privacy: .public)")
                await callStream.cancel()
            }
        }
        startLiveNotes()
    }

    /// Stop capture and return the finished transcript text. The recording is
    /// mixed into `<noteID>.m4a`.
    func stop(noteID: UUID) async -> (transcript: String, audio: NoteAudio?) {
        liveNotesTask?.cancel()
        mic.stop()
        if #available(macOS 14.2, *) { (tap as? SystemAudioTap)?.stop() }
        tap = nil

        let at = elapsedMs
        async let mine = micStream.finish()
        async let theirs: String = capturesCallAudio ? callStream.finish() : ""
        let (micFinal, callFinal) = await (mine, theirs)
        transcript.ingest(confirmed: micFinal, from: .me, atMs: at)
        transcript.ingest(confirmed: callFinal, from: .others, atMs: at)

        let recorder = recorder
        let audio = await Task.detached { recorder.finish(noteID: noteID) }.value
        return (transcript.rendered(), audio)
    }

    func cancel() async {
        liveNotesTask?.cancel()
        mic.stop()
        if #available(macOS 14.2, *) { (tap as? SystemAudioTap)?.stop() }
        tap = nil
        await micStream.cancel()
        await callStream.cancel()
        recorder.cancel()
    }

    /// Fill the transcript and notes for the PNG renderer. Nothing is captured.
    func seedForSnapshot(lines: [(MeetingSpeaker, Int, String)], liveNotes: [String], ownNotes: String,
                         capturesCallAudio: Bool = true) {
        var cumulative: [MeetingSpeaker: String] = [:]
        for (speaker, atMs, text) in lines {
            let joined = [cumulative[speaker], text].compactMap { $0 }.joined(separator: " ")
            cumulative[speaker] = joined
            transcript.ingest(confirmed: joined, from: speaker, atMs: atMs)
        }
        self.liveNotes = liveNotes
        self.ownNotes = ownNotes
        self.capturesCallAudio = capturesCallAudio
    }

    private func ingest(_ confirmed: String, from speaker: MeetingSpeaker) {
        transcript.ingest(confirmed: confirmed, from: speaker, atMs: elapsedMs)
    }

    /// Every few minutes, turn what was said since the last pass into bullets.
    /// Only when the assistant model is already on disk; it is never downloaded
    /// for this.
    private func startLiveNotes() {
        liveNotesTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.liveNotesInterval * 1_000_000_000))
                guard !Task.isCancelled, let self, CleanupModel.General.isInstalled else { continue }
                let cursor = self.liveNotesCursorMs
                let recent = self.transcript.rendered(after: cursor)
                self.liveNotesCursorMs = self.elapsedMs
                guard !recent.isEmpty else { continue }
                await MlxCleanupService.prepareGeneralIfInstalled()
                if let bullets = await MeetingNotesGenerator.live.liveBullets(for: recent) {
                    self.liveNotes.append(bullets)
                }
            }
        }
    }
}

extension MeetingNotesGenerator {
    /// The shipped generator: the on-device general model.
    static let live = MeetingNotesGenerator { user, system, maxTokens in
        await MlxCleanupService.general.generateAgent(
            user, systemPrompt: system, maxTokens: maxTokens, thinking: CleanupModel.General.thinks)
    }
}
