import AppKit
@preconcurrency import AVFoundation
import FluidAudio
import Foundation

@MainActor
final class DictationViewModel {
    let state: AppState

    private let microphoneCapture: MicrophoneCaptureService
    private let permissionsManager: PermissionsManager
    private let hotkeyUpdater: (HotkeyManager.HotkeyOption) -> Void
    private let transcriber: FluidAudioStreamingTranscriber
    private let textInjector: TextInjector
    private var pendingAppendTasks: [UUID: Task<Void, Never>] = [:]
    private var preparationTask: Task<Void, Never>?
    private let releaseTailNanoseconds: UInt64 = 80_000_000
    /// When the current recording actually started capturing, for the analytics
    /// duration bucket. `nil` between sessions.
    private var recordingStartedAt: Date?
    /// Drives gentle "you haven't used me in a while" reminders in the notch.
    private lazy var reminderScheduler = ReminderScheduler(state: state)
    /// Watches pasted text for the user's fix-ups and grows the vocabulary.
    private let correctionLearner = CorrectionLearner()
    /// Merge accumulator for confirmed streaming chunks. Kept unfiltered so
    /// `TranscriptMerger`'s overlap detection always compares raw engine text
    /// against raw engine text; only what goes into `state` is filler-filtered.
    private var rawConfirmedTranscript = ""
    /// Latest full volatile track from the engine (the current sliding window),
    /// kept so a failed/empty engine finish can still deliver what streaming
    /// produced. The full window — not the truncated live-pill remainder.
    private var rawVolatileTranscript = ""

    init(
        state: AppState,
        microphoneCapture: MicrophoneCaptureService,
        permissionsManager: PermissionsManager,
        hotkeyUpdater: @escaping (HotkeyManager.HotkeyOption) -> Void = { _ in },
        transcriber: FluidAudioStreamingTranscriber,
        textInjector: TextInjector
    ) {
        self.state = state
        self.microphoneCapture = microphoneCapture
        self.permissionsManager = permissionsManager
        self.hotkeyUpdater = hotkeyUpdater
        self.transcriber = transcriber
        self.textInjector = textInjector
    }

    convenience init() {
        self.init(hotkeyUpdater: { _ in })
    }

    convenience init(
        hotkeyUpdater: @escaping (HotkeyManager.HotkeyOption) -> Void
    ) {
        self.init(
            state: AppState(),
            microphoneCapture: MicrophoneCaptureService(),
            permissionsManager: PermissionsManager(),
            hotkeyUpdater: hotkeyUpdater,
            transcriber: FluidAudioStreamingTranscriber(),
            textInjector: TextInjector()
        )
    }

    /// Consulted on each refresh tick to decide whether to drop a gentle
    /// reminder into the notch. Cheap; a no-op unless idle and due.
    func evaluateReminders() {
        reminderScheduler.tick()
    }

    func startRecording() {
        guard state.canStart else { return }

        // A reminder showing now would be replaced by the live indicator anyway.
        reminderScheduler.clear()
        // A new dictation supersedes any correction watch on the previous one.
        correctionLearner.cancel()
        // Any pending "nowhere to paste" hint is stale once a new session starts.
        state.undeliveredTranscriptAt = nil

        // If the Apple Intelligence pass is opted in, warm it while the user talks
        // so the post-dictation formatting is hot instead of a cold start. The
        // default deterministic formatter's prewarm is a no-op.
        Task { await TextFormatterProvider.shared.current().prewarm() }

        state.phase = .preparingModels
        state.audioLevel = 0
        state.resetTranscript()
        rawConfirmedTranscript = ""
        rawVolatileTranscript = ""
        state.statusMessage = "Getting voice engine ready..."

        Task {
            do {
                let micAllowed = await microphoneCapture.ensurePermission()
                guard micAllowed else {
                    throw MicrophoneCaptureService.CaptureError.microphoneUnavailable
                }

                try await prepareSelectedEngineIfNeeded()

                state.download = nil
                state.statusMessage = "Voice engine ready. Starting microphone..."

                try await transcriber.start { [weak self] update in
                    Task { @MainActor in
                        guard let self else { return }
                        self.applyTranscriptUpdate(update)
                        if update.isConfirmed {
                            self.state.statusMessage = "Receiving confirmed local transcript..."
                        } else {
                            self.state.statusMessage = "Receiving live partial transcript..."
                        }
                    }
                }

                try microphoneCapture.start(
                    bufferHandler: { [weak self] buffer in
                        guard let self else { return }
                        Task { @MainActor in
                            self.enqueueAudioBuffer(buffer)
                        }
                    },
                    levelHandler: { [weak self] level in
                        Task { @MainActor in
                            self?.state.audioLevel = level
                        }
                    }
                )

                recordingStartedAt = Date()
                state.phase = .recording
                state.statusMessage = "Recording with \(state.selectedEngine.displayName)..."
            } catch {
                await handleFailure(error)
            }
        }
    }

    func stopRecording() {
        guard state.canStop else { return }

        // Capture session length now, at the user's stop, before the async
        // finalize work; cleared so a cancelled/failed run can't reuse it.
        let sessionDuration = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        recordingStartedAt = nil

        state.phase = .stopping
        state.audioLevel = 0
        state.statusMessage = "Catching final words..."

        Task {
            do {
                try? await Task.sleep(nanoseconds: releaseTailNanoseconds)
                microphoneCapture.stop()
                await drainPendingAudioBuffers()
                state.statusMessage = "Finalizing local transcript..."
                var rawFinal: String
                do {
                    rawFinal = try await transcriber.stop()
                } catch {
                    // The final decode failed after real speech already
                    // streamed through. Recreate the engine session, then fall
                    // back to the streamed text rather than losing the words.
                    await transcriber.cancel()
                    rawFinal = ""
                }
                if rawFinal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    rawFinal = salvagedStreamingTranscript()
                }
                // Repair spaces the ASR dropped at pause/segment boundaries
                // ("right?The" → "right? The") before the rest of the pipeline.
                let spaced = TranscriptSpacingRepair.repair(rawFinal)
                let formatted = await formatFinalTranscript(spaced)
                // May leave the text empty (a recording that was only "hmm" /
                // a silence hallucination) — the guard below then skips
                // history and injection entirely.
                let deFillered = filterFillersIfEnabled(formatted)
                // Apply the glossary as a safe text replacement (casing + known
                // mishearings) — the substitute for FluidAudio's transcript-
                // corrupting streaming rescorer.
                let final = VocabularyPostProcessor.apply(deFillered, glossary: state.customVocabulary)
                state.phase = .idle
                state.transcript.finalText = final
                if !final.isEmpty {
                    state.transcript.latestConfirmed = final
                    state.transcript.latestPartial = ""
                    state.appendHistory(text: final, engine: state.selectedEngine)
                    reminderScheduler.noteUsed()
                    Analytics.shared.send(.dictationCompleted(
                        engine: state.selectedEngine.rawValue,
                        duration: sessionDuration,
                        wordCount: final.split(whereSeparator: \.isWhitespace).count
                    ))
                    if state.autoPasteEnabled {
                        await injectFinalTextIfPossible(final)
                    }
                }
                state.statusMessage = "Finished local transcription."
            } catch {
                await handleFailure(error)
            }
        }
    }

    /// Run the on-device formatting pass on the final transcript when enabled
    /// and available; otherwise return it unchanged. Never throws.
    private func formatFinalTranscript(_ raw: String) async -> String {
        guard state.itnEnabled, !raw.isEmpty,
              FormattingHeuristic.mightNeedFormatting(raw)
        else { return raw }
        let formatter = await TextFormatterProvider.shared.current()
        guard formatter.isAvailable else { return raw }
        // Instant rules need no status; only the LLM pass shows "Formatting…".
        if !formatter.isInstant { state.statusMessage = "Formatting…" }
        return await formatter.format(raw)
    }

    func cancelSession() {
        microphoneCapture.stop()
        Task {
            await transcriber.cancel()
            await MainActor.run {
                self.state.phase = .idle
                self.state.audioLevel = 0
                self.state.statusMessage = "Session cancelled."
            }
        }
    }

    func cancelModelPreparation() {
        preparationTask?.cancel()
        preparationTask = nil

        if let preparingEngine = state.preparingEngine {
            state.preparingEngine = nil
            state.download = nil
            state.statusMessage = "\(preparingEngine.userFacingName) setup cancelled."
        }

        if case .preparingModels = state.phase {
            state.phase = .idle
        }
    }

    func shutdown() {
        correctionLearner.cancel()
        preparationTask?.cancel()
        microphoneCapture.stop()
        pendingAppendTasks.values.forEach { $0.cancel() }
        pendingAppendTasks.removeAll()
    }

    private func enqueueAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        let id = UUID()
        let task = Task { [transcriber] in
            try? await transcriber.append(buffer)
            return
        }
        pendingAppendTasks[id] = task

        Task { @MainActor in
            await task.value
            pendingAppendTasks[id] = nil
        }
    }

    private func drainPendingAudioBuffers() async {
        let tasks = Array(pendingAppendTasks.values)
        pendingAppendTasks.removeAll()

        for task in tasks {
            await task.value
        }
    }

    func toggleAccessibilityHelp() {
        permissionsManager.openAccessibilitySettings()
    }

    func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func pasteText(_ text: String) {
        copyToClipboard(text)
        // The user is recovering the text, so retract the "nowhere to paste" hint.
        state.undeliveredTranscriptAt = nil
        guard permissionsManager.accessibilityGranted() else {
            state.statusMessage = "Copied to clipboard. Enable Accessibility for auto-paste."
            return
        }
        Task { [textInjector] in
            await textInjector.inject(text)
        }
    }

    func pasteLastTranscript() {
        guard let entry = state.history.first else { return }
        pasteText(entry.text)
    }

    func deleteHistoryEntry(_ id: UUID) {
        state.removeHistoryEntry(id)
    }

    func clearAllHistory() {
        state.clearHistory()
    }

    func handleHotkeyPressed() {
        guard state.holdToTalkEnabled else { return }
        if state.preparingEngine != nil {
            state.statusMessage = "Voice engine is still getting ready."
            return
        }
        if state.canStart {
            startRecording()
        }
    }

    func handleHotkeyReleased() {
        guard state.holdToTalkEnabled else { return }
        if state.canStop {
            stopRecording()
        }
    }

    func updateHotkey(_ hotkey: HotkeyManager.HotkeyOption) {
        state.hotkey = hotkey
        hotkeyUpdater(hotkey)
    }

    func selectEngine(_ engine: TranscriberEngine) {
        guard state.selectedEngine != engine else { return }
        state.selectedEngine = engine
        state.download = nil
        state.statusMessage = "Getting voice engine ready..."
        prepareSelectedEngineInBackground()
    }

    func prepareDefaultEngineOnLaunch() {
        state.statusMessage = "Getting voice engine ready..."
        prepareSelectedEngineInBackground()
    }

    func prepareSelectedEngineInBackground() {
        let engine = state.selectedEngine
        guard state.preparedEngine != engine, state.preparingEngine != engine else { return }

        // A prior background prep may have left the phase in `.failed`; clear it
        // so the retry starts from a clean state (the recording path never hits
        // this method, so we won't stomp on a `.preparingModels`/`.recording` phase).
        if case .failed = state.phase {
            state.phase = .idle
        }

        preparationTask?.cancel()
        preparationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.prepareEngine(engine)
            } catch {
                guard !Task.isCancelled else { return }
                await self.handlePreparationFailure(error, engine: engine)
            }
        }
    }

    private func handleFailure(_ error: Error) async {
        microphoneCapture.stop()
        await transcriber.cancel()
        await MainActor.run {
            self.state.phase = .failed(error.localizedDescription)
            self.state.audioLevel = 0
            self.state.statusMessage = "Transcription failed: \(error.localizedDescription)"
        }
    }

    private func handlePreparationFailure(_ error: Error, engine: TranscriberEngine) async {
        await MainActor.run {
            if self.state.preparingEngine == engine {
                self.state.preparingEngine = nil
                self.state.download = nil
            }
            self.state.phase = .failed(error.localizedDescription)
            self.state.statusMessage = "Couldn't get the voice engine ready. Check your connection and try again."
        }
    }

    private static func detailText(for snapshot: DownloadUtils.DownloadProgress) -> String {
        switch snapshot.phase {
        case .listing:
            return "Checking voice engine..."
        case .downloading(let completedFiles, let totalFiles):
            if totalFiles > 0 {
                return "Downloading voice engine (\(completedFiles)/\(totalFiles))..."
            }
            return "Downloading voice engine..."
        case .compiling:
            return "Optimizing voice engine..."
        }
    }

    private func prepareSelectedEngineIfNeeded() async throws {
        let engine = state.selectedEngine
        if state.preparedEngine == engine { return }
        try await prepareEngine(engine)
    }

    private func prepareEngine(_ engine: TranscriberEngine) async throws {
        if state.preparedEngine == engine { return }

        state.preparingEngine = engine
        state.download = nil
        state.usingFallbackModelSource = false
        state.statusMessage = engine.isInstalled
            ? "Loading voice engine..."
            : "Downloading voice engine..."

        await installModelsFromMirror(engine)
        try await transcriber.prepareModels { [weak self] snapshot in
            Task { @MainActor in
                guard let self, self.state.preparingEngine == engine else { return }
                let detail = Self.detailText(for: snapshot)
                // If the mirror fell through, FluidAudio is now pulling from
                // HuggingFace — say so, so a slow download is explained.
                let shown = self.state.usingFallbackModelSource ? "\(detail) (backup source)" : detail
                self.state.download = ModelDownloadSnapshot(
                    fractionCompleted: snapshot.fractionCompleted,
                    detail: shown
                )
                self.state.statusMessage = shown
            }
        }

        guard !Task.isCancelled else { return }
        Log.modelPrep.notice("Voice engine ready (\(engine.displayName, privacy: .public))")
        Task {
            let formatter = await TextFormatterProvider.shared.current()
            Log.formatter.notice("formatter: \(String(describing: type(of: formatter)), privacy: .public)")
            await formatter.prewarm()
        }
        state.preparedEngine = engine
        state.preparingEngine = nil
        state.download = nil
        state.usingFallbackModelSource = false
        state.statusMessage = "Voice engine ready."
    }

    /// Prefer the fast R2 model mirror (accurate %, free egress); on any
    /// failure fall through so FluidAudio downloads from HuggingFace as before.
    private func installModelsFromMirror(_ engine: TranscriberEngine) async {
        do {
            try await ModelInstaller.installIfNeeded(engine) { [weak self] progress in
                Task { @MainActor in
                    guard let self, self.state.preparingEngine == engine else { return }
                    self.state.usingFallbackModelSource = false
                    self.state.download = ModelDownloadSnapshot(
                        fractionCompleted: progress.fractionCompleted,
                        detail: progress.detail
                    )
                    self.state.statusMessage = progress.detail
                }
            }
        } catch {
            // The mirror is down/stalled even after retries; FluidAudio's
            // prepareModels will now download from HuggingFace (slower). Make it
            // loud (persisted log) and visible (status), never a silent freeze.
            Log.modelPrep.error(
                "R2 mirror unavailable for \(engine.displayName, privacy: .public) after retries; falling back to HuggingFace: \(error.localizedDescription, privacy: .public)")
            await MainActor.run {
                guard self.state.preparingEngine == engine else { return }
                self.state.usingFallbackModelSource = true
                self.state.statusMessage = "Mirror unavailable — downloading from backup source (slower)…"
            }
        }
    }

    private func applyTranscriptUpdate(_ update: StreamingTranscriptUpdate) {
        if update.isConfirmed, !update.confirmedText.isEmpty {
            rawConfirmedTranscript = TranscriptMerger.mergedConfirmed(
                current: rawConfirmedTranscript,
                new: update.confirmedText
            )
            state.transcript.latestConfirmed = filterFillersIfEnabled(rawConfirmedTranscript)
        }

        // Keep the full volatile window for salvage; the pill preview can use
        // the shorter latest hypothesis for snappier live feedback.
        rawVolatileTranscript = update.partialText
        let latestSource = !update.latestText.isEmpty ? update.latestText : update.partialText
        let remainder = TranscriptMerger.partialRemainder(
            partialText: latestSource,
            confirmedText: rawConfirmedTranscript
        )
        state.transcript.latestPartial = filterFillersIfEnabled(remainder)
    }

    /// What streaming already produced (confirmed + current volatile window) —
    /// the last-resort fallback if the transcriber itself couldn't return text.
    private func salvagedStreamingTranscript() -> String {
        TranscriptMerger.bestEffort(
            confirmed: rawConfirmedTranscript,
            volatile: rawVolatileTranscript
        )
    }

    private func filterFillersIfEnabled(_ text: String) -> String {
        state.removeFillerWordsEnabled ? FillerWordFilter.clean(text) : text
    }

    private func injectFinalTextIfPossible(_ text: String) async {
        guard permissionsManager.accessibilityGranted() else {
            await MainActor.run {
                self.state.statusMessage = "Transcript ready. Enable Accessibility for auto-paste."
            }
            return
        }

        // Nothing editable is focused, so synthesized keystrokes would vanish.
        // The transcript is already in history, so surface a notch hint telling
        // the user where it went instead of typing into the void.
        if FocusedElementInspector.noEditableTarget() {
            state.undeliveredTranscriptAt = Date()
            state.statusMessage = "No text field focused. Saved to history. Press ⇧⌘V to paste."
            return
        }

        await textInjector.inject(text)
        await MainActor.run {
            self.state.statusMessage = "Finished local transcription and pasted at cursor."
        }
        if state.learnCorrectionsEnabled {
            correctionLearner.watch(injected: text) { [weak self] correction in
                guard let self else { return }
                self.state.learnVocabularyCorrection(
                    canonical: correction.typed,
                    heard: correction.heard
                )
                // Surface the otherwise-silent addition as a brief notch banner.
                self.state.learnedTerm = correction.typed
                self.state.learnedTermAt = Date()
                self.state.statusMessage =
                    "Learned \"\(correction.typed)\" — added to Words to get right."
            }
        }
    }
}
