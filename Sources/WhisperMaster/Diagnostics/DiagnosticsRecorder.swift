import AVFoundation
import Foundation

/// The interface call sites use, so `DictationViewModel` never carries a `#if`.
/// A `DIAGNOSTICS` build points `Diagnostics.shared` at the real recorder below;
/// any other build points it at `NoopDiagnostics`, whose default implementations
/// (in the extension) do nothing.
@MainActor
protocol DiagnosticsRecording {
    func begin(context: SessionTrace.Context)
    func mark(_ stage: DiagnosticsStage)
    func noteAudioBuffer(_ buffer: AVAudioPCMBuffer)
    func noteInputDevice(name: String, isBluetooth: Bool)
    func noteFrontApp(name: String, bundleID: String)
    func notePolish(timing: String)
    func noteFirstPartial()
    func noteFirstConfirmed()
    func noteRawAsr(_ text: String)
    func noteStage(_ stage: DiagnosticsStage, text: String)
    func noteASR(confirmedChars: Int, volatileChars: Int, usedSalvage: Bool)
    func finish(pasteOutcome: String, finalText: String)
    func abandon()
}

@MainActor
extension DiagnosticsRecording {
    func begin(context: SessionTrace.Context) {}
    func mark(_ stage: DiagnosticsStage) {}
    func noteAudioBuffer(_ buffer: AVAudioPCMBuffer) {}
    func noteInputDevice(name: String, isBluetooth: Bool) {}
    func noteFrontApp(name: String, bundleID: String) {}
    func notePolish(timing: String) {}
    func noteFirstPartial() {}
    func noteFirstConfirmed() {}
    func noteRawAsr(_ text: String) {}
    func noteStage(_ stage: DiagnosticsStage, text: String) {}
    func noteASR(confirmedChars: Int, volatileChars: Int, usedSalvage: Bool) {}
    func finish(pasteOutcome: String, finalText: String) {}
    func abandon() {}
}

/// The build-out target: everything compiles to nothing. Selected whenever the
/// `DIAGNOSTICS` flag is absent, guaranteeing no session data or audio is ever
/// written in a shipped build.
struct NoopDiagnostics: DiagnosticsRecording {}

/// Real recorder: assembles a `SessionTrace` across one dictation and hands the
/// finished trace + WAV to the store off the main actor. One session at a time
/// (push-to-talk is serial), so a plain optional holds the in-flight session.
@MainActor
final class DiagnosticsRecorder: DiagnosticsRecording {
    private let store: DiagnosticsStore

    init(store: DiagnosticsStore = DiagnosticsStore()) { self.store = store }

    private final class Session {
        let id = UUID().uuidString
        let startedAt = Date()
        var context: SessionTrace.Context
        var marks: [SessionTrace.Mark] = []
        var text = SessionTrace.TextChain()
        var deviceName = ""
        var isBluetooth = false
        var stats = AudioSignalStats()
        let audio = SessionAudioWriter()
        var confirmedChars = 0
        var volatileChars = 0
        var usedSalvage = false
        var sawFirstBuffer = false
        var sawFirstPartial = false
        var sawFirstConfirmed = false
        init(context: SessionTrace.Context) { self.context = context }
    }

    private var session: Session?

    func begin(context: SessionTrace.Context) {
        let new = Session(context: context)
        session = new
        append(.armed, to: new)
    }

    func mark(_ stage: DiagnosticsStage) {
        guard let session else { return }
        append(stage, to: session)
    }

    func noteAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let session else { return }
        if !session.sawFirstBuffer {
            session.sawFirstBuffer = true
            append(.firstBuffer, to: session)
        }
        session.stats.add(buffer)
        session.audio.append(buffer)
    }

    func noteInputDevice(name: String, isBluetooth: Bool) {
        session?.deviceName = name
        session?.isBluetooth = isBluetooth
    }

    func noteFrontApp(name: String, bundleID: String) {
        session?.context.frontApp = name
        session?.context.frontAppBundleID = bundleID
    }

    func notePolish(timing: String) {
        session?.context.polishTiming = timing
    }

    func noteFirstPartial() {
        guard let session, !session.sawFirstPartial else { return }
        session.sawFirstPartial = true
        append(.firstPartial, to: session)
    }

    func noteFirstConfirmed() {
        guard let session, !session.sawFirstConfirmed else { return }
        session.sawFirstConfirmed = true
        append(.firstConfirmed, to: session)
    }

    func noteRawAsr(_ text: String) { session?.text.rawAsr = text }

    func noteStage(_ stage: DiagnosticsStage, text: String) {
        guard let session else { return }
        append(stage, to: session)
        session.text.stages.append(.init(stage: stage.rawValue, text: text))
    }

    func noteASR(confirmedChars: Int, volatileChars: Int, usedSalvage: Bool) {
        session?.confirmedChars = confirmedChars
        session?.volatileChars = volatileChars
        session?.usedSalvage = usedSalvage
    }

    func finish(pasteOutcome: String, finalText: String) {
        guard let session else { return }
        self.session = nil
        session.context.pasteOutcome = pasteOutcome
        append(.pasted, to: session)
        session.text.finalPasted = finalText

        let trace = assemble(session, finalText: finalText)
        let wav = session.audio.wavData()
        let store = store
        Task.detached { store.persist(trace: trace, wav: wav) }
    }

    func abandon() { session = nil }

    // MARK: assembly

    private func append(_ stage: DiagnosticsStage, to session: Session) {
        let ms = Int(Date().timeIntervalSince(session.startedAt) * 1000)
        session.marks.append(.init(stage: stage.rawValue, msSinceStart: ms))
    }

    private func assemble(_ session: Session, finalText: String) -> SessionTrace {
        let audioMs = session.audio.durationMs
        let audio = SessionTrace.AudioStats(
            inputDeviceName: session.deviceName,
            isBluetooth: session.isBluetooth,
            sampleRate: session.audio.sampleRate,
            channelCount: 1,
            rmsMean: session.stats.rmsMean,
            peak: session.stats.peak,
            clippedPct: session.stats.clippedPct,
            droppedBuffers: session.audio.droppedBuffers)

        let asr = SessionTrace.ASRStats(
            audioDurationMs: audioMs,
            realTimeFactor: realTimeFactor(session, audioMs: audioMs),
            confirmedChars: session.confirmedChars,
            volatileChars: session.volatileChars,
            usedSalvagePath: session.usedSalvage,
            wordCount: finalText.split(whereSeparator: \.isWhitespace).count)

        return SessionTrace(
            id: session.id, startedAt: session.startedAt, context: session.context,
            timeline: session.marks, asr: asr, audio: audio, text: session.text)
    }

    /// Finalize time (stop → pasted) relative to how much audio there was — how
    /// long post-stop decode+cleanup took versus the utterance length.
    private func realTimeFactor(_ session: Session, audioMs: Int) -> Double {
        guard audioMs > 0 else { return 0 }
        func ms(_ stage: DiagnosticsStage) -> Int? {
            session.marks.first { $0.stage == stage.rawValue }?.msSinceStart
        }
        guard let start = ms(.finalizeStart), let end = ms(.pasted) else { return 0 }
        return Double(end - start) / Double(audioMs)
    }
}
