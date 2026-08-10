import Foundation
import Observation

enum RecordingPhase: Equatable {
    case idle
    case preparingModels
    case recording
    case stopping
    case failed(String)
}

struct ModelDownloadSnapshot: Equatable {
    let fractionCompleted: Double
    let detail: String
}

struct TranscriptSnapshot: Equatable {
    var latestPartial: String = ""
    var latestConfirmed: String = ""
    var finalText: String = ""
}

struct TranscriptHistoryEntry: Identifiable, Equatable, Codable {
    let id: UUID
    let text: String
    let createdAt: Date
    let engineRawValue: String

    init(id: UUID = UUID(), text: String, createdAt: Date = Date(), engineRawValue: String) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.engineRawValue = engineRawValue
    }

    var preview: String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = 64
        if trimmed.count <= limit { return trimmed }
        let idx = trimmed.index(trimmed.startIndex, offsetBy: limit)
        return String(trimmed[..<idx]) + "…"
    }
}

@MainActor
@Observable
final class AppState {
    static let historyDefaultsKey = "WhisperMaster.transcriptHistory.v1"
    static let historyLimit = 50
    static let vocabularyDefaultsKey = "WhisperMaster.customVocabulary.v1"
    // `WhisperMaster.appearance.v1` held the retired light/dark/system preference.
    // The app is light-only now (`NSApp.appearance` is pinned to `.aqua` at
    // launch), so the key is left on disk and never read — same reasoning as the
    // retired hotkey key below. Don't reuse the name.
    static let hotkeyDefaultsKey = "WhisperMaster.hotkey.v1"
    /// The coding-agent key. Stored as the raw option name, or "" for off, so the
    /// absence of the key means "never chosen" and an empty string means "chosen
    /// off" — two states a plain optional string cannot tell apart.
    static let agentHotkeyDefaultsKey = "WhisperMaster.agentHotkey.v1"
    /// Where a spoken prompt opens a new agent session when nothing is running.
    static let agentDirectoryDefaultsKey = "WhisperMaster.agentDirectory.v1"
    // `WhisperMaster.dayQueryHotkey.v1` was the retired second push-to-talk key.
    // Left on disk rather than migrated away — it is never read, and deleting a key
    // buys nothing. Don't reuse the name for something else.
    static let holdToTalkDefaultsKey = "WhisperMaster.holdToTalk.v1"
    static let remindersEnabledDefaultsKey = "WhisperMaster.remindersEnabled.v1"
    static let quickActionsDefaultsKey = "WhisperMaster.quickActions.v1"
    static let keepAwakeForRemoteDefaultsKey = "WhisperMaster.keepAwakeForRemote.v1"
    static let remoteDictationEnabledDefaultsKey = "WhisperMaster.remoteDictationEnabled.v1"
    static let analyticsEnabledDefaultsKey = "WhisperMaster.analyticsEnabled.v1"

    /// The persisted analytics opt-in, readable **without building an `AppState`**.
    ///
    /// `AppDelegate` needs this at the very top of `applicationDidFinishLaunching`
    /// so the crash handler is installed before the launch work that is most
    /// likely to crash (model load, Metal warm-up). Reading it off `viewModel`
    /// there would force the lazy `DictationViewModel` — and the whole engine
    /// graph behind it — to initialize earlier than it does today, which is a
    /// launch-order change nobody asked for. `init` below uses the same property,
    /// so the default can never drift between the two readers.
    /// `nonisolated` because it reads `UserDefaults` and no actor state — the
    /// point is to answer without an `AppState` existing at all.
    nonisolated static var persistedAnalyticsEnabled: Bool {
        UserDefaults.standard.object(forKey: analyticsEnabledDefaultsKey) as? Bool ?? true
    }
    static let usageSyncEnabledDefaultsKey = "WhisperMaster.usageSyncEnabled.v1"
    static let notesSyncEnabledDefaultsKey = "WhisperMaster.notesSyncEnabled.v1"
    static let reminderDefaultAlertStyleDefaultsKey = "WhisperMaster.reminderDefaultAlertStyle.v1"
    static let reminderDefaultSoundDefaultsKey = "WhisperMaster.reminderDefaultSound.v1"
    static let removeFillerWordsDefaultsKey = "WhisperMaster.removeFillerWords.v1"
    static let learnCorrectionsDefaultsKey = "WhisperMaster.learnCorrections.v1"
    static let llmCleanupDefaultsKey = "WhisperMaster.llmCleanup.v1"
    static let llmGrammarPolishDefaultsKey = "WhisperMaster.llmGrammarPolish.v1"
    static let speakAnswersDefaultsKey = "WhisperMaster.speakAnswers.v1"
    // `WhisperMaster.speakAutomationAnswers.v1` governed whether scheduled
    // automations spoke when they fired. Automations are gone, so it is left on disk
    // and never read — same posture as the retired hotkey and appearance keys above.
    // Don't reuse the name.
    static let answerVoiceEngineDefaultsKey = "WhisperMaster.answerVoiceEngine.v1"
    static let systemVoiceDefaultsKey = "WhisperMaster.systemVoice.v1"
    static let naturalVoiceDefaultsKey = "WhisperMaster.naturalVoice.v1"
    /// How long the "nowhere to type that" notch hint stays down before it
    /// retracts on its own.
    static let undeliveredBannerDuration: TimeInterval = 7
    /// How long the "learned a correction" notch confirmation stays down.
    static let learnedBannerDuration: TimeInterval = 4
    /// How long the "smart cleanup is ready" notch confirmation stays down.
    static let cleanupReadyBannerDuration: TimeInterval = 5
    /// How long the success "delivered" checkmark holds in the notch after a
    /// transcript lands at the cursor, before the surface retracts.
    static let deliveredBeatDuration: TimeInterval = 1.1
    /// How long a failed-dictation message stays in the notch before it retracts
    /// on its own (so a failure isn't a wordless glyph that lingers forever).
    static let failedBannerDuration: TimeInterval = 6
    /// How long the "note saved / reminder set" confirmation stays in the notch
    /// after a voice command lands in Notes & Reminders. The default window; a
    /// longer assistant answer overrides it per-confirmation
    /// (`commandConfirmationWindow`).
    static let commandConfirmationDuration: TimeInterval = 4
    /// How long an *assistant* answer to a spoken command holds. Same reasoning as
    /// `daySummaryDuration`: the user asked, and is reading a sentence rather than
    /// checking a checkmark.
    static let commandAnswerDuration: TimeInterval = 10
    /// How long the interactive "when should this reminder be?" prompt stays down
    /// awaiting a tap. Generous, but bounded — if the user walks away it retracts
    /// (and no reminder is created, since none of the times were chosen).
    static let reminderTimePromptDuration: TimeInterval = 30
    /// How long a "what's my day" answer stays down in the notch. Longer than the
    /// other hints — the user asked for it and is reading a few facts.
    static let daySummaryDuration: TimeInterval = 12
    /// What's left of the day-summary window once the voice stops reading it. While
    /// speech is running the clock is pinned (the refresh loop pushes `daySummaryAt`
    /// forward), so this is only the tail: long enough to finish reading the line you
    /// just heard, short enough that a thirty-second answer doesn't then leave the band
    /// hanging for another twelve. Same paused-clock idea as `dueReminderAt`.
    static let spokenAnswerTailHold: TimeInterval = 4
    /// How long a due reminder stays down in the notch. Longer than the passive
    /// hints — it's a scheduled alert the user set for themselves, and missing it
    /// is the failure mode. The clock only runs while it's actually on screen
    /// (see `canShowDueReminderBanner`).
    static let dueReminderBannerDuration: TimeInterval = 8
    /// How long a due reminder stays down *after* it's been ticked off — the undo
    /// window for the checkbox. Short: the alert has been answered, and leaving a
    /// struck-through line on the bezel for the full window is just noise.
    static let dueReminderAnsweredHold: TimeInterval = 3
    /// How long the polished transcript stays in the notch after the on-device
    /// polish rewrote a dictation — long enough to read the new wording.
    static let polishedBeatDuration: TimeInterval = 4

    var selectedEngine: TranscriberEngine = .slidingWindow
    var preparedEngine: TranscriberEngine?
    var preparingEngine: TranscriberEngine?
    /// The push-to-talk key. Defaults to the Globe/**fn** key — the one modifier
    /// on a MacBook that isn't already spoken for by a shortcut you'd type mid
    /// sentence. Persisted, so a change survives a relaunch.
    var hotkey: HotkeyManager.HotkeyOption = .fn {
        didSet { UserDefaults.standard.set(hotkey.rawValue, forKey: Self.hotkeyDefaultsKey) }
    }
    var holdToTalkEnabled: Bool = true {
        didSet { UserDefaults.standard.set(holdToTalkEnabled, forKey: Self.holdToTalkDefaultsKey) }
    }

    /// The key that talks to a coding agent, or nil for off.
    ///
    /// A second physical key rather than another chord, and **user-chosen rather
    /// than fixed**, because it has to stay off whatever the person already uses for
    /// dictation — which is not the default on most installs. `nil` is a real state:
    /// somebody with no kunai should not be holding a key aside for it.
    ///
    /// Talking to an agent genuinely needs its own way in. Everything else in the
    /// notch is either an interrupt that arrives on its own or a re-label of a
    /// dictation already in flight; this one *starts* something, and nothing can
    /// infer that from the words (see the prohibition on inferring intent in the
    /// root `CLAUDE.md`).
    var agentHotkey: HotkeyManager.HotkeyOption? = nil {
        didSet {
            UserDefaults.standard.set(agentHotkey?.rawValue ?? "", forKey: Self.agentHotkeyDefaultsKey)
        }
    }

    /// The agent key, but only when it is actually usable: a key that collides with
    /// push-to-talk would swallow one of the two, and the dictation key wins because
    /// it is the one the whole app is named for.
    var effectiveAgentHotkey: HotkeyManager.HotkeyOption? {
        guard let agentHotkey, agentHotkey != hotkey else { return nil }
        return agentHotkey
    }
    /// True while a double-tap has latched the running dictation open, so it keeps
    /// listening with the key released. Transient (never persisted); set by the
    /// view model, cleared whenever a recording starts or stops.
    var handsFreeActive: Bool = false
    var autoPasteEnabled: Bool = true
    var soundEnabled: Bool = true
    var hidePillWhenIdle: Bool = true
    var phase: RecordingPhase = .idle
    var download: ModelDownloadSnapshot?
    /// True while the system default audio input is a Bluetooth device (set by
    /// `BluetoothInputMonitor`). Such a mic forces the headset into low-quality
    /// "call mode", so the notch offers a one-tap switch to the built-in mic.
    var bluetoothInputActive: Bool = false
    /// The user dismissed (or acted on) the Bluetooth-mic hint this session.
    /// Reset when the Bluetooth input goes away so the hint can return.
    var bluetoothBannerDismissed: Bool = false
    /// The gentle-reminder line currently dropped down in the notch, or `nil`.
    /// Transient (never persisted); written only by `ReminderScheduler`.
    var activeReminder: String?
    /// The reminder currently being announced in the notch, having come due with
    /// the `.notification` alert style (the `.alarm` style takes its own window
    /// instead). Transient (never persisted); set by the AppDelegate's due-reminder
    /// poll once the notch is free to take it, cleared when the window elapses.
    /// The reminder **exactly as it was when it fired**, captured before
    /// `NotesStore.markFired` touches it — which is what makes the banner's
    /// checkbox reversible: un-checking hands this snapshot back to
    /// `NotesStore.restoreReminder`.
    var dueReminder: ReminderItem?
    var dueReminderAt: Date?
    /// Whether the user has ticked the reminder off from the notch band. Held here
    /// rather than read back off `isCompleted` because ticking a *repeating*
    /// reminder rolls it to its next occurrence instead of completing it — the box
    /// has to stay checked either way, or the tick reads as having done nothing.
    var dueReminderCompleted: Bool = false
    /// A spoken reminder that named no time — surfaced as an interactive notch
    /// quick-prompt ("when?"). Transient; set by the view model when a reminder
    /// command lands without a time, cleared once the user picks or it expires.
    var pendingReminderPrompt: PendingReminderPrompt?
    var pendingReminderPromptAt: Date?
    /// A brief "note saved" / "reminder set" line shown in the notch right after a
    /// voice command routes into Notes & Reminders (the paste is suppressed, so
    /// this is the only feedback). Transient; auto-expired by the refresh loop.
    ///
    /// Since the chord became an agent this also carries the assistant's own report
    /// of what it did ("Two meetings today", "Posted to #ops") — the paste is
    /// suppressed either way, so this band is the whole of the answer.
    var commandConfirmation: String?
    /// The line under it: where the thing went, or what answered.
    var commandConfirmationDetail: String = "Saved to Notes & Reminders"
    /// SF Symbol for the band, so a reminder, a note and an answer aren't all a
    /// checkmark.
    var commandConfirmationIcon: String = "checkmark.circle.fill"
    /// How long this particular confirmation holds. A four-word "Note saved" is read
    /// at a glance; a sentence the assistant came back with is not, so the caller
    /// sets the window to match what it's asking the user to read.
    var commandConfirmationWindow: TimeInterval = AppState.commandConfirmationDuration
    var commandConfirmationAt: Date?
    /// The answer to a "what's my day" query, dropped down in the notch. Set by the
    /// view model after aggregating the connectors; transient (never persisted),
    /// auto-expired by the refresh loop after `daySummaryDuration`.
    var activeDaySummary: DaySummary?
    var daySummaryAt: Date?
    /// True while an answer is being read aloud. Written by the view model from
    /// `AnswerSpeaker`'s callbacks; drives the banner's speaker glyph and pauses the
    /// banner's expiry clock so a spoken answer can't outlive its own caption.
    var isSpeakingAnswer: Bool = false
    /// Whether the answer currently on the band is being (or was) spoken. Picks which
    /// window applies — an answer nobody read aloud keeps the full silent-reading
    /// duration, rather than snapping away after the short spoken tail.
    var daySummaryWasSpoken: Bool = false
    /// Answers to questions the user asked, newest first. The notch line is truncated
    /// and gone in seconds, and a day query deliberately skips the transcript history —
    /// without this the answer is unrecoverable. Capped; persisted.
    var answerLog: [AnsweredQuestion] = []
    /// A one-shot request to open the Settings window on a given section — set by
    /// the tappable command-confirmation banner ("tap to change") so a spoken
    /// reminder's default time is one click from adjustable. Transient; consumed
    /// (and cleared) by `SettingsView` the moment it flips.
    var requestedSettingsSection: SettingsSection?
    /// One-shot request to open a *fresh* note / reminder editor once the Notes &
    /// Reminders page is on screen — set by the notch quick-actions panel, which
    /// sits on the bezel as a non-activating panel and so can't host a text field
    /// of its own. Transient; consumed (and cleared) by `NotesSettingsView`.
    var requestedNotesComposer: NotesComposerRequest?
    /// When the last dictation finished with no focused text field to paste
    /// into — so it was saved to history and surfaced as a notch hint instead.
    /// Transient (never persisted); set by the view model, auto-expired by the
    /// AppDelegate refresh loop once `undeliveredBannerDuration` has passed.
    var undeliveredTranscriptAt: Date?
    /// The transcript that had nowhere to go, kept alongside
    /// `undeliveredTranscriptAt` so the hint can show the words and offer a Copy
    /// button. Replaced in place if a late polish produces better wording, so
    /// what the button copies is always the best version. Transient.
    var undeliveredText: String?
    /// True while the optional on-device polish is running over the transcript we
    /// just delivered. Drives the notch "thinking" orb — the deterministic text
    /// is already pasted, so this is purely a "still improving it" signal.
    var isPolishing: Bool = false
    /// The polished wording, once the on-device pass produced one that actually
    /// reached the user (pasted in place, or copied). Shown briefly in the notch
    /// so a rewrite the user didn't ask twice for isn't invisible. Transient;
    /// auto-expired by the AppDelegate refresh loop after `polishedBeatDuration`.
    var polishedText: String?
    var polishedAt: Date?
    /// The canonical word just auto-learned into the glossary, and when — drives
    /// a brief notch confirmation so the silent addition is visible. Transient
    /// (never persisted); auto-expired by the AppDelegate refresh loop after
    /// `learnedBannerDuration`.
    var learnedTerm: String?
    var learnedTermAt: Date?
    /// When the last dictation successfully landed at the cursor — drives the
    /// brief success "delivered" checkmark in the notch. Transient (never
    /// persisted); auto-expired by the AppDelegate refresh loop after
    /// `deliveredBeatDuration`.
    var deliveredAt: Date?
    /// When the last dictation *failed* — drives the (auto-expiring) failure
    /// message in the notch. Transient; cleared by the view model / refresh loop.
    var failedAt: Date?
    /// Live progress of the on-device cleanup-model download, shown **only** in
    /// Settings (never the notch or tray — that's a hard UX rule). `nil` when no
    /// download is in flight. Transient; written by `CleanupModelManager`.
    var cleanupModelDownload: ModelInstaller.Progress?
    /// When the cleanup model finished downloading + warming — drives a one-shot
    /// "smart cleanup is ready" notch banner. Transient (never persisted),
    /// auto-expired by the AppDelegate refresh loop after `cleanupReadyBannerDuration`.
    var cleanupModelReadyAt: Date?
    /// Whether the cleanup model is currently loaded and usable. Transient;
    /// mirrors `MlxCleanupService.isReady` synchronously for the Settings status
    /// (works for both the R2 and Hugging Face load paths). Written by
    /// `CleanupModelManager`.
    var cleanupModelReady: Bool = false
    /// Set when the load fails after retries — surfaces an honest error + Retry in
    /// Settings instead of an eternal "Preparing…". Written by `CleanupModelManager`.
    var cleanupModelFailed: Bool = false
    /// One-shot flag the Settings "Retry" button sets; drained by the manager on
    /// the next refresh tick to re-attempt a failed load.
    var cleanupRetryRequested: Bool = false
    /// Whether gentle "you haven't used me in a while" reminders are enabled.
    /// Persisted; **on by default** — the app lives in the notch with no window to
    /// come back to, so an install nobody is reminded of is an install nobody uses.
    /// The cadence is conservative and the Settings toggle is a hard off-switch.
    var remindersEnabled: Bool = true {
        didSet { UserDefaults.standard.set(remindersEnabled, forKey: Self.remindersEnabledDefaultsKey) }
    }
    /// Whether resting the pointer on the notch opens the quick-actions panel
    /// (reminders + notes at a glance). Persisted; **on by default** — it's an
    /// affordance on a surface that otherwise only speaks when spoken to, and the
    /// toggle is the way out for anyone whose pointer lives up there.
    var quickActionsEnabled: Bool = true {
        didSet { UserDefaults.standard.set(quickActionsEnabled, forKey: Self.quickActionsDefaultsKey) }
    }
    /// Keep this Mac awake so the phone can reach it for remote dictation even
    /// after it's been sitting locked and idle. Persisted; **opt-in** — off by
    /// default because it prevents idle sleep entirely (a battery cost). When off,
    /// an in-progress remote session still holds the Mac awake on its own.
    var keepAwakeForRemote: Bool = false {
        didSet { UserDefaults.standard.set(keepAwakeForRemote, forKey: Self.keepAwakeForRemoteDefaultsKey) }
    }
    /// Accept dictation streamed from a paired phone (or another of your Macs).
    ///
    /// Persisted; **opt-in** — off by default because turning it on opens a
    /// listening socket on this Mac. It used to start unconditionally at launch
    /// for every user, which meant every install ran a network service its owner
    /// had never asked for. Connections are PSK-authenticated and encrypted
    /// (see `RemotePairing`), but "no listener at all" is still the right default
    /// for anyone who never dictates from their phone.
    var remoteDictationEnabled: Bool = false {
        didSet { UserDefaults.standard.set(remoteDictationEnabled, forKey: Self.remoteDictationEnabledDefaultsKey) }
    }
    /// Learn vocabulary from corrections: after a paste, if the user replaces
    /// one misheard word, add "typed: heard" to the glossary automatically.
    /// Persisted; **on by default** — it only ever reads the field we pasted
    /// into, briefly, and the toggle is the opt-out.
    var learnCorrectionsEnabled: Bool = true {
        didSet { UserDefaults.standard.set(learnCorrectionsEnabled, forKey: Self.learnCorrectionsDefaultsKey) }
    }
    /// Strip unambiguous spoken fillers ("um", "uh", "hmm") from transcripts.
    /// Persisted; **on by default** — nobody dictates "um" on purpose, and the
    /// toggle is the escape hatch if it ever eats something intentional.
    var removeFillerWordsEnabled: Bool = true {
        didSet { UserDefaults.standard.set(removeFillerWordsEnabled, forKey: Self.removeFillerWordsDefaultsKey) }
    }
    /// Run the finished transcript through the on-device qwen "smart cleanup"
    /// pass (fixes self-corrections/false starts). Persisted; **opt-in** — off
    /// until the user turns it on (onboarding or Settings), since it downloads a
    /// ~1.8 GB model. Dictation works normally whether or not it's ready.
    var llmCleanupEnabled: Bool = false {
        didSet { UserDefaults.standard.set(llmCleanupEnabled, forKey: Self.llmCleanupDefaultsKey) }
    }
    /// Experimental sub-mode of smart cleanup: when on, the model fully polishes
    /// grammar and wording (reads well) instead of only trimming disfluencies.
    /// Off by default; only meaningful while `llmCleanupEnabled` is on.
    var llmGrammarPolishEnabled: Bool = false {
        didSet { UserDefaults.standard.set(llmGrammarPolishEnabled, forKey: Self.llmGrammarPolishDefaultsKey) }
    }
    /// Whether spoken numbers/symbols are rewritten to written form (ITN) on the
    /// final transcript — "twenty five" → "25", "at gmail dot com" → "@gmail.com".
    /// Persisted; **on by default**. The escape hatch if a conversion ever misfires.
    var itnEnabled: Bool = true {
        didSet { UserDefaults.standard.set(itnEnabled, forKey: FormattingPreference.defaultsKey) }
    }
    /// Opt-in to use Apple's on-device LLM for formatting instead of the built-in
    /// rules. **Off by default.** Turning it off drops the model session so it
    /// stops consuming resources — nothing Apple-Intelligence-related stays loaded.
    var useAppleIntelligence: Bool = false {
        didSet {
            UserDefaults.standard.set(useAppleIntelligence, forKey: AppleIntelligencePreference.defaultsKey)
            if !useAppleIntelligence {
                Task { await TextFormatterProvider.shared.releaseApple() }
            }
        }
    }
    /// Share usage analytics (PostHog + GA4). **On by default — opt-out.**
    ///
    /// ⚠️ **This is no longer anonymous.** It was, when the only identifier was a
    /// random per-install UUID; since `Analytics.identify` the person profile
    /// carries the **Clerk user id and email**, because "which customer uses which
    /// feature" cannot be answered by a per-install id. The *events* are still
    /// content-free — never a transcript, a note, or a recording, only app version,
    /// OS, and coarse bucketed feature counts — but they are attributable to a
    /// named account.
    ///
    /// The on-by-default posture predates that change and is worth revisiting: an
    /// opt-out default is a much easier argument for anonymous counts than for
    /// account-linked ones. `RegulatedMode` still overrides it outright, and the
    /// Settings copy no longer claims anonymity. Toggling starts/stops the SDK live.
    var analyticsEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(analyticsEnabled, forKey: Self.analyticsEnabledDefaultsKey)
            Analytics.shared.setEnabled(analyticsEnabled)
        }
    }
    /// Back up your usage stats to your account and keep them in sync across
    /// your Macs. **On by default — opt-out.** Local tracking (the Insights
    /// dashboard) always runs; this only governs whether the per-day rollups are
    /// pushed to the cloud, attributed to the signed-in account.
    var usageSyncEnabled: Bool = true {
        didSet { UserDefaults.standard.set(usageSyncEnabled, forKey: Self.usageSyncEnabledDefaultsKey) }
    }
    /// Back up notes & reminders to your account and sync them across your Macs.
    /// **On by default — opt-out.** Local storage always works; this only governs
    /// the best-effort cloud push/pull.
    var notesSyncEnabled: Bool = true {
        didSet { UserDefaults.standard.set(notesSyncEnabled, forKey: Self.notesSyncEnabledDefaultsKey) }
    }
    /// True while the running session is armed as a **spoken command** — the user
    /// held the command chord (fn + control), so the finished transcript becomes a
    /// note or a reminder instead of being typed. Transient (never persisted); set
    /// by the view model, cleared whenever a session ends. Read by the notch so the
    /// band says which of the two things it's doing.
    ///
    /// There is no *preference* behind this: arming is the held chord itself, which
    /// is why the old always-on "Create by voice" toggle is gone. An ordinary
    /// dictation that merely opens with "remind me…" is now just text again.
    var commandCaptureArmed: Bool = false

    /// True while the agent key is holding a capture whose words go to a coding
    /// agent rather than being typed. Transient; mirrored from the view model so the
    /// band can say which session it is about to send to.
    var agentCaptureArmed: Bool = false

    /// The repository a spoken prompt opens a **new** session in, when nothing is
    /// running yet.
    ///
    /// Deliberately empty by default rather than falling back to the home directory:
    /// starting a coding agent loose in `~` is the kind of helpful guess that ends in
    /// a bad afternoon. With nothing set and nothing running, the words are held in
    /// the undelivered banner instead, which says what to do.
    var agentDefaultDirectory: String = "" {
        didSet {
            UserDefaults.standard.set(
                agentDefaultDirectory, forKey: Self.agentDirectoryDefaultsKey)
        }
    }

    /// Where a new session opens: the explicit setting, else the directory of a
    /// session that already exists, so the common case needs no setup at all.
    var resolvedAgentDirectory: String? {
        let configured = agentDefaultDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty { return configured }
        return agents.lastKnownDirectory
    }
    /// True while the assistant is carrying out a finished command — the tool-calling
    /// loop is running. The band is already up (`isPolishing` holds it there for the
    /// thinking orb); this is what stops it captioning the work "Polishing", which
    /// would describe a rewrite that isn't happening.
    var commandAgentRunning: Bool = false
    /// What that loop is doing right now, so the band can name the connector it's
    /// waiting on ("Checking Personal") instead of saying "Working on it" for the
    /// whole run. Nil outside a run, and while the loop is between steps the last
    /// one stands — see `AgentLoop.onStep`.
    var agentActivity: AgentActivity?
    /// Default alert style new reminders inherit (per-reminder overridable).
    /// Persisted as the enum raw value. This is the "configure in settings" knob.
    var reminderDefaultAlertStyle: ReminderAlertStyle = .notification {
        didSet { UserDefaults.standard.set(reminderDefaultAlertStyle.rawValue, forKey: Self.reminderDefaultAlertStyleDefaultsKey) }
    }
    /// Default sound new reminders (and the "Test sound" button) use. Persisted.
    var reminderDefaultSound: String = ReminderSound.defaultName {
        didSet { UserDefaults.standard.set(reminderDefaultSound, forKey: Self.reminderDefaultSoundDefaultsKey) }
    }
    /// Availability of Apple's on-device model (drives the Settings hint).
    /// Refreshed by the status loop so it updates live as the model downloads.
    var appleIntelligenceStatus: AppleIntelligenceStatus = .current
    /// True while the R2 mirror was unavailable and the model is coming from the
    /// slower HuggingFace fallback — surfaced in the UI so a slow prepare is
    /// never a silent mystery.
    var usingFallbackModelSource: Bool = false
    var transcript = TranscriptSnapshot()
    var statusMessage: String = "Getting voice engine ready..."
    var audioLevel: Float = 0
    var history: [TranscriptHistoryEntry] = []
    /// User-maintained terms to bias decoding toward (proper nouns, jargon
    /// like "RAG"). Persisted; applied on each recording.
    var customVocabulary: [String] = [] {
        didSet { Self.persistVocabulary(customVocabulary) }
    }

    /// The device mesh: this Mac plus other Macs running Whisper Master on the
    /// network. Written by `MeshCoordinator`; observed by the mesh settings panel.
    var meshPeers: [MeshPeer] = []

    /// Durable, on-device usage stats behind the Insights dashboard (per-day
    /// rollups, streaks, per-app breakdown). **Per-account:** starts empty and is
    /// scoped to the signed-in Clerk user by `AppDelegate` (`usageStore.activate`)
    /// once auth resolves, so each user sees only their own numbers. Written only
    /// via `usageStore.record(...)` from the view model at each stop.
    let usageStore = UsageStore(load: false)

    /// Per-account notes & reminders behind the Notes & Reminders tab. Like
    /// `usageStore`: starts empty and is scoped to the signed-in account by
    /// `AppDelegate` (`notesStore.activate`) once auth resolves.
    let notesStore = NotesStore(load: false)

    /// Playback for the recordings behind spoken notes. One per app, so starting a
    /// second note's audio stops the first. Playback only — it never touches the
    /// capture graph (see `NoteAudioPlayer`).
    let noteAudioPlayer = NoteAudioPlayer()

    /// The user's connector **instances** behind the Connectors tab — many named
    /// connections per kind ("Google Calendar Work"). Like `usageStore` and
    /// `notesStore`: starts empty and is scoped to the signed-in account by
    /// `AppDelegate` (`connectorStore.activate(userID:)`) once auth resolves.
    let connectorStore = ConnectorInstanceStore(load: false)

    /// The one write awaiting the user's consent, surfaced as a notch card.
    let approvals = ApprovalCoordinator()

    /// The coding-agent surface: kunai sessions on this Mac, and whatever one of
    /// them is currently waiting on a person for.
    ///
    /// Starts dormant — `start()` is called from the app layer once, post-auth — so
    /// `swift test` and the headless snapshot renderer can build an `AppState`
    /// without opening a socket or polling a port. Same posture as
    /// `UsageStore(load: false)`.
    let agents = AgentSurfaceController()

    /// Whether a coding agent is holding a turn open waiting for an answer.
    ///
    /// This yields to `approvals.pending` and to nothing else above it: both are
    /// consent cards with a caller suspended behind them, but the connector card is
    /// the immediate consequence of something the user just said out loud and it
    /// denies itself on a timeout, so it must not be the one that waits.
    var shouldShowAgentAsk: Bool {
        agents.ask != nil && approvals.pending == nil
    }

    /// Whether the user has the agent surface open to look at it. Below the ask,
    /// because a question someone is waiting on outranks browsing, and suppressed
    /// while dictating so the band can report the recording it is holding.
    var shouldShowAgentGlance: Bool {
        agents.isGlanceOpen && !shouldShowAgentAsk && approvals.pending == nil
            && phase == .idle && !agentCaptureArmed && !shouldShowAgentWorking
    }

    /// A session revealed by a send that is still mid-turn.
    ///
    /// It gets the slim **row** rather than the full tail, because a turn runs for
    /// minutes and a panel-height band over the menu bar for minutes is an
    /// obstruction rather than ambient awareness. The tail comes back the moment
    /// there is a finished reply to read.
    ///
    /// Only a *revealed* session does this. A glance the user opened deliberately
    /// shows what they asked for, running or not.
    var shouldShowAgentWorking: Bool {
        agents.isGlanceOpen && agents.revealedAt != nil
            && agents.openSession?.state == .running
            && !shouldShowAgentAsk && approvals.pending == nil
            && phase == .idle && !agentCaptureArmed
    }

    /// Opt-in, off by default — same posture as `llmCleanupEnabled`. When off, a day
    /// query answers from the deterministic `DaySummaryService` and no tool is ever
    /// called.
    var connectorAgentEnabled: Bool = false {
        didSet { UserDefaults.standard.set(connectorAgentEnabled, forKey: Self.connectorAgentDefaultsKey) }
    }

    static let connectorAgentDefaultsKey = "WhisperMaster.connectorAgent.enabled.v1"

    // MARK: - Reading answers aloud

    /// Speak the answer when the user asks a question out loud.
    ///
    /// **On by default**, unlike the other assistant switches. The only things that
    /// reach it are the dedicated day-query key and an explicit day-query wake phrase —
    /// you asked with your voice, so an answer you can hear is the expected outcome, and
    /// ordinary dictation can never trigger it.
    var speakAnswersEnabled: Bool = true {
        didSet { UserDefaults.standard.set(speakAnswersEnabled, forKey: Self.speakAnswersDefaultsKey) }
    }

    var answerVoiceEngine: AnswerVoiceEngine = .system {
        didSet {
            UserDefaults.standard.set(answerVoiceEngine.rawValue, forKey: Self.answerVoiceEngineDefaultsKey)
        }
    }

    /// The chosen `AVSpeechSynthesisVoice.identifier`, or empty for "Automatic" —
    /// which re-resolves to the best installed voice each time, so downloading a better
    /// one upgrades the app with no setting to change.
    var systemVoiceIdentifier: String = "" {
        didSet { UserDefaults.standard.set(systemVoiceIdentifier, forKey: Self.systemVoiceDefaultsKey) }
    }

    /// The chosen Kokoro voice pack id.
    var naturalVoiceID: String = NaturalVoiceCatalog.defaultVoice {
        didSet { UserDefaults.standard.set(naturalVoiceID, forKey: Self.naturalVoiceDefaultsKey) }
    }

    /// Live progress of the natural-voice download, shown **only** in Settings — same
    /// hard rule as `cleanupModelDownload` (never the notch, never the tray). Transient.
    var naturalVoiceDownload: ModelInstaller.Progress?
    /// The natural models are on disk and loaded. Transient; reconciled each tick.
    var naturalVoiceReady: Bool = false
    /// The download or the load failed — Settings offers a retry rather than leaving the
    /// user wondering why the voice never changed. Transient.
    var naturalVoiceFailed: Bool = false
    /// One-shot: the user tapped Retry / Download. Consumed by the view model.
    var naturalVoiceRetryRequested: Bool = false

    init() {
        history = Self.loadHistory()
        answerLog = AnswerLog.load()
        customVocabulary = Self.loadVocabulary()
        // The push-to-talk key is persisted; absent means a fresh install, which
        // takes the fn default. There is only one key now — the assistant is the
        // fn+control chord, not a second physical key — so no collision to break.
        hotkey = (UserDefaults.standard.string(forKey: Self.hotkeyDefaultsKey))
            .flatMap(HotkeyManager.HotkeyOption.init(rawValue:)) ?? .fn
        // The agent key is off until chosen. Deliberately not defaulted to a free
        // key: reserving a modifier on every Mac for a server almost nobody runs is
        // the kind of quiet imposition the fn-claim rules exist to prevent.
        agentHotkey = (UserDefaults.standard.string(forKey: Self.agentHotkeyDefaultsKey))
            .flatMap { $0.isEmpty ? nil : HotkeyManager.HotkeyOption(rawValue: $0) }
        agentDefaultDirectory =
            UserDefaults.standard.string(forKey: Self.agentDirectoryDefaultsKey) ?? ""
        // Opt-out: on unless the user has explicitly turned it off.
        holdToTalkEnabled = UserDefaults.standard.object(forKey: Self.holdToTalkDefaultsKey) as? Bool ?? true
        // Opt-in: off until the user has explicitly turned it on.
        connectorAgentEnabled = UserDefaults.standard.object(forKey: Self.connectorAgentDefaultsKey) as? Bool ?? false
        // Opt-out: you asked out loud, so an answer you can hear is the default.
        speakAnswersEnabled = UserDefaults.standard.object(forKey: Self.speakAnswersDefaultsKey) as? Bool ?? true
        answerVoiceEngine = (UserDefaults.standard.string(forKey: Self.answerVoiceEngineDefaultsKey))
            .flatMap(AnswerVoiceEngine.init(rawValue:)) ?? .system
        systemVoiceIdentifier = UserDefaults.standard.string(forKey: Self.systemVoiceDefaultsKey) ?? ""
        naturalVoiceID = UserDefaults.standard.string(forKey: Self.naturalVoiceDefaultsKey)
            ?? NaturalVoiceCatalog.defaultVoice
        // Opt-out: on unless the user has explicitly turned it off.
        remindersEnabled = UserDefaults.standard.object(forKey: Self.remindersEnabledDefaultsKey) as? Bool ?? true
        // Opt-out: on unless the user has explicitly turned it off.
        quickActionsEnabled = UserDefaults.standard.object(forKey: Self.quickActionsDefaultsKey) as? Bool ?? true
        // Opt-in: off until the user has explicitly turned it on.
        keepAwakeForRemote = UserDefaults.standard.object(forKey: Self.keepAwakeForRemoteDefaultsKey) as? Bool ?? false
        // Opt-in: no listening socket until the user explicitly asks for one.
        remoteDictationEnabled = UserDefaults.standard.object(forKey: Self.remoteDictationEnabledDefaultsKey) as? Bool ?? false
        // Opt-out: on unless the user has explicitly turned it off.
        analyticsEnabled = Self.persistedAnalyticsEnabled
        // Opt-out: on unless the user has explicitly turned it off.
        usageSyncEnabled = UserDefaults.standard.object(forKey: Self.usageSyncEnabledDefaultsKey) as? Bool ?? true
        // Opt-out: on unless the user has explicitly turned it off.
        notesSyncEnabled = UserDefaults.standard.object(forKey: Self.notesSyncEnabledDefaultsKey) as? Bool ?? true
        reminderDefaultAlertStyle = (UserDefaults.standard.string(forKey: Self.reminderDefaultAlertStyleDefaultsKey))
            .flatMap(ReminderAlertStyle.init(rawValue:)) ?? .notification
        reminderDefaultSound = ReminderSound.resolved(
            UserDefaults.standard.string(forKey: Self.reminderDefaultSoundDefaultsKey) ?? ReminderSound.defaultName)
        // Opt-out: on unless the user has explicitly turned it off.
        removeFillerWordsEnabled = UserDefaults.standard.object(forKey: Self.removeFillerWordsDefaultsKey) as? Bool ?? true
        // Opt-out: on unless the user has explicitly turned it off.
        learnCorrectionsEnabled = UserDefaults.standard.object(forKey: Self.learnCorrectionsDefaultsKey) as? Bool ?? true
        // Opt-in: off until the user has explicitly turned it on (~1.8 GB model).
        llmCleanupEnabled = UserDefaults.standard.object(forKey: Self.llmCleanupDefaultsKey) as? Bool ?? false
        llmGrammarPolishEnabled = UserDefaults.standard.object(forKey: Self.llmGrammarPolishDefaultsKey) as? Bool ?? false
        // On by default; absent key means a fresh install → enabled.
        itnEnabled = FormattingPreference.isEnabled
        // Off by default; the deterministic rules handle formatting unless opted in.
        useAppleIntelligence = AppleIntelligencePreference.isEnabled
    }

    var canStart: Bool {
        switch phase {
        case .idle, .failed:
            return preparingEngine == nil
        case .preparingModels, .recording, .stopping:
            return false
        }
    }

    var canStop: Bool {
        phase == .recording
    }

    /// Show the interactive "when should this reminder be?" quick-prompt. Highest
    /// priority band — it's the immediate, actionable consequence of the command
    /// the user just spoke, and it needs a tap. Time-bounded so it can't linger.
    var shouldShowReminderTimePrompt: Bool {
        guard let at = pendingReminderPromptAt, pendingReminderPrompt != nil else { return false }
        return Date().timeIntervalSince(at) < Self.reminderTimePromptDuration
            && phase == .idle
            && download == nil
            && preparingEngine == nil
    }

    /// Whether the surface is free to *carry* a due reminder — the display gate
    /// below minus its time window. Split out because the announcement's clock
    /// only runs while it's actually visible: a dictation started mid-window hides
    /// the band, and an alert the user never saw must not expire behind it. The
    /// AppDelegate refresh loop reads this to hold the window open.
    /// The three bands it defers to each either await a tap (the approval card,
    /// the "when?" quick-prompt) or hold something the user can't get back from
    /// anywhere else on screen (the undelivered hint's Copy button). Because the
    /// clock pauses rather than running behind them, both alerts get their turn
    /// instead of one eating the other. Nothing below them outranks a reminder
    /// the user scheduled.
    var canShowDueReminderBanner: Bool {
        phase == .idle
            && download == nil
            && preparingEngine == nil
            && approvals.pending == nil
            && !shouldShowAgentAsk
            && !shouldShowReminderTimePrompt
            && !shouldShowUndeliveredBanner
    }

    /// Show a reminder that has come due. It outranks every passive hint below —
    /// it's a scheduled alert the user set for themselves, and it replaced a
    /// system notification, so it can't be the thing that gets buried. It still
    /// yields to a pending write approval and the "when?" quick-prompt, both of
    /// which are waiting on a tap.
    var shouldShowDueReminderBanner: Bool {
        guard let at = dueReminderAt, dueReminder != nil, canShowDueReminderBanner else { return false }
        return Date().timeIntervalSince(at) < dueReminderWindow
    }

    /// How long the band holds from `dueReminderAt` — the full announcement, or the
    /// shorter undo window once the user has ticked it off. The checkbox restarts
    /// the clock, so the undo window is measured from the tick either way.
    var dueReminderWindow: TimeInterval {
        dueReminderCompleted ? Self.dueReminderAnsweredHold : Self.dueReminderBannerDuration
    }

    /// How long the day-summary band holds from `daySummaryAt`. A spoken answer gets the
    /// short tail, because the refresh loop has been pinning `daySummaryAt` to *now* for
    /// the whole utterance — so the countdown only starts when the voice stops, and what
    /// remains is the beat to finish reading it. An answer nobody spoke keeps the full
    /// silent-reading window.
    var daySummaryWindow: TimeInterval {
        daySummaryWasSpoken ? Self.spokenAnswerTailHold : Self.daySummaryDuration
    }

    /// Show the brief "note saved / reminder set" confirmation. Sits just under
    /// the quick-prompt (the two never coincide for one command).
    var shouldShowCommandConfirmation: Bool {
        guard let at = commandConfirmationAt, commandConfirmation != nil else { return false }
        return Date().timeIntervalSince(at) < commandConfirmationWindow
            && phase == .idle
            && download == nil
            && preparingEngine == nil
            && !shouldShowReminderTimePrompt
            && !shouldShowDueReminderBanner
    }

    /// Show the "what's my day" answer. High priority — the user just asked for
    /// it — but yields to the quick-prompt/command confirmation which need a tap.
    var shouldShowDaySummary: Bool {
        guard let at = daySummaryAt, activeDaySummary != nil else { return false }
        return Date().timeIntervalSince(at) < daySummaryWindow
            && phase == .idle
            && download == nil
            && preparingEngine == nil
            && !shouldShowReminderTimePrompt
            && !shouldShowCommandConfirmation
            && !shouldShowDueReminderBanner
    }

    /// Show the Bluetooth-mic hint in the notch only when idle (never mid-
    /// recording) and the user hasn't dismissed it.
    var shouldShowBluetoothBanner: Bool {
        bluetoothInputActive && !bluetoothBannerDismissed && phase == .idle
            && !shouldShowReminderTimePrompt && !shouldShowCommandConfirmation
            && !shouldShowDaySummary
            && !shouldShowDueReminderBanner
    }

    /// Show the "saved, nowhere to paste" hint when a recent dictation had no
    /// target field, the app is idle, and nothing higher-priority (download,
    /// prepare) owns the surface. Takes precedence over the Bluetooth hint and
    /// the gentle reminder — it's the immediate result of the user's action.
    var shouldShowUndeliveredBanner: Bool {
        guard let at = undeliveredTranscriptAt else { return false }
        return Date().timeIntervalSince(at) < Self.undeliveredBannerDuration
            && phase == .idle
            && download == nil
            && preparingEngine == nil
    }

    /// Show a brief "learned <word>" confirmation right after auto-learn adds a
    /// term. Same immediacy tier as the undelivered hint; sits just under it.
    var shouldShowLearnedBanner: Bool {
        guard let at = learnedTermAt, learnedTerm != nil else { return false }
        return Date().timeIntervalSince(at) < Self.learnedBannerDuration
            && phase == .idle
            && download == nil
            && preparingEngine == nil
            && !shouldShowUndeliveredBanner
            && !shouldShowDueReminderBanner
    }

    /// Show a one-shot "smart cleanup is ready" confirmation right after the
    /// model finishes downloading + warming. Same immediacy tier as the learned
    /// hint; sits just under it. (Download *progress* never touches the notch —
    /// only this completion signal does.)
    var shouldShowCleanupReadyBanner: Bool {
        guard let at = cleanupModelReadyAt else { return false }
        return Date().timeIntervalSince(at) < Self.cleanupReadyBannerDuration
            && phase == .idle
            && download == nil
            && preparingEngine == nil
            && !shouldShowUndeliveredBanner
            && !shouldShowLearnedBanner
            && !shouldShowDueReminderBanner
    }

    /// Show the success "delivered" checkmark briefly after a transcript lands
    /// at the cursor. Idle-only (the paste already returned) and yields to the
    /// higher-priority action hints above it.
    var shouldShowDeliveredBeat: Bool {
        guard let at = deliveredAt else { return false }
        return Date().timeIntervalSince(at) < Self.deliveredBeatDuration
            && phase == .idle
            && download == nil
            && preparingEngine == nil
            && !shouldShowUndeliveredBanner
            && !shouldShowDueReminderBanner
    }

    /// Whether the band should show the live dictation line (the state word + the
    /// orb — never the streaming transcript). True for the whole working stretch —
    /// recording, finalizing, and the polish that runs on after the paste.
    var shouldShowLiveTranscript: Bool {
        guard download == nil else { return false }
        if isPolishing { return true }
        switch phase {
        case .recording, .stopping: return true
        case .idle, .preparingModels, .failed: return false
        }
    }

    /// Show the polished transcript for a beat once the on-device pass rewrote
    /// the dictation. Idle-only, and it yields to the undelivered hint — which
    /// shows the same (polished) text with a Copy button, so the two would be
    /// redundant.
    var shouldShowPolishedBeat: Bool {
        guard let at = polishedAt, polishedText != nil else { return false }
        return Date().timeIntervalSince(at) < Self.polishedBeatDuration
            && phase == .idle
            && !isPolishing
            && download == nil
            && preparingEngine == nil
            && !shouldShowUndeliveredBanner
            && !shouldShowDueReminderBanner
    }

    /// Show a gentle reminder in the notch only when one is queued, the app is
    /// idle, and nothing higher-priority (download, prepare, Bluetooth hint,
    /// undelivered/learned hints) is occupying the surface.
    var shouldShowReminder: Bool {
        activeReminder != nil
            && phase == .idle
            && download == nil
            && preparingEngine == nil
            && !shouldShowBluetoothBanner
            && !shouldShowUndeliveredBanner
            && !shouldShowLearnedBanner
            && !shouldShowCleanupReadyBanner
            && !shouldShowDaySummary
            && !shouldShowDueReminderBanner
    }

    /// Whether the notch surface is carrying something of its own right now — a
    /// dictation state, a download, a banner, or one of the brief beats.
    ///
    /// The hover quick-actions panel reads this to stay out of the way: it and the
    /// dictation surface both anchor to the notch, and two panels claiming the same
    /// physical strip would draw over each other. Deliberately generous — when in
    /// doubt the *dictation* surface wins, because it's the one reporting something
    /// the user is doing right now.
    var notchIsOccupied: Bool {
        if phase != .idle { return true }
        if download != nil || preparingEngine != nil { return true }
        if approvals.pending != nil { return true }
        if shouldShowAgentAsk || shouldShowAgentGlance || shouldShowAgentWorking { return true }
        return shouldShowReminderTimePrompt
            || shouldShowDueReminderBanner
            || shouldShowCommandConfirmation
            || shouldShowDaySummary
            || shouldShowBluetoothBanner
            || shouldShowUndeliveredBanner
            || shouldShowLearnedBanner
            || shouldShowCleanupReadyBanner
            || shouldShowReminder
            || shouldShowDeliveredBeat
            || shouldShowLiveTranscript
            || shouldShowPolishedBeat
    }

    func resetTranscript() {
        transcript = TranscriptSnapshot()
    }

    /// Prepend a new transcript to history, returning its id so a later
    /// background refinement can update the same entry (or `nil` if the text was
    /// empty and nothing was stored).
    @discardableResult
    func appendHistory(text: String, engine: TranscriberEngine) -> UUID? {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        let entry = TranscriptHistoryEntry(text: cleaned, engineRawValue: engine.rawValue)
        var next = history
        next.insert(entry, at: 0)
        if next.count > Self.historyLimit {
            next.removeLast(next.count - Self.historyLimit)
        }
        history = next
        Self.persistHistory(next)
        return entry.id
    }

    /// Replace the text of an existing history entry in place (keeping its id,
    /// timestamp and engine) — used when the on-device polish lands after the
    /// entry was already saved. No-op if the id is gone or the text is unchanged.
    func updateHistoryText(_ id: UUID, to text: String) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty,
              let idx = history.firstIndex(where: { $0.id == id }),
              history[idx].text != cleaned
        else { return }
        let old = history[idx]
        var next = history
        next[idx] = TranscriptHistoryEntry(
            id: old.id, text: cleaned, createdAt: old.createdAt, engineRawValue: old.engineRawValue)
        history = next
        Self.persistHistory(next)
    }

    func clearHistory() {
        history = []
        Self.persistHistory([])
    }

    /// Record an answer so it survives its banner. The only entry point — bypassing it
    /// skips the cap and the persistence, exactly like `appendHistory`.
    func appendAnswer(
        question: String,
        answer: String,
        provenance: String = "",
        source: AnsweredQuestion.Source = .spoken
    ) {
        let trimmedAnswer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAnswer.isEmpty else { return }
        let entry = AnsweredQuestion(
            question: question.trimmingCharacters(in: .whitespacesAndNewlines),
            answer: trimmedAnswer,
            provenance: provenance,
            source: source)
        answerLog = AnswerLog.appending(entry, to: answerLog)
        AnswerLog.persist(answerLog)
    }

    func clearAnswerLog() {
        answerLog = []
        AnswerLog.persist([])
    }

    func removeHistoryEntry(_ id: UUID) {
        history.removeAll { $0.id == id }
        Self.persistHistory(history)
    }

    private static func loadHistory() -> [TranscriptHistoryEntry] {
        guard let data = UserDefaults.standard.data(forKey: historyDefaultsKey) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([TranscriptHistoryEntry].self, from: data)) ?? []
    }

    private static func persistHistory(_ entries: [TranscriptHistoryEntry]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: historyDefaultsKey)
    }

    /// Fold a learned correction into the glossary: extend the canonical
    /// term's alias list if it already exists, otherwise add a new
    /// "canonical: heard" line. No-op when the pair is already covered.
    func learnVocabularyCorrection(canonical: String, heard: String) {
        let canonicalLower = canonical.lowercased()
        let heardLower = heard.lowercased()
        guard canonicalLower != heardLower else { return }

        var lines = customVocabulary
        for (index, line) in lines.enumerated() {
            guard let parsed = VocabularyTermParser.parse(line),
                  parsed.text.lowercased() == canonicalLower
            else { continue }
            let known = [parsed.text.lowercased()] + parsed.aliases.map { $0.lowercased() }
            guard !known.contains(heardLower) else { return }
            lines[index] = "\(parsed.text): \((parsed.aliases + [heard]).joined(separator: ", "))"
            customVocabulary = lines
            return
        }
        lines.append("\(canonical): \(heard)")
        customVocabulary = lines
    }

    private static func loadVocabulary() -> [String] {
        UserDefaults.standard.stringArray(forKey: vocabularyDefaultsKey) ?? []
    }

    private static func persistVocabulary(_ terms: [String]) {
        UserDefaults.standard.set(terms, forKey: vocabularyDefaultsKey)
    }

}
