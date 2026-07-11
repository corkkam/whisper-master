import AppKit
import ApplicationServices
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
    /// Owns the optional on-device cleanup model: background download, progress
    /// (Settings only), and the one-shot ready banner. Dormant unless opted in.
    private lazy var cleanupModelManager = CleanupModelManager(state: state)
    /// Watches pasted text for the user's fix-ups and grows the vocabulary.
    private let correctionLearner = CorrectionLearner()
    /// The in-flight background polish for the last dictation (qwen cleanup +
    /// in-place refine). Cancelled when a new recording starts so a stale refine
    /// never edits the next session's field.
    private var refinementTask: Task<Void, Never>?
    /// Merge accumulator for confirmed streaming chunks. Kept unfiltered so
    /// `TranscriptMerger`'s overlap detection always compares raw engine text
    /// against raw engine text; only what goes into `state` is filler-filtered.
    private var rawConfirmedTranscript = ""
    /// Latest full volatile track from the engine (the current sliding window),
    /// kept so a failed/empty engine finish can still deliver what streaming
    /// produced. The full window — not the truncated live-pill remainder.
    private var rawVolatileTranscript = ""
    /// Smooths the raw per-buffer mic level (fast attack, slow decay) so the
    /// notch wave breathes instead of snapping to zero between words.
    private var levelEnvelope = LevelEnvelope()
    /// Auto-clears a lingering `.failed` phase back to `.idle` so a failure
    /// message doesn't sit in the notch forever.
    private var failedResetTask: Task<Void, Never>?

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

        // Open a diagnostics session at the true key-press instant (this runs
        // synchronously from the hotkey handler). No-op unless a DIAGNOSTICS build.
        Diagnostics.shared.begin(context: makeDiagnosticsContext())

        // A reminder showing now would be replaced by the live indicator anyway.
        reminderScheduler.clear()
        // A new dictation supersedes any correction watch or pending polish on
        // the previous one.
        correctionLearner.cancel()
        refinementTask?.cancel()
        // Any pending "nowhere to paste" hint, success beat, or failure message
        // is stale once a new session starts.
        state.undeliveredTranscriptAt = nil
        state.deliveredAt = nil
        state.failedAt = nil
        failedResetTask?.cancel()
        levelEnvelope.reset()

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
                Diagnostics.shared.mark(.engineStarted)

                try microphoneCapture.start(
                    bufferHandler: { [weak self] buffer in
                        guard let self else { return }
                        Task { @MainActor in
                            self.enqueueAudioBuffer(buffer)
                        }
                    },
                    levelHandler: { [weak self] level in
                        Task { @MainActor in
                            guard let self else { return }
                            self.state.audioLevel = self.levelEnvelope.step(target: level)
                        }
                    }
                )
                Diagnostics.shared.mark(.micStarted)
                Diagnostics.shared.noteInputDevice(
                    name: AudioInputDevices.currentInputName(),
                    isBluetooth: state.bluetoothInputActive)

                recordingStartedAt = Date()
                state.phase = .recording
                state.statusMessage = "Recording with \(state.selectedEngine.displayName)..."
                Feedback.start(soundEnabled: state.soundEnabled)
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
        levelEnvelope.reset()
        state.statusMessage = "Catching final words..."
        Feedback.stop(soundEnabled: state.soundEnabled)
        Diagnostics.shared.mark(.stopRequested)

        Task {
            do {
                try? await Task.sleep(nanoseconds: releaseTailNanoseconds)
                microphoneCapture.stop()
                await drainPendingAudioBuffers()
                state.statusMessage = "Finalizing local transcript..."
                Diagnostics.shared.mark(.finalizeStart)
                var rawFinal: String
                var usedSalvage = false
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
                    usedSalvage = true
                }
                Diagnostics.shared.noteRawAsr(rawFinal)
                // Repair spaces the ASR dropped at pause/segment boundaries
                // ("right?The" → "right? The") before the rest of the pipeline.
                let spaced = TranscriptSpacingRepair.repair(rawFinal)
                Diagnostics.shared.noteStage(.spacing, text: spaced)
                // Collapse spoken number self-corrections ("twenty no thirty" →
                // "thirty") before ITN, so the survivor is what gets formatted.
                let (corrected, selfCorrectionFixes) = SelfCorrectionCollapser.collapseCounting(spaced)
                Diagnostics.shared.noteStage(.selfCorrection, text: corrected)
                let formatted = await formatFinalTranscript(corrected)
                Diagnostics.shared.noteStage(.itn, text: formatted)
                // May leave the text empty (a recording that was only "hmm" /
                // a silence hallucination) — the guard below then skips
                // history and injection entirely.
                let (deFillered, fillerFixes): (String, Int) = state.removeFillerWordsEnabled
                    ? FillerWordFilter.cleanCounting(formatted)
                    : (formatted, 0)
                Diagnostics.shared.noteStage(.filler, text: deFillered)
                // Apply the glossary as a safe text replacement (casing + known
                // mishearings) — the substitute for FluidAudio's transcript-
                // corrupting streaming rescorer.
                let (cleaned, dictionaryFixes) = VocabularyPostProcessor.applyCounting(
                    deFillered, glossary: state.customVocabulary)
                Diagnostics.shared.noteStage(.vocab, text: cleaned)
                Diagnostics.shared.noteASR(
                    confirmedChars: rawConfirmedTranscript.count,
                    volatileChars: rawVolatileTranscript.count,
                    usedSalvage: usedSalvage)
                // Paste the deterministic cleanup *instantly* — dictation never
                // waits on the LLM. The optional on-device qwen polish then runs
                // in the background and refines this text in place a beat later
                // (see scheduleRefinement), so the field ends up as clean as if
                // we'd waited, but the user never did.
                state.phase = .idle
                state.transcript.finalText = cleaned
                guard !cleaned.isEmpty else {
                    // Nothing to paste (only "hmm" / a silence hallucination).
                    // Still record the session — an empty result is itself a
                    // "miss" worth inspecting, and the audio is captured.
                    Diagnostics.shared.finish(pasteOutcome: "empty", finalText: "")
                    state.statusMessage = "Finished local transcription."
                    return
                }
                state.transcript.latestConfirmed = cleaned
                state.transcript.latestPartial = ""
                let entryID = state.appendHistory(text: cleaned, engine: state.selectedEngine)
                reminderScheduler.noteUsed()
                let wordCount = WordCount.count(cleaned)
                Analytics.shared.send(.dictationCompleted(
                    engine: state.selectedEngine.rawValue,
                    duration: sessionDuration,
                    wordCount: wordCount
                ))
                // The frontmost app is the one about to receive the paste — we
                // don't steal focus, so it's still the user's target app.
                let front = NSWorkspace.shared.frontmostApplication
                Diagnostics.shared.noteFrontApp(
                    name: front?.localizedName ?? "unknown",
                    bundleID: front?.bundleIdentifier ?? "")
                // Fold this dictation into the durable usage stats (Insights
                // dashboard). Same front-app snapshot the diagnostics use — the
                // app about to receive the paste — now always-on, not DIAGNOSTICS.
                state.usageStore.record(DictationRecord(
                    timestamp: Date(),
                    wordCount: wordCount,
                    durationSeconds: sessionDuration,
                    appName: front?.localizedName ?? "",
                    appBundleID: front?.bundleIdentifier ?? "",
                    engineRawValue: state.selectedEngine.rawValue,
                    fixes: FixCounts(
                        wordsCorrected: selfCorrectionFixes + fillerFixes,
                        dictionary: dictionaryFixes)))
                // What AX sees at the moment we choose the paste route — the
                // evidence for building the "nowhere to type" classifier.
                Diagnostics.shared.noteFocus(FocusedElementInspector.focusDiagnostic())

                var pasteOutcome = "historyOnly"
                var pastedText = cleaned
                if state.autoPasteEnabled {
                    let result = await pasteFinal(cleaned, entryID: entryID)
                    pasteOutcome = result.outcome
                    pastedText = result.pasted
                    // Confirm the moment the text actually lands at the cursor:
                    // a checkmark beat + chime. Routes that pasted somewhere (a
                    // native field, web, or a terminal) count; the clipboard /
                    // no-Accessibility / secure-blocked routes already surface
                    // their own "press ⌘V" hint, so they don't.
                    let deliveredRoutes: Set<String> = ["native", "web", "terminal"]
                    if deliveredRoutes.contains(pasteOutcome), state.undeliveredTranscriptAt == nil {
                        state.deliveredAt = Date()
                        Feedback.delivered(soundEnabled: state.soundEnabled)
                    }
                } else {
                    scheduleRefinement(pasted: cleaned, entryID: entryID, target: nil)
                }
                Diagnostics.shared.notePolish(timing: polishTiming(for: pasteOutcome))
                Diagnostics.shared.finish(pasteOutcome: pasteOutcome, finalText: pastedText)
                state.statusMessage = "Finished local transcription."
            } catch {
                Diagnostics.shared.abandon()
                await handleFailure(error)
            }
        }
    }

    /// Kick the optional on-device qwen polish in the background and, when it
    /// produces a better transcript, rewrite the already-pasted text (and the
    /// saved history entry) in place — never blocking, since the deterministic
    /// text was already pasted. Also arms the correction learner on whatever text
    /// ends up on screen, so it never mistakes our own refine for a user fix-up.
    private func scheduleRefinement(pasted: String, entryID: UUID?, target: AXUIElement?) {
        refinementTask?.cancel()
        refinementTask = Task { [weak self] in
            guard let self else { return }
            var onScreen = pasted
            if let refined = await self.llmRefined(pasted), refined != pasted, !Task.isCancelled {
                if let target {
                    // We pasted into a live field — try to fix it in place. Only
                    // mirror the change into history if the field edit actually
                    // took, so history matches what the user sees.
                    let applied = await InPlaceRefiner.apply(
                        pasted: pasted, refined: refined, element: target, injector: self.textInjector)
                    if applied {
                        onScreen = refined
                        if let entryID { self.state.updateHistoryText(entryID, to: refined) }
                    }
                } else if let entryID {
                    // Nothing was pasted (no editable target) — history is the
                    // only artifact, so the polish belongs there.
                    self.state.updateHistoryText(entryID, to: refined)
                }
            }
            guard !Task.isCancelled else { return }
            self.armCorrectionLearner(for: onScreen, hasTarget: target != nil)
        }
    }

    /// Run the optional on-device qwen cleanup and return the polished text only
    /// if the feature is enabled, the model is loaded, and the output survives
    /// `CleanupFaithfulnessGuard`. Returns `nil` (→ keep the deterministic paste)
    /// otherwise. Near-instant when disabled or not-yet-ready.
    private func llmRefined(_ input: String) async -> String? {
        guard state.llmCleanupEnabled, !input.isEmpty else { return nil }
        guard await MlxCleanupService.shared.isReady else {
            Diagnostics.shared.noteLLM(ready: false, raw: nil, accepted: false, ms: 0)
            return nil
        }
        let polish = state.llmGrammarPolishEnabled
        let prompt = CleanupPrompt.resolved(grammarPolish: polish)
        let start = Date()
        let cleaned = await MlxCleanupService.shared.clean(input, systemPrompt: prompt)
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        let accepted = cleaned.map {
            CleanupFaithfulnessGuard.accept(original: input, cleaned: $0, allowRephrase: polish)
        } ?? false
        Diagnostics.shared.noteLLM(ready: true, raw: cleaned, accepted: accepted, ms: ms)
        guard let cleaned, accepted else { return nil }
        return cleaned
    }

    /// Start watching the pasted field for the user's own fix-ups (to grow the
    /// vocabulary). Deferred until after refinement so the baseline is the text
    /// actually on screen, and never armed when nothing was pasted.
    private func armCorrectionLearner(for text: String, hasTarget: Bool) {
        guard hasTarget, state.autoPasteEnabled, state.learnCorrectionsEnabled, !text.isEmpty else { return }
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

    /// Reconcile the cleanup model with the `llmCleanupEnabled` toggle. Called
    /// each refresh tick (edge-triggered inside, so it's a no-op unless the
    /// toggle changed): starts the background download on opt-in, frees the
    /// model on opt-out.
    func reconcileCleanupModel() {
        cleanupModelManager.syncWithToggle()
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
        refinementTask?.cancel()
        preparationTask?.cancel()
        microphoneCapture.stop()
        pendingAppendTasks.values.forEach { $0.cancel() }
        pendingAppendTasks.removeAll()
    }

    private func enqueueAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        Diagnostics.shared.noteAudioBuffer(buffer)
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
        // Real ⌘V (text is already on the clipboard) so it lands in web/Electron
        // apps too. Left on the clipboard on purpose — this is a recovery action.
        Task { [textInjector] in
            await textInjector.pressCommandV()
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
            self.levelEnvelope.reset()
            self.state.failedAt = Date()
            self.state.statusMessage = "Transcription failed: \(error.localizedDescription)"
            self.scheduleFailedReset()
        }
    }

    /// After a failure has been on screen for `failedBannerDuration`, quietly
    /// return to idle so the notch retracts instead of showing a stuck glyph.
    /// Guarded so a new recording (which flips the phase itself) isn't clobbered.
    private func scheduleFailedReset() {
        failedResetTask?.cancel()
        let failedStamp = state.failedAt
        failedResetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(AppState.failedBannerDuration * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            // Only reset if this is still the same failure (no new session began).
            if case .failed = self.state.phase, self.state.failedAt == failedStamp {
                self.state.phase = .idle
                self.state.failedAt = nil
            }
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

        // Warm the mic graph now (once, at launch) so the first push-to-talk
        // doesn't pay the cold Core Audio start that was clipping first words.
        // Only if the user already granted mic access — never prompt from here.
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
            microphoneCapture.prewarm()
        }
        // Keep it warm across AirPods connect/disconnect, which otherwise stales
        // the launch-time warm and brings the ~500ms cold start back.
        microphoneCapture.startAutoRewarm()
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
            Diagnostics.shared.noteFirstConfirmed()
            rawConfirmedTranscript = TranscriptMerger.mergedConfirmed(
                current: rawConfirmedTranscript,
                new: update.confirmedText
            )
            state.transcript.latestConfirmed = filterFillersIfEnabled(rawConfirmedTranscript)
        }

        if !update.partialText.isEmpty { Diagnostics.shared.noteFirstPartial() }
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

    /// Snapshot of the knobs that frame a diagnostics session (no-op build ignores it).
    private func makeDiagnosticsContext() -> SessionTrace.Context {
        SessionTrace.Context(
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
            engine: state.selectedEngine.rawValue,
            fillerFilter: state.removeFillerWordsEnabled,
            llmCleanup: state.llmCleanupEnabled,
            itn: state.itnEnabled,
            holdToTalk: state.holdToTalkEnabled,
            pasteOutcome: nil)
    }

    /// When the optional qwen polish runs relative to the paste, given the paste
    /// path. Web/Electron computes polish *before* the ⌘V; native pastes the
    /// deterministic text then refines in place *after*. Off (or no delivery) is
    /// `none`.
    private func polishTiming(for pasteOutcome: String) -> String {
        guard state.llmCleanupEnabled else { return "none" }
        switch pasteOutcome {
        case "web", "terminal": return "beforePaste"
        case "native", "clipboard", "noAccessibility": return "afterPaste"
        default: return "none"   // historyOnly / empty — nothing pasted
        }
    }

    /// Paste the finished transcript and set up polish, choosing the mechanism by
    /// what the focused field allows:
    ///  - **Native, Accessibility-readable field:** instant keystroke paste of the
    ///    deterministic text, then a background in-place refine (`scheduleRefinement`)
    ///    edits it to the polished version — the user never waits.
    ///  - **Web / Electron field (AX can't see it):** we can't safely edit in place,
    ///    so compute the polish *first* and paste the final text once with a real
    ///    ⌘V. Polish still applies; the only cost is the LLM's brief latency.
    ///  - **No editable focus:** copy to the clipboard and hint ⌘V; polish the
    ///    history entry in the background.
    /// Delivers the transcript and reports, for diagnostics, both the paste route
    /// (`noAccessibility` / `native` / `clipboard` / `web` / `terminal`) and the text that was
    /// *actually* pasted. Only the web path differs from the deterministic input —
    /// it pastes the polished text — but returning it keeps the trace honest
    /// instead of always recording the pre-polish string.
    @discardableResult
    private func pasteFinal(_ deterministic: String, entryID: UUID?) async -> (outcome: String, pasted: String) {
        guard permissionsManager.accessibilityGranted() else {
            copyToClipboard(deterministic)
            state.statusMessage = "Copied to clipboard, press ⌘V. Enable Accessibility for auto-paste."
            scheduleRefinement(pasted: deterministic, entryID: entryID, target: nil)
            return ("noAccessibility", deterministic)
        }

        // Terminals (Ghostty, Warp, Terminal.app, iTerm, …) always have a real
        // paste destination — the shell — but don't advertise it through AX the
        // way a native field does. GPU/custom terminals expose no caret (so they'd
        // be misread as "nowhere to type" below) and AppKit terminals report
        // `AXTextArea` (so they'd take the per-char inject path, which terminals
        // drop). Both honor a real ⌘V, so route any terminal straight to that path
        // and skip the AX-role branches. See `TerminalApps`.
        let isTerminal = TerminalApps.frontmostIsTerminal()

        if !isTerminal, let editable = FocusedElementInspector.editableTarget() {
            await textInjector.inject(deterministic)
            state.statusMessage = "Finished local transcription and pasted at cursor."
            scheduleRefinement(pasted: deterministic, entryID: entryID, target: editable)
            return ("native", deterministic)
        }

        if !isTerminal, FocusedElementInspector.focusHasNoTextTarget() {
            copyToClipboard(deterministic)
            state.undeliveredTranscriptAt = Date()
            state.statusMessage = "No text field found. Copied to clipboard, press ⌘V to paste."
            scheduleRefinement(pasted: deterministic, entryID: entryID, target: nil)
            return ("clipboard", deterministic)
        }

        // Terminal / Web / Electron: Accessibility can't (safely) read the field,
        // so in-place refine isn't safe. Polish up front (best-effort — nil keeps
        // the deterministic text), then paste the final result once with a real
        // ⌘V, which these apps honor. This is how polish reaches WhatsApp, Slack,
        // browsers, and the shell.
        if state.llmCleanupEnabled { state.statusMessage = "Polishing\u{2026}" }
        let finalText = (await llmRefined(deterministic)) ?? deterministic
        // Secure Keyboard Entry (Terminal's menu, or any focused password field)
        // makes the WindowServer swallow the synthesized ⌘V too. A blind paste
        // would fail *and* `pasteViaClipboard` would then restore the old clipboard
        // out from under the user — so leave the transcript on the clipboard for a
        // manual ⌘V and say why nothing landed.
        if isTerminal, TerminalApps.secureKeyboardEntryEnabled() {
            copyToClipboard(finalText)
            state.undeliveredTranscriptAt = Date()
            state.statusMessage = "Secure Keyboard Entry is on — auto-paste blocked. "
                + "Turn it off (Terminal: Shell → Secure Keyboard Entry), or press ⌘V. "
                + "Text is on the clipboard."
        } else {
            await pasteViaClipboard(finalText)
            state.statusMessage = "Finished local transcription and pasted at cursor."
        }
        if finalText != deterministic, let entryID {
            state.updateHistoryText(entryID, to: finalText)
        }
        return (isTerminal ? "terminal" : "web", finalText)
    }

    /// Paste `text` with a real ⌘V — a system paste that lands in web/Electron
    /// apps, unlike synthesized per-character key events. Saves and restores the
    /// user's clipboard around the paste, and only restores if the transcript is
    /// still there, so it never clobbers something copied in the meantime.
    private func pasteViaClipboard(_ text: String) async {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        copyToClipboard(text)
        await textInjector.pressCommandV()
        try? await Task.sleep(nanoseconds: 600_000_000)
        if pasteboard.string(forType: .string) == text {
            pasteboard.clearContents()
            if let saved { pasteboard.setString(saved, forType: .string) }
        }
    }
}
