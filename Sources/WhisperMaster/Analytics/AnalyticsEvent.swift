import Foundation

/// The feature area a signal belongs to.
///
/// Rides on **every** event as a `category` parameter so both tools can answer
/// "what is this account actually using?" with one breakdown, instead of a
/// hand-maintained list of event names that goes stale the first time somebody
/// adds a case below. In PostHog it is the natural first split on any insight; in
/// GA it wants registering once under Admin → Custom definitions.
enum AnalyticsCategory: String {
    /// Launch, update, onboarding — the app existing at all.
    case lifecycle
    /// Speaking and getting text out: sessions, delivery, the hotkey.
    case dictation
    /// The held fn+control chord and everything the agent loop does behind it.
    case assistant
    /// Notes: creation, pinning, the recording.
    case notes
    /// Reminders: creation, completion, the archive.
    case reminders
    /// Third-party accounts and the consent that gates them.
    case connectors
    /// Spoken answers and the voice that reads them.
    case speech
    /// The optional on-device LLM cleanup pass.
    case cleanup
    /// Preferences and permission posture.
    case settings
    /// Crashes and handled failures.
    case reliability
}

/// Every analytics signal the app can emit, with its wire names and parameters.
///
/// Pure and SDK-agnostic — `Analytics` translates these into PostHog events and
/// Google Analytics 4 events. **Nothing here carries user content:** only app
/// versions, coarse buckets, and enum-like states. Numbers are bucketed so no
/// single signal is fingerprintable back to a specific session.
///
/// **The account is not here, and that is deliberate.** Since `Analytics.identify`,
/// events are attributable to a signed-in person via the *profile* — but the event
/// body stays free of the id, the email, and anything the user said. So the
/// identity lives in exactly one place and can be dropped in exactly one place,
/// and an exported event stream is not a customer list.
///
/// The two vendors get **different spellings of the same event** (`name` vs
/// `googleName`) because GA4 rejects anything outside
/// `[A-Za-z][A-Za-z0-9_]{0,39}` — no dots — while PostHog's existing dotted
/// names are already live in dashboards and must not be renamed under them.
///
/// **Never rename an existing case's wire names.** A PostHog insight and a GA
/// custom dimension both key off the string, and a rename orphans the history
/// rather than migrating it. Add a case; leave the old spelling alone.
enum AnalyticsEvent {
    // MARK: - Lifecycle

    /// The app was launched. Drives DAU/WAU/MAU, retention, and (via the SDK's
    /// automatic metadata) version / macOS / device / country breakdowns.
    case appLaunched
    /// The setup wizard was completed — the activation rate for new installs.
    case onboardingFinished
    /// First launch on a newer app version — how fast Sparkle rollouts land.
    case updateInstalled(from: String, to: String)

    // MARK: - Dictation

    /// A dictation session finished with non-empty text.
    case dictationCompleted(engine: String, duration: TimeInterval, wordCount: Int)
    /// A session ended without producing text — the failure side of the number
    /// above, and the only way to see a completion *rate* rather than a count.
    case dictationDiscarded(reason: DictationDiscardReason)
    /// A finished transcript had nowhere to paste and fell back to the notch
    /// banner. `copied` records whether the user rescued it from there, which is
    /// what separates "an annoyance" from "lost words".
    case dictationUndelivered(copied: Bool)
    /// The push-to-talk key was changed in Settings. The *value* matters more than
    /// the count: fn is the key the Globe-claim below exists for.
    case hotkeyChanged(to: String)
    /// The Globe key was taken off macOS for push-to-talk, or handed back.
    /// Handing it back is the signal that the claim was unwelcome.
    case fnKeyClaim(restored: Bool)
    /// A hands-free (double-tap latch) session, rather than a held key. Emitted
    /// once per session so the two interaction modes are comparable.
    case handsFreeUsed

    // MARK: - Assistant

    /// The fn+control chord armed a capture. The denominator for everything below.
    case assistantInvoked
    /// Where the captured words ended up, across the three tiers in
    /// `routeCommandCapture`. This is the single most useful assistant number:
    /// it says how often the 3B agent actually takes the work versus how often
    /// the deterministic fallbacks carry it.
    case assistantRouted(route: AssistantRoute)
    /// One tool call inside the agent loop. `tool` is the catalog's own name (a
    /// fixed enum-like string, never an argument), so per-tool success rates and
    /// the tools nobody uses are both visible.
    case assistantToolRun(tool: String, succeeded: Bool)
    /// The loop ended without an answer — the budget ran out, the model refused,
    /// or a tool threw.
    case assistantFailed(reason: AssistantFailureReason)

    // MARK: - Notes

    /// A note was created, and by which of the two paths.
    case noteCreated(source: NoteSource, hasAudio: Bool)
    /// A note was pinned to the bezel, or unpinned.
    case notePinned(pinned: Bool)
    /// A note's recording was played back. The adoption number for the whole
    /// audio-tee feature: if this stays near zero, the WAV on disk is not earning
    /// its keep.
    case noteAudioPlayed
    /// A note was deleted.
    case noteDeleted

    // MARK: - Reminders

    /// A reminder was created, and by which path.
    case reminderCreated(source: NoteSource, repeating: Bool)
    /// A reminder was ticked. A repeating one rolls forward instead of archiving,
    /// so the two are counted apart.
    case reminderCompleted(repeating: Bool)
    /// A tick was undone from the notch or the archive.
    case reminderRestored
    /// The completed archive was emptied.
    case reminderArchiveCleared

    // MARK: - Connectors

    /// A third-party account was connected, or disconnected. `provider` is the
    /// provider's own slug (`google_calendar`, `slack`), never the account name.
    case connectorLinked(provider: String, linked: Bool)
    /// A consent card was answered. `decision` covers the three buttons plus the
    /// timeout, which is its own answer: a card nobody responds to is a card in
    /// the wrong place.
    case approvalDecided(tool: String, decision: ApprovalDecision)

    // MARK: - Speech

    /// An answer was read aloud, by whichever backend took it.
    case answerSpoken(voice: SpeechVoice)
    /// The optional Kokoro natural-voice models finished installing.
    case naturalVoiceInstalled

    // MARK: - Cleanup

    /// The optional on-device Smart cleanup (LLM) model finished downloading and
    /// loaded for the first time — i.e. a user actually pulled the ~1.5 GB model.
    /// This is the "how many adopted the LLM" counter.
    case cleanupModelDownloaded
    /// A cleanup pass actually changed the transcript and the change reached the
    /// user. Emitted only on a delivered substitution, so it measures the feature
    /// working rather than the feature running.
    case cleanupApplied

    // MARK: - Settings

    /// The current permission posture, sampled at launch.
    case permissionState(accessibility: Bool, microphone: Bool)
    /// A preference was flipped. `setting` is a stable key, so the feature-adoption
    /// picture includes the things people turn *off*.
    case settingToggled(setting: String, enabled: Bool)

    // MARK: - Reliability

    /// The previous run ended without reaching `applicationWillTerminate`,
    /// reported on the next launch by `CrashReporter`. A `nil` report means the
    /// exit was unclean but no matching `.ips` was readable — see `hasReport`.
    case appCrashed(CrashReport?)
    /// A handled failure worth counting. `domain` is a fixed area string and
    /// `kind` a fixed reason — never an `error.localizedDescription`, which can
    /// carry a file path or a server message.
    case failureOccurred(domain: String, kind: String)

    // MARK: - Enumerated parameter values

    /// Why a dictation produced nothing.
    enum DictationDiscardReason: String {
        /// The user cancelled before it finished.
        case cancelled
        /// The engine returned an empty transcript.
        case empty
        /// The engine or the model failed.
        case engineFailed
        /// Too short to be speech.
        case tooShort
    }

    /// Which tier of `routeCommandCapture` took the words.
    enum AssistantRoute: String {
        /// The `AgentLoop` over the on-device model.
        case agent
        /// The deterministic day summary.
        case daySummary
        /// The keyword gate — note vs reminder.
        case deterministic
    }

    /// Why the agent loop produced no answer.
    enum AssistantFailureReason: String {
        /// The 30s budget expired.
        case budgetExhausted
        /// A tool threw.
        case toolError
        /// The model produced nothing usable.
        case modelEmpty
        /// The model was not loaded.
        case modelUnavailable
    }

    /// Which path created a note or reminder.
    enum NoteSource: String {
        /// The agent's `create_note` / `create_reminder` tool.
        case agent
        /// The deterministic keyword gate.
        case deterministic
        /// Typed in the Settings window.
        case manual
    }

    /// The four ways a consent card ends.
    enum ApprovalDecision: String {
        case once
        case always
        case denied
        /// Nobody answered and it denied itself.
        case timedOut
    }

    /// Which synthesizer read the answer.
    enum SpeechVoice: String {
        /// macOS `AVSpeechSynthesizer`.
        case system
        /// Kokoro-82M on the ANE.
        case natural
    }

    // MARK: - Wire names

    /// The feature area this signal belongs to.
    var category: AnalyticsCategory {
        switch self {
        case .appLaunched, .onboardingFinished, .updateInstalled:
            return .lifecycle
        case .dictationCompleted, .dictationDiscarded, .dictationUndelivered,
             .hotkeyChanged, .fnKeyClaim, .handsFreeUsed:
            return .dictation
        case .assistantInvoked, .assistantRouted, .assistantToolRun, .assistantFailed:
            return .assistant
        case .noteCreated, .notePinned, .noteAudioPlayed, .noteDeleted:
            return .notes
        case .reminderCreated, .reminderCompleted, .reminderRestored, .reminderArchiveCleared:
            return .reminders
        case .connectorLinked, .approvalDecided:
            return .connectors
        case .answerSpoken, .naturalVoiceInstalled:
            return .speech
        case .cleanupModelDownloaded, .cleanupApplied:
            return .cleanup
        case .permissionState, .settingToggled:
            return .settings
        case .appCrashed, .failureOccurred:
            return .reliability
        }
    }

    /// The PostHog event name (namespaced, dot-separated by convention).
    var name: String {
        switch self {
        case .appLaunched: return "App.launched"
        case .onboardingFinished: return "Onboarding.finished"
        case .updateInstalled: return "Update.installed"
        case .dictationCompleted: return "Dictation.completed"
        case .dictationDiscarded: return "Dictation.discarded"
        case .dictationUndelivered: return "Dictation.undelivered"
        case .hotkeyChanged: return "Dictation.hotkeyChanged"
        case .fnKeyClaim: return "Dictation.fnKeyClaim"
        case .handsFreeUsed: return "Dictation.handsFree"
        case .assistantInvoked: return "Assistant.invoked"
        case .assistantRouted: return "Assistant.routed"
        case .assistantToolRun: return "Assistant.toolRun"
        case .assistantFailed: return "Assistant.failed"
        case .noteCreated: return "Note.created"
        case .notePinned: return "Note.pinned"
        case .noteAudioPlayed: return "Note.audioPlayed"
        case .noteDeleted: return "Note.deleted"
        case .reminderCreated: return "Reminder.created"
        case .reminderCompleted: return "Reminder.completed"
        case .reminderRestored: return "Reminder.restored"
        case .reminderArchiveCleared: return "Reminder.archiveCleared"
        case .connectorLinked: return "Connector.linked"
        case .approvalDecided: return "Connector.approvalDecided"
        case .answerSpoken: return "Speech.answerSpoken"
        case .naturalVoiceInstalled: return "Speech.naturalVoiceInstalled"
        case .cleanupModelDownloaded: return "Cleanup.modelDownloaded"
        case .cleanupApplied: return "Cleanup.applied"
        case .permissionState: return "Permission.state"
        case .settingToggled: return "Setting.toggled"
        case .appCrashed: return "App.crashed"
        case .failureOccurred: return "App.failure"
        }
    }

    /// The GA4 event name — snake_case, and deliberately **not** derived from
    /// `name` by string munging, since these strings are what analysts will read
    /// in the GA reports and a rename there orphans a saved exploration.
    ///
    /// None collide with GA's reserved names (`first_open`, `session_start`,
    /// `user_engagement`, `in_app_purchase`, `app_remove`, …) or its reserved
    /// prefixes (`ga_`, `google_`, `firebase_`), which GA drops on sight.
    var googleName: String {
        switch self {
        case .appLaunched: return "app_launched"
        case .onboardingFinished: return "onboarding_finished"
        case .updateInstalled: return "update_installed"
        case .dictationCompleted: return "dictation_completed"
        case .dictationDiscarded: return "dictation_discarded"
        case .dictationUndelivered: return "dictation_undelivered"
        case .hotkeyChanged: return "hotkey_changed"
        case .fnKeyClaim: return "fn_key_claim"
        case .handsFreeUsed: return "hands_free_used"
        case .assistantInvoked: return "assistant_invoked"
        case .assistantRouted: return "assistant_routed"
        case .assistantToolRun: return "assistant_tool_run"
        case .assistantFailed: return "assistant_failed"
        case .noteCreated: return "note_created"
        case .notePinned: return "note_pinned"
        case .noteAudioPlayed: return "note_audio_played"
        case .noteDeleted: return "note_deleted"
        case .reminderCreated: return "reminder_created"
        case .reminderCompleted: return "reminder_completed"
        case .reminderRestored: return "reminder_restored"
        case .reminderArchiveCleared: return "reminder_archive_cleared"
        case .connectorLinked: return "connector_linked"
        case .approvalDecided: return "connector_approval_decided"
        case .answerSpoken: return "answer_spoken"
        case .naturalVoiceInstalled: return "natural_voice_installed"
        case .cleanupModelDownloaded: return "cleanup_model_downloaded"
        case .cleanupApplied: return "cleanup_applied"
        case .permissionState: return "permission_state"
        case .settingToggled: return "setting_toggled"
        case .appCrashed: return "app_crashed"
        case .failureOccurred: return "app_failure"
        }
    }

    /// Content-free parameters attached to the signal, including `category`.
    ///
    /// **One catalog for both sinks.** PostHog gets these names verbatim (they're
    /// already live in its dashboards); GA gets them converted to its snake_case
    /// convention by `GA4Limits.parameterName`, so `wordCountBucket` is registered
    /// as the custom dimension `word_count_bucket`. Doing that as a deterministic
    /// transform rather than a second hand-written dictionary is what keeps the
    /// two vendors from drifting apart.
    var parameters: [String: String] {
        var parameters = specificParameters
        // Set last and unconditionally, so a case that forgets it still lands in
        // the right bucket and no case can accidentally shadow it.
        parameters["category"] = category.rawValue
        return parameters
    }

    private var specificParameters: [String: String] {
        switch self {
        case .appLaunched, .onboardingFinished, .cleanupModelDownloaded,
             .assistantInvoked, .handsFreeUsed, .noteAudioPlayed, .noteDeleted,
             .reminderRestored, .reminderArchiveCleared, .naturalVoiceInstalled,
             .cleanupApplied:
            return [:]
        case let .dictationCompleted(engine, duration, wordCount):
            return [
                "engine": engine,
                "durationBucket": Self.durationBucket(duration),
                "wordCountBucket": Self.wordCountBucket(wordCount),
            ]
        case let .dictationDiscarded(reason):
            return ["reason": reason.rawValue]
        case let .dictationUndelivered(copied):
            return ["copied": copied ? "true" : "false"]
        case let .hotkeyChanged(to):
            return ["hotkey": to]
        case let .fnKeyClaim(restored):
            return ["restored": restored ? "true" : "false"]
        case let .assistantRouted(route):
            return ["route": route.rawValue]
        case let .assistantToolRun(tool, succeeded):
            return ["tool": tool, "succeeded": succeeded ? "true" : "false"]
        case let .assistantFailed(reason):
            return ["reason": reason.rawValue]
        case let .noteCreated(source, hasAudio):
            return ["source": source.rawValue, "hasAudio": hasAudio ? "true" : "false"]
        case let .notePinned(pinned):
            return ["pinned": pinned ? "true" : "false"]
        case let .reminderCreated(source, repeating):
            return ["source": source.rawValue, "repeating": repeating ? "true" : "false"]
        case let .reminderCompleted(repeating):
            return ["repeating": repeating ? "true" : "false"]
        case let .connectorLinked(provider, linked):
            return ["provider": provider, "linked": linked ? "true" : "false"]
        case let .approvalDecided(tool, decision):
            return ["tool": tool, "decision": decision.rawValue]
        case let .answerSpoken(voice):
            return ["voice": voice.rawValue]
        case let .settingToggled(setting, enabled):
            return ["setting": setting, "enabled": enabled ? "true" : "false"]
        case let .permissionState(accessibility, microphone):
            return [
                "accessibility": accessibility ? "granted" : "denied",
                "microphone": microphone ? "granted" : "denied",
            ]
        case let .updateInstalled(from, to):
            return ["fromVersion": from, "toVersion": to]
        case let .failureOccurred(domain, kind):
            return ["domain": domain, "kind": kind]
        case let .appCrashed(report):
            // `hasReport` is the honesty flag. An unclean exit is also what a
            // Force Quit, a kernel panic, and a power cut look like, so the two
            // cases must stay separable in the reports: `hasReport=true` is a
            // confirmed crash with a stack, `false` is "ended abruptly, cause
            // unknown". Collapsing them would inflate the crash rate with every
            // user who ever force-quit the app.
            guard let report else {
                return [
                    "hasReport": "false",
                    "exceptionType": "unknown",
                    "crashSignature": "unknown",
                ]
            }
            return [
                "hasReport": "true",
                "exceptionType": report.exceptionType,
                "crashSignal": report.signal,
                "crashSignature": report.signature,
                "crashBinary": report.binary,
                // The version that *crashed*, which is not necessarily the one
                // reporting it — the report is read on the next launch, which may
                // already be a Sparkle update later.
                "crashedVersion": report.crashedVersion,
            ]
        }
    }

    /// Coarse session-length bucket — never the exact duration.
    static func durationBucket(_ seconds: TimeInterval) -> String {
        switch seconds {
        case ..<5: return "0-5s"
        case ..<15: return "5-15s"
        case ..<30: return "15-30s"
        case ..<60: return "30-60s"
        case ..<180: return "1-3m"
        default: return "3m+"
        }
    }

    /// Coarse transcript-length bucket — never the exact word count or text.
    static func wordCountBucket(_ count: Int) -> String {
        switch count {
        case ..<1: return "0"
        case ..<10: return "1-9"
        case ..<25: return "10-24"
        case ..<50: return "25-49"
        case ..<100: return "50-99"
        case ..<250: return "100-249"
        default: return "250+"
        }
    }
}
