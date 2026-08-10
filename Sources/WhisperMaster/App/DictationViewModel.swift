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
    /// Clears any half-finished press/tap gesture on the live monitor. Called
    /// whenever a session ends, so a hands-free latch established by a double-tap
    /// can never outlive the recording it was latching (a session stopped from the
    /// tray would otherwise leave the next single tap reading as a "stop").
    /// Settable by the App layer; no-op for headless construction.
    var hotkeyGestureReset: () -> Void = {}
    private let transcriber: FluidAudioStreamingTranscriber
    private let textInjector: TextInjector
    private var pendingAppendTasks: [UUID: Task<Void, Never>] = [:]
    private var preparationTask: Task<Void, Never>?
    /// This session's audio, kept in memory in case the capture turns into a spoken
    /// note — a note the user made by voice keeps the recording, so they can hear
    /// what they actually said rather than trusting the transcript alone.
    ///
    /// It runs for **every** session rather than only for chord-armed ones, and that
    /// is deliberate: the chord can arm a session that is already in flight (fn
    /// pressed a hair before control — see the chord notes in `CLAUDE.md`), so
    /// starting the writer at arm time would clip the opening word off exactly the
    /// notes people dictate fastest. The cost is a mono int16 downmix per buffer,
    /// which is nothing beside Parakeet, and the samples are dropped at the end of
    /// any session that didn't become a note.
    private var noteAudioWriter: SessionAudioWriter?
    /// Ceiling on collected note audio (5 min at capture rate ≈ 10 MB). A latched
    /// hands-free session has no natural end, so this is what stops an idle latch
    /// from growing the heap all afternoon.
    private static let noteAudioMaxMs = 5 * 60 * 1000
    private let releaseTailNanoseconds: UInt64 = 80_000_000
    /// When the current recording actually started capturing, for the analytics
    /// duration bucket. `nil` between sessions.
    private var recordingStartedAt: Date?
    /// True when the command chord (fn + control) armed the current session — its
    /// finished transcript goes to the assistant instead of being typed.
    /// Consumed (and reset) at stop, and mirrored into `state.commandCaptureArmed`
    /// for the notch. Unlike the day-query arm this can be set *mid-session*: the
    /// chord shares a key with the push-to-talk, so pressing fn a hair before
    /// control has already started an ordinary recording — re-labelling it keeps
    /// every frame of audio instead of restarting the capture.
    private var commandArmed = false
    /// True when the chord is what *started* the running session (nothing else was
    /// holding it open), so breaking the chord is what should stop it. False when
    /// the chord merely re-labelled a session the push-to-talk key owns — there,
    /// letting go of control must not cut the recording short.
    private var commandChordOwnsSession = false
    /// True when the agent key armed the current session — its finished transcript
    /// goes to a coding agent instead of being typed. Consumed (and reset) at stop,
    /// and mirrored into `state.agentCaptureArmed` for the notch.
    private var agentArmed = false
    /// True when the agent key is what *started* the running session, so its release
    /// is what should stop it. False when it only re-labelled a session the
    /// push-to-talk key owns.
    private var agentKeyOwnsSession = false
    /// When the agent key went down, so its release can tell a tap from a hold.
    private var agentKeyDownAt: Date?
    /// Whether an agent band was on screen at the press — a tap then means
    /// "dismiss", not "open the list".
    private var agentGlanceWasOpenAtKeyDown = false
    /// Drives gentle "you haven't used me in a while" reminders in the notch.
    private lazy var reminderScheduler = ReminderScheduler(state: state)
    /// Owns the optional on-device cleanup model: background download, progress
    /// (Settings only), and the one-shot ready banner. Dormant unless opted in.
    private lazy var cleanupModelManager = CleanupModelManager(state: state)
    /// Reads assistant answers aloud. Created on the **first answer that wants
    /// speaking**, never at launch — an `AVSpeechSynthesizer` should not exist for a
    /// user who turned this off, nor under `swift test` / the headless snapshot
    /// renderer, both of which construct an `AppState`. `reconcileSpeech` therefore
    /// checks for nil rather than touching the property, which would defeat the point.
    private var answerSpeaker: AnswerSpeaker?
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

    func startRecording(command: Bool = false) {
        // Whatever agent band was lingering — a pinned reply, an open glance — a
        // new recording outranks it, and letting it pop back up mid- or
        // post-dictation is the "shows during normal dictation" bug.
        state.agents.closeGlance()
        guard state.canStart else { return }
        // Every session begins as a normal dictation unless the command chord armed
        // it — reset here so a stale arm can't leak into the next one.
        setCommandArmed(command)
        // A session starts held-open by the key; a double-tap can latch it later.
        state.handsFreeActive = false

        // Open a diagnostics session at the true key-press instant (this runs
        // synchronously from the hotkey handler). No-op unless a DIAGNOSTICS build.
        Diagnostics.shared.begin(context: makeDiagnosticsContext())

        // A reminder showing now would be replaced by the live indicator anyway.
        reminderScheduler.clear()
        // Reaching for the key *is* the barge-in: an answer still being read aloud is
        // cut off here, before the mic comes up, so we never transcribe our own voice.
        answerSpeaker?.stop()
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
        state.commandAgentRunning = false
        state.polishedText = nil
        state.polishedAt = nil
        failedResetTask?.cancel()
        levelEnvelope.reset()
        // Start collecting this session's audio, in case it turns into a spoken note
        // (see `noteAudioWriter`).
        noteAudioWriter = SessionAudioWriter()

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

                // If the audio route changes mid-recording and the capture graph
                // can't be rebuilt on the new devices, end the session honestly
                // rather than keeping a "recording" state fed by nothing.
                microphoneCapture.onCaptureLost = { [weak self] in
                    Task { @MainActor in
                        guard let self, self.state.canStop else { return }
                        await self.handleFailure(MicrophoneCaptureService.CaptureError.captureInterrupted)
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
        // Which account these words belong to, captured *here* rather than at the
        // end of the finalize below: usage is per-account and the loaded account is
        // repointed by the 0.5 s auth reconcile, so a sign-in/out during the
        // finalize would otherwise file this session under whoever happens to be
        // signed in when it finishes.
        let sessionOwner = state.usageStore.currentUserID
        // Consume the command arm now (synchronously, at the user's stop) so it
        // can't linger; the async finalize below reads this captured copy.
        let commandMode = commandArmed
        setCommandArmed(false)
        commandChordOwnsSession = false
        // Same consume-at-stop rule as the assistant arm above: read it here, at the
        // user's stop, so it can't linger into the next session.
        let agentMode = agentArmed
        setAgentArmed(false)
        agentKeyOwnsSession = false
        // However this stop arrived (key release, double-tap, tray, failure), the
        // gesture that latched the session is finished with it.
        state.handsFreeActive = false
        hotkeyGestureReset()

        state.phase = .stopping
        state.audioLevel = 0
        levelEnvelope.reset()
        state.statusMessage = "Catching final words..."
        Feedback.stop(soundEnabled: state.soundEnabled)
        Diagnostics.shared.mark(.stopRequested)

        Task {
            // Whatever this session turned out to be, its audio is dead weight once
            // the finalize is done: a note that wanted it has already consumed the
            // writer (`takeNoteAudio` nils it out), so anything still here belongs to
            // a dictation that was typed, answered, or failed. `defer` rather than a
            // line per exit — the block below returns from four different places, and
            // the one that got missed would hold ~10 MB until the next dictation.
            defer { noteAudioWriter = nil }
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
                let fixes = FixCounts(
                    wordsCorrected: selfCorrectionFixes + fillerFixes,
                    dictionary: dictionaryFixes)
                // Was this the assistant? Only when the user *held the chord* for
                // this session — the words are then a question or an instruction,
                // never text, so the paste is *suppressed* below.
                //
                // Nothing below the chord may re-open this branch. An unarmed
                // dictation is never inspected for trigger phrases or question
                // shapes: "remind me to call mom" typed into a chat window stays
                // typed, and so does "what's my schedule for the sprint?". Inferring
                // intent from words means eating a transcript whenever the guess is
                // wrong, and no keyword list is good enough to earn that.
                var assistantHandled = false
                if agentMode, !cleaned.isEmpty {
                    // The agent key wins over the assistant chord when both are
                    // somehow armed: it is the more specific instruction, and it
                    // names a destination rather than a kind of handling.
                    assistantHandled = await routeAgentCapture(cleaned)
                } else if commandMode, !cleaned.isEmpty {
                    assistantHandled = await routeCommandCapture(cleaned)
                }
                // The frontmost app is the one about to receive the paste — or, for
                // an assistant capture, the one the user was speaking from. We don't
                // steal focus, so it's still the user's target app. Taken once here
                // and shared, so the usage record and the trace below describe the
                // same instant instead of two re-queries.
                let front = NSWorkspace.shared.frontmostApplication
                // One call chooses this session's exit *and* folds it into the
                // durable usage stats, because they are one decision: a capture the
                // assistant took and one that produced nothing are both real minutes
                // of speaking, and omitting them makes the WPM gauge, lifetime words
                // and the streak read low. The kind that was recorded is the branch
                // taken below, so no exit can be reached without being accounted for
                // — a line per exit is exactly what was missed before.
                let kind = SessionAccounting(
                    store: state.usageStore,
                    appName: front?.localizedName ?? "",
                    appBundleID: front?.bundleIdentifier ?? "",
                    engineRawValue: state.selectedEngine.rawValue
                ).account(
                    transcript: cleaned,
                    assistantHandled: assistantHandled,
                    duration: sessionDuration,
                    fixes: fixes,
                    owner: sessionOwner)
                switch kind {
                case .empty:
                    // Nothing to paste (only "hmm" / a silence hallucination) — the
                    // session still counted above, since a miss is worth inspecting.
                    Diagnostics.shared.finish(pasteOutcome: "empty", finalText: "")
                    state.statusMessage = "Finished local transcription."
                    return
                case .assistant:
                    reminderScheduler.noteUsed()
                    Diagnostics.shared.finish(pasteOutcome: "command", finalText: cleaned)
                    state.statusMessage = "Handled by the assistant."
                    return
                case .dictation:
                    break
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
                Diagnostics.shared.noteFrontApp(
                    name: front?.localizedName ?? "unknown",
                    bundleID: front?.bundleIdentifier ?? "")
                // Roll the durable totals onto the analytics *person*. Read after
                // `SessionAccounting.account` above has already folded this session
                // in, so the totals include it — this reports the store, it does not
                // record anything itself.
                //
                // This is what makes "which accounts are heavy users" a filter
                // rather than an aggregation across every event that account ever
                // sent: PostHog can cohort on a person property directly. On the
                // `.dictation` path only, so the profile reflects delivered work
                // rather than every session that was opened.
                Analytics.shared.updatePersonProperties([
                    "lifetimeDictations": String(state.usageStore.totalDictations),
                    "lifetimeWords": String(state.usageStore.totalWords),
                    "engine": state.selectedEngine.rawValue,
                ])
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

    /// Which exit the finalize takes, and the usage record it owes — one decision,
    /// made in one place.
    ///
    /// The defect this shape exists to prevent was a *missing call*: the assistant
    /// and empty exits of `stopRecording` returned before recording anything, so
    /// chord-armed captures and misses never reached the Insights dashboard at all.
    /// A line per exit is precisely the thing that gets forgotten, so `account`
    /// returns the kind it just recorded and the caller branches on that — an exit
    /// cannot be taken without being accounted for. `stopRecording` needs a
    /// microphone and a loaded engine; this doesn't, so it is what the tests pin.
    @MainActor
    struct SessionAccounting {
        let store: UsageStore
        /// The app the session belongs to, snapshotted once by the caller.
        let appName: String
        let appBundleID: String
        let engineRawValue: String

        /// Classify the finished session and fold it into the durable usage stats.
        /// Returns what it recorded, which is also the exit to take: `.empty` and
        /// `.assistant` finish there, `.dictation` goes on to the paste.
        @discardableResult
        func account(
            transcript: String,
            assistantHandled: Bool,
            duration: TimeInterval,
            fixes: FixCounts,
            owner: String?
        ) -> DictationRecord.SessionKind {
            let kind: DictationRecord.SessionKind =
                transcript.isEmpty ? .empty : (assistantHandled ? .assistant : .dictation)
            store.record(
                DictationViewModel.usageRecord(
                    kind: kind,
                    transcript: transcript,
                    duration: duration,
                    appName: appName,
                    appBundleID: appBundleID,
                    engineRawValue: engineRawValue,
                    fixes: fixes),
                owner: owner)
            return kind
        }
    }

    /// The record for one finished session. Pure, so what each exit of the finalize
    /// contributes to usage is testable without a microphone.
    static func usageRecord(
        kind: DictationRecord.SessionKind,
        transcript: String,
        duration: TimeInterval,
        appName: String,
        appBundleID: String,
        engineRawValue: String,
        fixes: FixCounts,
        now: Date = Date()
    ) -> DictationRecord {
        DictationRecord(
            timestamp: now,
            wordCount: WordCount.count(transcript),
            durationSeconds: duration,
            appName: appName,
            appBundleID: appBundleID,
            engineRawValue: engineRawValue,
            fixes: fixes,
            kind: kind)
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
    /// If a calendar connector is on but access was never requested, ask now — the
    /// user has just held the chord, which is as explicit as an ask gets. Runs before
    /// the agent so the tools it's about to reach for aren't refused on a permission
    /// nobody was ever prompted for.
    private func requestCalendarAccessIfNeeded() async {
        guard state.connectorStore.hasReadableCalendar,
              CalendarConnector.shared.isUndetermined else { return }
        let granted = await CalendarConnector.shared.requestAccess()
        state.connectorStore.calendarAccessGranted = granted
        guard granted else { return }
        for kind in ConnectorKind.allCases {
            state.connectorStore.clearErrors(ofKind: kind, matching: .needsCalendarAccess)
        }
    }

    /// Answer a day question straight from `DaySummaryService` — no model, no tool
    /// loop. The rung under the agent, so a cold start (or a machine that has never
    /// downloaded the 1.5 GB model) still answers "what's on my calendar" with
    /// something true instead of filing the question as a note.
    private func presentDaySummary(for question: String) async {
        let summary = await DaySummaryService.buildAsync(
            store: state.connectorStore, spokenQuery: question)
        state.activeDaySummary = summary
        state.daySummaryAt = Date()
        state.appendAnswer(
            question: question,
            answer: [summary.headline, summary.detail].filter { !$0.isEmpty }.joined(separator: ". "))
        Feedback.delivered(soundEnabled: state.soundEnabled)
        // Here the detail *is* the answer's second half (the next thing on the
        // calendar), so unlike the agent path it gets spoken.
        state.daySummaryWasSpoken = speakAnswer(
            headline: summary.headline, detail: summary.detail)
    }

    // MARK: - Reading answers aloud

    /// Read an answer out loud, if the user wants that for this kind of answer.
    ///
    /// Returns whether it will speak, which the caller records as
    /// `state.daySummaryWasSpoken` — that's what tells the notch to hold the band for
    /// the voice instead of running its silent-reading clock down behind it.
    ///
    /// - Parameter detail: the banner's second line. `nil` where it's provenance chrome
    ///   worth seeing and not worth hearing; passed through where it carries the answer.
    @discardableResult
    private func speakAnswer(headline: String, detail: String?) -> Bool {
        guard state.speakAnswersEnabled else { return false }
        // Every answer now comes from a question the user just asked out loud, so
        // there is no second, unprompted-speech consent to check — scheduled
        // automations, the only thing that could talk without being asked, are gone.
        // The mic guard stays: an answer can still land while a new dictation has
        // already started, and talking into a live microphone puts the app's own
        // voice in the transcript.
        guard state.phase == .idle else { return false }

        let speaker = answerSpeaker ?? makeAnswerSpeaker()
        return speaker.speak(headline: headline, detail: detail)
    }

    private func makeAnswerSpeaker() -> AnswerSpeaker {
        let speaker = AnswerSpeaker(preferences: { [state] in
            AnswerSpeaker.Preferences(
                engine: state.answerVoiceEngine,
                systemVoiceIdentifier: state.systemVoiceIdentifier,
                naturalVoiceID: state.naturalVoiceID)
        })
        // The speaker never writes `AppState` itself — it reports, and the view model
        // (the only permitted writer) records.
        speaker.onStateChange = { [weak self] speaking in
            self?.state.isSpeakingAnswer = speaking
        }
        speaker.onNaturalReady = { [weak self] in
            self?.state.naturalVoiceReady = true
            self?.state.naturalVoiceFailed = false
        }
        speaker.onNaturalFailure = { [weak self] _ in
            self?.state.naturalVoiceReady = false
            self?.state.naturalVoiceFailed = true
        }
        answerSpeaker = speaker
        return speaker
    }

    /// Stop talking. Barge-in from a new recording, and the app quitting.
    func stopSpeaking() {
        answerSpeaker?.stop()
    }

    /// Speak a sample line so the user can hear a voice before choosing it.
    func previewVoice() {
        (answerSpeaker ?? makeAnswerSpeaker()).preview()
    }

    /// Replay a logged answer from the Today card.
    ///
    /// Deliberately **not** routed through `speakAnswer`: this is a direct tap on a
    /// speaker button, so it ignores the "read answers aloud" preference — the user
    /// just asked for this one. It still declines while the mic is live.
    func speakLoggedAnswer(_ entry: AnsweredQuestion) {
        guard state.phase == .idle else { return }
        (answerSpeaker ?? makeAnswerSpeaker()).speak(headline: entry.answer, detail: nil)
    }

    /// Kick off (or retry) the natural voice's download, then warm it.
    func downloadNaturalVoice() {
        guard state.naturalVoiceDownload == nil else { return }
        state.naturalVoiceFailed = false
        Task { [weak self] in
            guard let self else { return }
            do {
                try await NaturalVoiceInstaller.install { progress in
                    Task { @MainActor [weak self] in self?.state.naturalVoiceDownload = progress }
                }
                self.state.naturalVoiceDownload = nil
                (self.answerSpeaker ?? self.makeAnswerSpeaker()).prewarmNaturalVoiceIfNeeded()
            } catch {
                Log.modelPrep.error(
                    "Natural voice install failed: \(error.localizedDescription, privacy: .public)")
                self.state.naturalVoiceDownload = nil
                self.state.naturalVoiceFailed = true
            }
        }
    }

    /// Called from the AppDelegate's 0.5 s tick. Three cheap jobs, all no-ops most of
    /// the time, and the first one is not optional:
    ///
    /// 1. **Un-stick the banner.** While `isSpeakingAnswer` is true the refresh loop
    ///    pins `daySummaryAt` to now, so a speaking flag that never cleared — a backend
    ///    that died, a callback that never arrived — would hold the notch open forever.
    ///    Reconciling against the speaker's own view of whether it's running is the
    ///    backstop for that.
    /// 2. **Enforce a ceiling.** `SpokenAnswer` caps the text, so anything still going
    ///    after `maxHoldSeconds` is wedged rather than long.
    /// 3. **Honour the switches** — turning speech off, or switching away from the
    ///    natural voice, should take effect now rather than after the current answer.
    func reconcileSpeech() {
        // Deliberately does not create the speaker: most users never speak an answer.
        guard let speaker = answerSpeaker else {
            if state.isSpeakingAnswer { state.isSpeakingAnswer = false }
            return
        }
        if state.isSpeakingAnswer, !speaker.isRunning {
            state.isSpeakingAnswer = false
        }
        if let startedAt = speaker.startedAt,
           Date().timeIntervalSince(startedAt) > AnswerSpeaker.maxHoldSeconds {
            speaker.stop()
        }
        if !state.speakAnswersEnabled, state.isSpeakingAnswer {
            speaker.stop()
        }
        if state.naturalVoiceRetryRequested {
            state.naturalVoiceRetryRequested = false
            downloadNaturalVoice()
        }
        if state.answerVoiceEngine == .natural {
            speaker.prewarmNaturalVoiceIfNeeded()
            // Guarded: an unguarded write would push an @Observable change through
            // every observer twice a second for the life of the process, which is the
            // same per-tick cost the tray refresher is careful to avoid.
            if state.naturalVoiceReady != speaker.naturalVoiceIsReady {
                state.naturalVoiceReady = speaker.naturalVoiceIsReady
            }
        } else if state.naturalVoiceReady {
            // Switched away — hand the models back now rather than waiting out the idle
            // timer. Releasing promptly is the whole memory argument for this backend.
            speaker.releaseNaturalVoice()
            state.naturalVoiceReady = false
        }
    }

    // MARK: - The assistant (fn + control)

    /// The command chord (fn + control) became complete.
    ///
    /// Two cases, and the difference is whether anything is already recording:
    /// - **nothing running** → start a session armed as a command, owned by the
    ///   chord, so breaking the chord ends it (plain push-to-talk).
    /// - **a session already running** → just re-label it. The chord shares the fn
    ///   key with the default push-to-talk, so pressing fn a hair before control
    ///   has already started an ordinary dictation; re-labelling keeps every frame
    ///   of audio the user has spoken, where a restart would drop the first word.
    ///   That session stays owned by the key that started it.
    func handleCommandChordEngaged() {
        // Where Notes & Reminders is unreleased (stable) the chord means nothing:
        // arming a session we'd have to un-arm at the end would put "Note or
        // reminder" in the notch and then paste the words anyway.
        guard FeatureFlags.connectorsAndNotesAvailable else { return }
        if state.canStop || state.phase == .preparingModels {
            setCommandArmed(true)
            state.statusMessage = "Listening for the assistant..."
            return
        }
        if state.preparingEngine != nil {
            state.statusMessage = "Voice engine is still getting ready."
            return
        }
        guard state.canStart else { return }
        commandChordOwnsSession = true
        startRecording(command: true)
    }

    /// The chord broke (either key came up). Only stops the session when the chord
    /// is what opened it — otherwise the push-to-talk key is still holding it, and
    /// letting go of control must not cut the recording short.
    func handleCommandChordReleased() {
        guard commandChordOwnsSession else { return }
        commandChordOwnsSession = false
        if state.canStop {
            stopRecording()
        }
    }

    /// Mirror the private arm into `AppState` so the notch can say which of the two
    /// things the band is doing. One writer, so the two can't drift.
    private func setCommandArmed(_ armed: Bool) {
        commandArmed = armed
        state.commandCaptureArmed = armed
    }

    // MARK: - The agent key

    /// The agent key went down: start (or re-label) a capture whose words go to a
    /// coding agent.
    ///
    /// Mirrors the assistant chord exactly, and for the same reason: this key can be
    /// pressed a moment after the push-to-talk key, so a session may already be in
    /// flight. Re-labelling keeps every frame of audio where a restart would drop the
    /// opening word.
    func handleAgentKeyStart() {
        agentKeyDownAt = Date()
        // Remember what was on screen at the press: a tap dismisses it, while a
        // hold talks — and the hold must start recording *now*, band open or not,
        // or the first word is lost.
        agentGlanceWasOpenAtKeyDown = state.agents.isGlanceOpen
        guard state.agents.isAvailable else {
            state.statusMessage = "No coding agent is running on this Mac."
            return
        }
        if state.canStop || state.phase == .preparingModels {
            setAgentArmed(true)
            state.statusMessage = "Listening for the agent..."
            return
        }
        if state.preparingEngine != nil {
            state.statusMessage = "Voice engine is still getting ready."
            return
        }
        guard state.canStart else { return }
        agentKeyOwnsSession = true
        setAgentArmed(true)
        startRecording()
    }

    /// The agent key came up.
    ///
    /// **Hold means talk; a quick tap means look.** One key, two gestures, in the
    /// spirit of the push-to-talk key's own hold / double-tap / toggle set — because
    /// the alternative was a second binding for "show me the sessions", and a
    /// shortcut per surface is exactly what makes a keyboard unlearnable.
    ///
    /// A tap is resolved *here*, on the release, rather than by delaying the start:
    /// starting on the press is what keeps the first word of a real dictation, and
    /// nothing about a sub-`tapMaxHold` press is worth transcribing anyway.
    func handleAgentKeyStop() {
        let heldFor = agentKeyDownAt.map { Date().timeIntervalSince($0) } ?? .infinity
        agentKeyDownAt = nil

        if heldFor < Self.agentTapMaxHold {
            if agentKeyOwnsSession, state.canStop { cancelSession() }
            agentKeyOwnsSession = false
            setAgentArmed(false)
            // A tap on an open band dismisses it and stops there; a tap on a bare
            // notch opens the glance. Without the distinction, tapping to dismiss
            // a reply immediately replaced it with the session list.
            if agentGlanceWasOpenAtKeyDown {
                state.agents.closeGlance()
            } else {
                state.agents.toggleGlance()
            }
            return
        }

        guard agentKeyOwnsSession else { return }
        agentKeyOwnsSession = false
        if state.canStop { stopRecording() }
    }

    /// Longest press still read as a tap. Matches `HotkeyGesture.tapMaxHold`, which
    /// is the same judgement about the same physical gesture.
    private static let agentTapMaxHold: TimeInterval = 0.35

    private func setAgentArmed(_ armed: Bool) {
        agentArmed = armed
        state.agentCaptureArmed = armed
    }

    /// Send an armed capture to a coding agent. Returns `true` when the words were
    /// delivered, so the caller suppresses the paste.
    ///
    /// When delivery fails — no server, no session and nowhere to start one — the
    /// words are **not** silently dropped and **not** pasted into whatever app
    /// happens to be in front. They go to the undelivered banner with its Copy
    /// button, because the user held a key that means "send this to the agent", and
    /// typing it into their editor is the one outcome that key press ruled out.
    private func routeAgentCapture(_ text: String) async -> Bool {
        let delivered = await state.agents.deliver(
            prompt: text, startingIn: state.resolvedAgentDirectory)
        guard !delivered else {
            state.statusMessage = "Sent to \(state.agents.promptTarget?.repo ?? "the agent")."
            return true
        }
        copyToClipboard(text)
        state.undeliveredText = text
        state.undeliveredTranscriptAt = Date()
        state.statusMessage = state.agents.isAvailable
            ? "No session to send to. Set a project folder in Settings."
            : "No coding agent is running on this Mac."
        return true
    }

    /// Carry out an armed capture. Returns `true` when it handled the text (the
    /// caller then suppresses the paste).
    ///
    /// Three tiers, in order:
    ///
    /// 1. **The agent** (`CommandAgentService`) — the reasoning model with tools, and
    ///    the whole of the assistant. It can file a reminder with a time buried
    ///    mid-sentence, read the calendar, run a connector write (which raises the
    ///    usual approval card), or simply answer. Tried first whenever the on-device
    ///    model is loaded.
    /// 2. **The deterministic day summary** — for a capture that reads as a question
    ///    about the day when the agent couldn't take it. This is the one place
    ///    `DayQueryDetector` is still allowed to run, and it's safe here precisely
    ///    because it is *not* deciding whether to suppress the paste: the chord
    ///    already did that. It only picks which of two handlings an armed capture
    ///    gets, so a false positive costs a wrong-shaped answer, not a lost
    ///    transcript. It answers from `DaySummaryService` with no model at all, so
    ///    "what's on my calendar" still works on a cold start.
    /// 3. **The deterministic gate** — the original keyword path: no model loaded, an
    ///    exhausted loop, or a model that talked when the words said to file.
    ///
    /// Because the user held a key that *means* "talk to the assistant", no tier
    /// declines on content: a capture with no trigger at all is still filed — as a
    /// note, the kind that needs nothing but words. Pasting "take a note buy milk"
    /// into the user's editor is the one outcome the key press rules out, so the last
    /// tier is what guarantees the words land somewhere even when the model is no
    /// help.
    private func routeCommandCapture(_ text: String) async -> Bool {
        // Where Notes & Reminders is unreleased (stable) this whole path stays
        // off. Routing would swallow the transcript — suppressing the paste and
        // filing it into a store with no openable surface — so "remind me to
        // call mom" would silently vanish. Better to just paste the words.
        guard FeatureFlags.connectorsAndNotesAvailable else { return false }
        // The denominator for every assistant number below: how often the chord
        // was actually used, before any tier has had a chance to take it.
        Analytics.shared.send(.assistantInvoked)
        await requestCalendarAccessIfNeeded()
        if await runCommandAgent(text) {
            Analytics.shared.send(.assistantRouted(route: .agent))
            return true
        }
        if state.connectorStore.hasReadableCalendar, DayQueryDetector.matches(text) {
            await presentDaySummary(for: text)
            Analytics.shared.send(.assistantRouted(route: .daySummary))
            return true
        }
        let fallback = ClassifiedIntent.armedCapture(of: text)
        let refined = await classifyIntent(text, fallback: fallback)
        let intent = refined.kind == .dictation ? fallback : refined
        // The trigger-stripped words, used wherever the model left a piece empty.
        let payload = CommandDetector.detect(text)?.payload ?? text
        Analytics.shared.send(.assistantRouted(route: .deterministic))
        if intent.kind == .reminder {
            createReminder(from: intent, fallbackTitle: payload)
        } else {
            createNote(from: intent, fallbackBody: payload, transcript: text)
        }
        return true
    }

    /// Run the spoken command through the agent. Returns `true` when it acted, in
    /// which case the notch is already carrying its answer.
    ///
    /// Gated on the model being **already loaded** for the same reason the classifier
    /// is: a command must never block on a cold 1.5 GB download. Connector tools join
    /// the tool set only when the user has opted the assistant into their connectors
    /// (`connectorAgentEnabled`); the notes and reminders tools are always there,
    /// because filing what you just said is what the chord means.
    private func runCommandAgent(_ text: String) async -> Bool {
        guard await MlxCleanupService.shared.isReady else { return false }
        let agent = CommandAgentService(
            store: state.connectorStore,
            notes: state.notesStore,
            approvals: state.approvals,
            connectorsAllowed: state.connectorAgentEnabled,
            alertStyle: state.reminderDefaultAlertStyle,
            soundName: state.reminderDefaultSound,
            takeNoteAudio: { [weak self] id in self?.takeNoteAudio(for: id) })
        // The orb shows the thinking figure while the loop runs — the paste is
        // suppressed, so without it the notch sits silent through a multi-second
        // tool call and reads as having dropped the command. `isPolishing` is what
        // holds the band open; `commandAgentRunning` is what stops it captioning the
        // work as a rewrite.
        state.isPolishing = true
        state.commandAgentRunning = true
        state.agentActivity = .thinking
        let result = await agent.perform(
            text,
            generate: AgentLoop.liveGenerator(),
            // The loop reports; the view model is what writes `AppState`, so the
            // "one writer" rule survives the callback.
            onStep: { [weak self] step in self?.state.agentActivity = step })
        state.isPolishing = false
        state.commandAgentRunning = false
        state.agentActivity = nil
        guard let result else { return false }
        // The two outcomes get different surfaces, because they're different things.
        // A creation is a checkmark to glance at — it's already durable in Notes &
        // Reminders, and the band is a receipt. An *answer* exists only as long as
        // the band does unless it's put somewhere, so it goes through the answer
        // surface: `activeDaySummary` (whose clock the refresh loop pins while the
        // voice runs, which the confirmation band's does not), `appendAnswer` so it
        // stays readable in Today → Recent answers, and `speakAnswer`.
        guard result.createdSomething else {
            presentAnswer(question: text, answer: result.answer, provenance: result.detail)
            return true
        }
        showCommandConfirmation(
            Self.bandLine(result.answer),
            icon: result.icon,
            detail: result.detail,
            window: AppState.commandConfirmationDuration)
        return true
    }

    /// Put an assistant answer on every surface that outlives the band: the notch,
    /// the answer log, and the voice. The single place answers land, whatever asked
    /// for them.
    private func presentAnswer(question: String, answer: String, provenance: String) {
        state.activeDaySummary = DaySummary(
            headline: answer, detail: provenance, events: [], gaps: [], scopedTo: nil)
        state.daySummaryAt = Date()
        // The band's line is truncated and gone in seconds; this is where a long
        // answer stays readable.
        state.appendAnswer(question: question, answer: answer, provenance: provenance)
        Feedback.delivered(soundEnabled: state.soundEnabled)
        // No detail: provenance ("From Work Calendar") is chrome worth seeing, not
        // hearing.
        state.daySummaryWasSpoken = speakAnswer(headline: answer, detail: nil)
    }

    /// Clamp the assistant's line to what the band can actually show. The banner is
    /// one line on a surface a few hundred points wide, so a long answer would be cut
    /// mid-word by the notch's clip with nothing to say it had been; an ellipsis at a
    /// word boundary at least admits it. The full artifact is in Notes & Reminders.
    static func bandLine(_ text: String, limit: Int = 58) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        guard trimmed.count > limit else { return trimmed }
        let head = trimmed.prefix(limit)
        let cut = head.lastIndex(of: " ").map { String(head[head.startIndex..<$0]) } ?? String(head)
        return cut.trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Ask the on-device model to classify + extract, but only when it's already
    /// loaded — a command must never block on a cold model download. Returns the
    /// deterministic reading otherwise (so a reminder still lands, just with no
    /// extracted time → the default-time path asks).
    private func classifyIntent(_ text: String, fallback: ClassifiedIntent) async -> ClassifiedIntent {
        guard await MlxCleanupService.shared.isReady else { return fallback }
        guard let raw = await MlxCleanupService.shared.clean(text, systemPrompt: IntentPrompt.system),
              let parsed = IntentClassifier.parse(raw)
        else { return fallback }
        return parsed
    }

    /// File a spoken note, keeping **what was said** and **how it sounded** beside
    /// the assistant's tidied version.
    ///
    /// `intent.title`/`intent.body` are the model's rewrite of the capture; the
    /// transcript is the verbatim words. Both are stored because the rewrite is the
    /// useful form and the transcript is the only record of the original — and for a
    /// note filed by voice, "did it hear me right?" is the first question the user
    /// has. The recording answers it without them having to trust either string.
    private func createNote(from intent: ClassifiedIntent, fallbackBody: String, transcript: String) {
        let body = intent.body.isEmpty ? fallbackBody : intent.body
        let id = UUID()
        let audio = takeNoteAudio(for: id)
        state.notesStore.upsertNote(Note(
            id: id,
            title: intent.title,
            body: body,
            transcript: transcript,
            audio: audio))
        // `hasAudio` is the adoption signal for the whole audio tee — a note made
        // from a session too short to record looks the same otherwise.
        Analytics.shared.send(.noteCreated(source: .deterministic, hasAudio: audio != nil))
        showCommandConfirmation("Note saved", icon: "note.text",
                                window: AppState.commandConfirmationDuration)
    }

    /// Hand this session's collected audio to a note, and stop collecting.
    ///
    /// Consuming the writer here is what keeps a single recording from being
    /// attached to two notes if one capture somehow files twice, and it frees the
    /// samples the moment they've been written to disk.
    private func takeNoteAudio(for noteID: UUID) -> NoteAudio? {
        guard let writer = noteAudioWriter else { return nil }
        noteAudioWriter = nil
        // A capture with no real audio (a failed session, or a mic that delivered
        // nothing) gets no recording rather than a zero-length file that renders a
        // dead play button.
        guard writer.durationMs > 200 else { return nil }
        return NoteAudioStore.save(
            wav: writer.wavData(), durationMs: writer.durationMs, for: noteID)
    }

    /// Put a confirmation on the band. Every field is written on every call — they
    /// persist between commands, so a leftover icon or a leftover 10 s window from
    /// the previous answer would otherwise bleed into this one.
    private func showCommandConfirmation(
        _ message: String,
        icon: String,
        detail: String = "Saved to Notes & Reminders",
        window: TimeInterval
    ) {
        state.commandConfirmation = message
        state.commandConfirmationDetail = detail
        state.commandConfirmationIcon = icon
        state.commandConfirmationWindow = window
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
        Analytics.shared.send(.reminderCreated(source: .deterministic, repeating: false))
        let when = Self.reminderTimeString(due, now: now)
        // A stated time is set; an unstated one gets a default the user can adjust
        // by tapping the banner (→ Settings → Notes & Reminders).
        showCommandConfirmation(
            stated != nil ? "Reminder set for \(when)" : "Reminder set for \(when) · tap to change",
            icon: "bell.badge.fill",
            window: AppState.commandConfirmationDuration)
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
        // A cancelled session files nothing, so its arms die with it.
        setCommandArmed(false)
        commandChordOwnsSession = false
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
        // Tee the mic into the note recorder. This is *collection*, not a second
        // capture — one tap, and the buffer is already in hand, so nothing here goes
        // near a device or the engine (see the device-juggling prohibitions in
        // `CLAUDE.md`). Bounded so a latched hands-free session can't grow without
        // limit; past the cap the note simply keeps the audio it already has.
        if let writer = noteAudioWriter, writer.durationMs < Self.noteAudioMaxMs {
            writer.append(buffer)
        }
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

    /// The push-to-talk key went down (or a tap started a session). Hold-to-talk
    /// vs. toggle is decided upstream in `HotkeyManager`, which is what knows the
    /// shape of the gesture; by here the intent is unambiguous.
    func handleHotkeyStart() {
        if state.preparingEngine != nil {
            state.statusMessage = "Voice engine is still getting ready."
            return
        }
        if state.canStart {
            startRecording()
        }
    }

    func handleHotkeyStop() {
        if state.canStop {
            stopRecording()
        }
    }

    /// A double-tap latched the running dictation open — it keeps listening with
    /// the key released, until the next double-tap. Only a live recording can be
    /// latched; anything else would leave the notch claiming hands-free with
    /// nothing running.
    func handleHotkeyHandsFree() {
        guard state.canStop else { return }
        state.handsFreeActive = true
        state.statusMessage = "Hands-free — double-tap again to stop."
    }

    /// Toggle mode (`holdToTalkEnabled` off): one tap of the key flips the state.
    func handleHotkeyToggle() {
        if state.canStop {
            stopRecording()
        } else {
            handleHotkeyStart()
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
            // A session that never produced a transcript can't be a command —
            // clear the arm so the notch doesn't keep claiming one is in flight.
            self.setCommandArmed(false)
            self.commandChordOwnsSession = false
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
