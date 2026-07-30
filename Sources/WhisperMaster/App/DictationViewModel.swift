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
    /// Applies a change to the dedicated day-query hotkey to the live monitor.
    /// Settable by the App layer (which owns the second `HotkeyManager`); defaults
    /// to a no-op so tests/headless construction don't need it.
    var dayQueryHotkeyUpdater: (HotkeyManager.HotkeyOption) -> Void = { _ in }
    private let transcriber: FluidAudioStreamingTranscriber
    private let textInjector: TextInjector
    private var pendingAppendTasks: [UUID: Task<Void, Never>] = [:]
    private var preparationTask: Task<Void, Never>?
    private let releaseTailNanoseconds: UInt64 = 80_000_000
    /// When the current recording actually started capturing, for the analytics
    /// duration bucket. `nil` between sessions.
    private var recordingStartedAt: Date?
    /// True when the current session was started by the dedicated "ask about my
    /// day" hotkey — its finished transcript is answered from the connectors and
    /// shown in the notch instead of being pasted. Consumed (and reset) at stop.
    private var dayQueryArmed = false
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
    /// Running text from the transcriber's low-latency **preview** track, which
    /// lands seconds before the accurate track says anything at all. It exists to
    /// fill the notch while you're still speaking and is **display-only**: it is
    /// never merged into `rawConfirmedTranscript`/`rawVolatileTranscript`, so it
    /// can't reach the paste, the history, the salvage path, or the cleanup passes.
    private var previewTranscript = ""
    /// The accurate track's newest hypothesis for the current window — the tail
    /// shown after `rawConfirmedTranscript`. Held as state so the display can be
    /// recomputed when only the preview track ticked.
    private var latestHypothesis = ""
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

    /// Fires due automations. Driven from the same 0.5 s refresh tick — see
    /// `AutomationScheduler` for the catch-up and overlap policies.
    func tickAutomations() {
        guard state.connectorAgentEnabled else { return }
        automationScheduler.tick()
    }

    /// Run one automation now, from the Settings list.
    func runAutomationNow(_ task: ScheduledTask) {
        automationScheduler.runNow(task)
    }

    /// Drives scheduled automations. Lazy so nothing is constructed for a user who
    /// never opts in.
    private lazy var automationScheduler = AutomationScheduler(
        store: state.automationStore,
        runner: { [weak self] task, trigger in
            await self?.runAutomation(task, trigger: trigger)
                ?? TaskRun(taskID: task.id, status: .failed, answer: "Cancelled.", trigger: trigger)
        })

    /// One automation firing: ask its question through the same agent a spoken query
    /// uses, `unattended` so an unapproved write is denied rather than raising a card
    /// nobody is there to read.
    private func runAutomation(_ task: ScheduledTask, trigger: String) async -> TaskRun {
        var run = TaskRun(taskID: task.id, trigger: trigger)
        guard await MlxCleanupService.shared.isReady else {
            run.status = .failed
            run.answer = "The on-device model wasn't ready."
            run.finishedAt = Date()
            return run
        }
        let agent = ConnectorAgentService(store: state.connectorStore, approvals: state.approvals)
        let outcome = await agent.answer(
            question: task.instructions,
            unattended: true,
            generate: ConnectorAgentService.liveGenerator())
        if let outcome {
            run.status = .ok
            run.answer = outcome.answer
            // Surface it where the user already looks. A scheduled answer nobody sees
            // is a scheduled answer that didn't happen.
            state.activeDaySummary = DaySummary(
                headline: task.title, detail: outcome.answer,
                events: [], gaps: [], scopedTo: nil)
            state.daySummaryAt = Date()
        } else {
            // Fall back to the deterministic summary rather than reporting nothing.
            let summary = await DaySummaryService.buildAsync(store: state.connectorStore)
            run.status = .ok
            run.answer = "\(summary.headline). \(summary.detail)"
            state.activeDaySummary = summary
            state.daySummaryAt = Date()
        }
        run.finishedAt = Date()
        return run
    }

    func startRecording(dayQuery: Bool = false) {
        guard state.canStart else { return }
        // Every session begins as a normal dictation unless the dedicated day-query
        // hotkey armed it — reset here so a stale arm can't leak into the next one.
        dayQueryArmed = dayQuery

        // Open a diagnostics session at the true key-press instant (this runs
        // synchronously from the hotkey handler). No-op unless a DIAGNOSTICS build.
        Diagnostics.shared.begin(context: makeDiagnosticsContext())

        // A reminder showing now would be replaced by the live indicator anyway.
        reminderScheduler.clear()
        // A new dictation supersedes any correction watch or pending polish on
        // the previous one.
        correctionLearner.cancel()
        refinementTask?.cancel()
        // Any pending "nowhere to paste" hint, success beat, polish result, or
        // failure message is stale once a new session starts.
        state.undeliveredTranscriptAt = nil
        state.undeliveredText = nil
        state.deliveredAt = nil
        state.failedAt = nil
        state.isPolishing = false
        state.polishedText = nil
        state.polishedAt = nil
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
        previewTranscript = ""
        latestHypothesis = ""
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
        // Consume the day-query arm now (synchronously, at the user's stop) so it
        // can't linger; the async finalize below reads this captured copy.
        let queryMode = dayQueryArmed
        dayQueryArmed = false

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
                // A "what's my day" question? Either the dedicated day-query hotkey
                // was held (queryMode), or the transcript itself opens with a
                // day-query wake phrase (only honored when the user actually has a
                // connector on, so it can't hijack an ordinary dictation). The
                // paste is *suppressed* — the words asked for an answer, which lands
                // in the notch instead of the cursor.
                let connectorsActive = state.connectorStore.hasReadableCalendar
                if queryMode || (connectorsActive && DayQueryDetector.matches(cleaned)) {
                    await runDayQuery(cleaned)
                    reminderScheduler.noteUsed()
                    Diagnostics.shared.finish(pasteOutcome: "dayQuery", finalText: cleaned)
                    state.statusMessage = "Answered from your connectors."
                    return
                }
                // A spoken command? The cheap keyword gate runs first (ordinary
                // dictation pays nothing); only a command-looking transcript
                // consults the on-device decision-maker, which routes it into
                // Notes & Reminders and can still veto a false positive. When it
                // routes, the paste is *suppressed* — the words became a note or
                // reminder, not text to type — so we finish here.
                if await routeVoiceCommandIfNeeded(cleaned) {
                    reminderScheduler.noteUsed()
                    Diagnostics.shared.finish(pasteOutcome: "command", finalText: cleaned)
                    state.statusMessage = "Saved to Notes & Reminders."
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
                        self.notePolished(refined)
                    }
                } else {
                    // Nothing was pasted (no editable target) — history and the
                    // clipboard are the only artifacts, so the polish belongs
                    // there, and the notch hint should offer the better wording.
                    if let entryID { self.state.updateHistoryText(entryID, to: refined) }
                    self.adoptPolishedUndelivered(was: pasted, now: refined)
                    self.notePolished(refined)
                }
            }
            guard !Task.isCancelled else { return }
            self.armCorrectionLearner(for: onScreen, hasTarget: target != nil)
        }
    }

    /// Show the polished wording in the notch for a beat. Called only from the
    /// paths where the polish actually reached the user (pasted, edited in place,
    /// or left on the clipboard) — a rewrite the user never received would be a
    /// lie on the band.
    private func notePolished(_ text: String) {
        state.polishedText = text
        state.polishedAt = Date()
    }

    /// A polish landed for a transcript that had nowhere to paste. Point the
    /// notch hint (and its Copy button) at the better wording, and swap the
    /// clipboard over too — but only if our own text is still on it, so a copy
    /// the user made in the meantime is never clobbered.
    private func adoptPolishedUndelivered(was deterministic: String, now refined: String) {
        guard state.undeliveredTranscriptAt != nil || state.undeliveredText == deterministic else { return }
        state.undeliveredText = refined
        if NSPasteboard.general.string(forType: .string) == deterministic {
            copyToClipboard(refined)
        }
    }

    /// Run the optional on-device qwen cleanup and return the polished text only
    /// if the feature is enabled, the model is loaded, and the output survives
    /// `CleanupFaithfulnessGuard`. Returns `nil` (→ keep the deterministic paste)
    /// otherwise. Near-instant when disabled or not-yet-ready.
    ///
    /// Flips `state.isPolishing` for the duration so the notch orb can show the
    /// "thinking" figure while the model works — the text is already delivered,
    /// so this is a progress signal, never a block.
    private func llmRefined(_ input: String) async -> String? {
        guard state.llmCleanupEnabled, !input.isEmpty else { return nil }
        guard await MlxCleanupService.shared.isReady else {
            Diagnostics.shared.noteLLM(ready: false, raw: nil, accepted: false, ms: 0)
            return nil
        }
        state.isPolishing = true
        defer { state.isPolishing = false }
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

    // MARK: - Day query (Connectors)

    /// Answer a "what's my day" question from the connector instances and drop the
    /// answer into the notch.
    ///
    /// The question text is passed through so a query that **names** an instance
    /// ("what's on my work calendar") is scoped to it; an unqualified one merges every
    /// enabled calendar instance. Instances that couldn't be read are reported as gaps
    /// rather than silently reducing the answer.
    private func runDayQuery(_ question: String) async {
        // If a calendar connector is on but access was never requested, ask now —
        // the user just explicitly asked about their day.
        if state.connectorStore.hasReadableCalendar, CalendarConnector.shared.isUndetermined {
            let granted = await CalendarConnector.shared.requestAccess()
            state.connectorStore.calendarAccessGranted = granted
            if granted {
                for kind in ConnectorKind.allCases {
                    state.connectorStore.clearErrors(ofKind: kind, matching: .needsCalendarAccess)
                }
            }
        }
        // Try the local tool-calling loop first when the user opted in. It falls back
        // to the deterministic summary on any failure — a malformed call, an unknown
        // tool, an exhausted budget — so the notch always answers with something true.
        if state.connectorAgentEnabled, await MlxCleanupService.shared.isReady {
            let agent = ConnectorAgentService(store: state.connectorStore, approvals: state.approvals)
            if let outcome = await agent.answer(
                question: question, generate: ConnectorAgentService.liveGenerator()) {
                state.activeDaySummary = DaySummary(
                    headline: outcome.answer,
                    detail: outcome.instanceLabels.isEmpty
                        ? ""
                        : "From \(Set(outcome.instanceLabels).sorted().joined(separator: ", "))",
                    events: [], gaps: [], scopedTo: nil)
                state.daySummaryAt = Date()
                Feedback.delivered(soundEnabled: state.soundEnabled)
                return
            }
        }
        let summary = await DaySummaryService.buildAsync(store: state.connectorStore, spokenQuery: question)
        state.activeDaySummary = summary
        state.daySummaryAt = Date()
        Feedback.delivered(soundEnabled: state.soundEnabled)
    }

    /// The dedicated "ask about my day" hotkey was pressed — start a recording
    /// armed as a day query (its transcript is answered, not pasted).
    func handleDayQueryHotkeyPressed() {
        guard state.holdToTalkEnabled else { return }
        if state.preparingEngine != nil {
            state.statusMessage = "Voice engine is still getting ready."
            return
        }
        if state.canStart {
            startRecording(dayQuery: true)
        }
    }

    func handleDayQueryHotkeyReleased() {
        guard state.holdToTalkEnabled else { return }
        if state.canStop {
            stopRecording()
        }
    }

    func updateDayQueryHotkey(_ hotkey: HotkeyManager.HotkeyOption) {
        state.dayQueryHotkey = hotkey
        dayQueryHotkeyUpdater(hotkey)
    }

    // MARK: - Voice commands (Notes & Reminders)

    /// Route a finished transcript into Notes & Reminders when it opens like a
    /// spoken command. Returns `true` when it handled the text (the caller then
    /// suppresses the paste). Cheap `CommandDetector` gate first — ordinary
    /// dictation never touches the model; a command-looking transcript consults
    /// the on-device decision-maker, which extracts the pieces and can still veto
    /// a false positive (→ `.dictation`, returns `false`, paste as usual).
    private func routeVoiceCommandIfNeeded(_ text: String) async -> Bool {
        guard state.voiceCommandsEnabled else { return false }
        guard let detected = CommandDetector.detect(text) else { return false }
        let intent = await classifyIntent(text, fallback: detected)
        switch intent.kind {
        case .dictation:
            return false
        case .note:
            createNote(from: intent, fallbackBody: detected.payload)
            return true
        case .reminder:
            createReminder(from: intent, fallbackTitle: detected.payload)
            return true
        }
    }

    /// Ask the on-device model to classify + extract, but only when it's already
    /// loaded — a command must never block on a cold model download. Falls back
    /// to the deterministic mapping of the keyword gate otherwise (so a reminder
    /// still lands, just with no extracted time → the default-time path asks).
    private func classifyIntent(_ text: String, fallback: DetectedCommand) async -> ClassifiedIntent {
        guard await MlxCleanupService.shared.isReady else { return ClassifiedIntent(fallback) }
        guard let raw = await MlxCleanupService.shared.clean(text, systemPrompt: IntentPrompt.system),
              let parsed = IntentClassifier.parse(raw)
        else { return ClassifiedIntent(fallback) }
        return parsed
    }

    private func createNote(from intent: ClassifiedIntent, fallbackBody: String) {
        let body = intent.body.isEmpty ? fallbackBody : intent.body
        state.notesStore.upsertNote(Note(title: intent.title, body: body))
        state.commandConfirmation = "Note saved"
        state.commandConfirmationAt = Date()
        Feedback.delivered(soundEnabled: state.soundEnabled)
    }

    private func createReminder(from intent: ClassifiedIntent, fallbackTitle: String) {
        let now = Date()
        let stated = intent.timePhrase.flatMap { RelativeTimeParser.parse($0, now: now) }
        let due = stated ?? Self.defaultReminderDue(now: now)
        let title = intent.title.isEmpty ? fallbackTitle : intent.title
        state.notesStore.upsertReminder(ReminderItem(
            title: title,
            body: intent.body,
            dueDate: due,
            alertStyle: state.reminderDefaultAlertStyle,
            soundName: state.reminderDefaultSound))
        let when = Self.reminderTimeString(due, now: now)
        // A stated time is set; an unstated one gets a default the user can adjust
        // by tapping the banner (→ Settings → Notes & Reminders).
        state.commandConfirmation = stated != nil
            ? "Reminder set for \(when)"
            : "Reminder set for \(when) · tap to change"
        state.commandConfirmationAt = now
        Feedback.delivered(soundEnabled: state.soundEnabled)
    }

    /// Default due time for a reminder whose "when?" wasn't stated (or couldn't be
    /// parsed): one hour out — the same default the manual "Add reminder" uses.
    private static func defaultReminderDue(now: Date) -> Date {
        Calendar.current.date(byAdding: .hour, value: 1, to: now) ?? now.addingTimeInterval(3600)
    }

    /// A short, human due-time label for the confirmation banner: "5:00 PM" today,
    /// "tomorrow 9:00 AM", else "Mon 9:00 AM".
    private static func reminderTimeString(_ date: Date, now: Date) -> String {
        let cal = Calendar.current
        let f = DateFormatter()
        if cal.isDate(date, inSameDayAs: now) {
            f.dateFormat = "h:mm a"
        } else if let tomorrow = cal.date(byAdding: .day, value: 1, to: now),
                  cal.isDate(date, inSameDayAs: tomorrow) {
            f.dateFormat = "'tomorrow' h:mm a"
        } else {
            f.setLocalizedDateFormatFromTemplate("EEE h mm a")
        }
        return f.string(from: date)
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

    /// The Copy button on the "nowhere to type that" notch hint. Puts the
    /// transcript on the clipboard — the polished wording when the on-device pass
    /// produced one — and leaves the hint up, since the user may still be looking
    /// for somewhere to put it. Falls back to the newest history entry if the
    /// transient text has already been cleared.
    func copyUndeliveredTranscript() {
        let text = state.undeliveredText ?? state.history.first?.text ?? ""
        guard !text.isEmpty else { return }
        copyToClipboard(text)
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

    /// First-launch / post-auth engine prep. Downloads the voice model only when
    /// it is not already installed at the local path; otherwise loads the
    /// existing install. Safe to call repeatedly — no-ops while the same engine
    /// is already prepared or mid-prep.
    func prepareDefaultEngineOnLaunch() {
        let engine = state.selectedEngine
        if state.preparedEngine == engine { return }
        if state.preparingEngine == engine { return }
        state.statusMessage = engine.isInstalled
            ? "Loading voice engine..."
            : "Downloading voice engine..."
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
        // The preview track only ever paints the notch. Nothing here may touch the
        // raw accumulators — they are what `stop()` salvages and what gets pasted.
        if update.isPreview {
            previewTranscript = TranscriptMerger.tidiedPreview(
                TranscriptMerger.bestEffort(
                    confirmed: update.confirmedText,
                    volatile: update.partialText
                )
            )
            refreshLiveTranscriptDisplay()
            return
        }

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
        latestHypothesis = !update.latestText.isEmpty ? update.latestText : update.partialText
        refreshLiveTranscriptDisplay()
    }

    /// Put the best live text we have on the notch.
    ///
    /// Two tracks feed this. The accurate one says nothing for its first
    /// `chunkSeconds + rightContextSeconds` of audio (13 s as shipped), so until it
    /// speaks up the notch shows the **preview** track — all of it in volatile ink,
    /// since none of it is locked in. The moment the accurate track produces
    /// anything it owns the display outright and the preview steps aside.
    ///
    /// The two are deliberately **not** blended: the preview decodes its own
    /// windows, so its wording won't be an exact prefix of the confirmed text and
    /// `partialRemainder` would fail to find the seam and duplicate the whole
    /// tail. Handover is near-seamless anyway — by the time the accurate track
    /// confirms, its confirmed+volatile pair covers everything the preview did.
    private func refreshLiveTranscriptDisplay() {
        guard rawConfirmedTranscript.isEmpty, latestHypothesis.isEmpty else {
            state.transcript.latestConfirmed = filterFillersIfEnabled(rawConfirmedTranscript)
            state.transcript.latestPartial = filterFillersIfEnabled(
                TranscriptMerger.partialRemainder(
                    partialText: latestHypothesis,
                    confirmedText: rawConfirmedTranscript
                )
            )
            return
        }

        state.transcript.latestConfirmed = ""
        state.transcript.latestPartial = filterFillersIfEnabled(previewTranscript)
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
            // Nothing was typed anywhere, so this needs the same visible recovery
            // as the no-text-field case: the words on the band plus a Copy button.
            state.undeliveredText = deterministic
            state.undeliveredTranscriptAt = Date()
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
            state.undeliveredText = deterministic
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
            state.undeliveredText = finalText
            state.undeliveredTranscriptAt = Date()
            state.statusMessage = "Secure Keyboard Entry is on — auto-paste blocked. "
                + "Turn it off (Terminal: Shell → Secure Keyboard Entry), or press ⌘V. "
                + "Text is on the clipboard."
        } else {
            await pasteViaClipboard(finalText)
            state.statusMessage = "Finished local transcription and pasted at cursor."
        }
        if finalText != deterministic {
            if let entryID { state.updateHistoryText(entryID, to: finalText) }
            // The polish happened *before* this paste, so the words that landed
            // are already the good ones — show them so the rewrite is visible.
            notePolished(finalText)
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
