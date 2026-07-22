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
    static let remindersEnabledDefaultsKey = "WhisperMaster.remindersEnabled.v1"
    static let keepAwakeForRemoteDefaultsKey = "WhisperMaster.keepAwakeForRemote.v1"
    static let analyticsEnabledDefaultsKey = "WhisperMaster.analyticsEnabled.v1"
    static let usageSyncEnabledDefaultsKey = "WhisperMaster.usageSyncEnabled.v1"
    static let notesSyncEnabledDefaultsKey = "WhisperMaster.notesSyncEnabled.v1"
    static let voiceCommandsEnabledDefaultsKey = "WhisperMaster.voiceCommands.v1"
    static let reminderDefaultAlertStyleDefaultsKey = "WhisperMaster.reminderDefaultAlertStyle.v1"
    static let reminderDefaultSoundDefaultsKey = "WhisperMaster.reminderDefaultSound.v1"
    static let removeFillerWordsDefaultsKey = "WhisperMaster.removeFillerWords.v1"
    static let learnCorrectionsDefaultsKey = "WhisperMaster.learnCorrections.v1"
    static let llmCleanupDefaultsKey = "WhisperMaster.llmCleanup.v1"
    static let llmGrammarPolishDefaultsKey = "WhisperMaster.llmGrammarPolish.v1"
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
    /// after a voice command lands in Notes & Reminders.
    static let commandConfirmationDuration: TimeInterval = 4
    /// How long the interactive "when should this reminder be?" prompt stays down
    /// awaiting a tap. Generous, but bounded — if the user walks away it retracts
    /// (and no reminder is created, since none of the times were chosen).
    static let reminderTimePromptDuration: TimeInterval = 30
    /// How long a "what's my day" answer stays down in the notch. Longer than the
    /// other hints — the user asked for it and is reading a few facts.
    static let daySummaryDuration: TimeInterval = 12

    var selectedEngine: TranscriberEngine = .slidingWindow
    var preparedEngine: TranscriberEngine?
    var preparingEngine: TranscriberEngine?
    var hotkey: HotkeyManager.HotkeyOption = .rightOption
    /// Push-to-talk key that always means "ask about my day" — the finished
    /// transcript is routed to the connectors and answered in the notch instead of
    /// being pasted. Defaults to a different key than `hotkey`.
    var dayQueryHotkey: HotkeyManager.HotkeyOption = .rightCommand
    var holdToTalkEnabled: Bool = true
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
    /// A spoken reminder that named no time — surfaced as an interactive notch
    /// quick-prompt ("when?"). Transient; set by the view model when a reminder
    /// command lands without a time, cleared once the user picks or it expires.
    var pendingReminderPrompt: PendingReminderPrompt?
    var pendingReminderPromptAt: Date?
    /// A brief "note saved" / "reminder set" line shown in the notch right after a
    /// voice command routes into Notes & Reminders (the paste is suppressed, so
    /// this is the only feedback). Transient; auto-expired by the refresh loop.
    var commandConfirmation: String?
    var commandConfirmationAt: Date?
    /// The answer to a "what's my day" query, dropped down in the notch. Set by the
    /// view model after aggregating the connectors; transient (never persisted),
    /// auto-expired by the refresh loop after `daySummaryDuration`.
    var activeDaySummary: DaySummary?
    var daySummaryAt: Date?
    /// A one-shot request to open the Settings window on a given section — set by
    /// the tappable command-confirmation banner ("tap to change") so a spoken
    /// reminder's default time is one click from adjustable. Transient; consumed
    /// (and cleared) by `SettingsView` the moment it flips.
    var requestedSettingsSection: SettingsSection?
    /// When the last dictation finished with no focused text field to paste
    /// into — so it was saved to history and surfaced as a notch hint instead.
    /// Transient (never persisted); set by the view model, auto-expired by the
    /// AppDelegate refresh loop once `undeliveredBannerDuration` has passed.
    var undeliveredTranscriptAt: Date?
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
    /// Persisted; **opt-in** — off until the user turns it on in Settings.
    var remindersEnabled: Bool = false {
        didSet { UserDefaults.standard.set(remindersEnabled, forKey: Self.remindersEnabledDefaultsKey) }
    }
    /// Keep this Mac awake so the phone can reach it for remote dictation even
    /// after it's been sitting locked and idle. Persisted; **opt-in** — off by
    /// default because it prevents idle sleep entirely (a battery cost). When off,
    /// an in-progress remote session still holds the Mac awake on its own.
    var keepAwakeForRemote: Bool = false {
        didSet { UserDefaults.standard.set(keepAwakeForRemote, forKey: Self.keepAwakeForRemoteDefaultsKey) }
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
    /// Share anonymous usage analytics (PostHog). **On by default —
    /// opt-out.** Safe to default on because the data carries no PII: never
    /// transcripts, only app version, OS, and coarse feature counts. Users can
    /// switch it off in Settings → About. Toggling starts/stops the SDK live.
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
    /// Route spoken commands ("remind me to…", "add a note…") into Notes &
    /// Reminders instead of pasting them. A cheap keyword gate means ordinary
    /// dictation is untouched; when the on-device model is loaded it makes the
    /// final call (and can veto a false positive). Persisted; **opt-in** — off
    /// until the user turns it on, since it changes what happens to a phrase that
    /// merely starts with "remind me".
    var voiceCommandsEnabled: Bool = false {
        didSet { UserDefaults.standard.set(voiceCommandsEnabled, forKey: Self.voiceCommandsEnabledDefaultsKey) }
    }
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

    /// The user's connector choices (Gmail, Google Calendar, Outlook, Slack, iCal,
    /// …) behind the Connectors tab. Device-wide (see `ConnectorStore`).
    let connectorStore = ConnectorStore()

    init() {
        history = Self.loadHistory()
        customVocabulary = Self.loadVocabulary()
        // Opt-in: off until the user has explicitly turned it on.
        remindersEnabled = UserDefaults.standard.object(forKey: Self.remindersEnabledDefaultsKey) as? Bool ?? false
        // Opt-in: off until the user has explicitly turned it on.
        keepAwakeForRemote = UserDefaults.standard.object(forKey: Self.keepAwakeForRemoteDefaultsKey) as? Bool ?? false
        // Opt-out: on unless the user has explicitly turned it off.
        analyticsEnabled = UserDefaults.standard.object(forKey: Self.analyticsEnabledDefaultsKey) as? Bool ?? true
        // Opt-out: on unless the user has explicitly turned it off.
        usageSyncEnabled = UserDefaults.standard.object(forKey: Self.usageSyncEnabledDefaultsKey) as? Bool ?? true
        // Opt-out: on unless the user has explicitly turned it off.
        notesSyncEnabled = UserDefaults.standard.object(forKey: Self.notesSyncEnabledDefaultsKey) as? Bool ?? true
        // Opt-in: off until the user has explicitly turned it on.
        voiceCommandsEnabled = UserDefaults.standard.object(forKey: Self.voiceCommandsEnabledDefaultsKey) as? Bool ?? false
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

    /// Show the brief "note saved / reminder set" confirmation. Sits just under
    /// the quick-prompt (the two never coincide for one command).
    var shouldShowCommandConfirmation: Bool {
        guard let at = commandConfirmationAt, commandConfirmation != nil else { return false }
        return Date().timeIntervalSince(at) < Self.commandConfirmationDuration
            && phase == .idle
            && download == nil
            && preparingEngine == nil
            && !shouldShowReminderTimePrompt
    }

    /// Show the "what's my day" answer. High priority — the user just asked for
    /// it — but yields to the quick-prompt/command confirmation which need a tap.
    var shouldShowDaySummary: Bool {
        guard let at = daySummaryAt, activeDaySummary != nil else { return false }
        return Date().timeIntervalSince(at) < Self.daySummaryDuration
            && phase == .idle
            && download == nil
            && preparingEngine == nil
            && !shouldShowReminderTimePrompt
            && !shouldShowCommandConfirmation
    }

    /// Show the Bluetooth-mic hint in the notch only when idle (never mid-
    /// recording) and the user hasn't dismissed it.
    var shouldShowBluetoothBanner: Bool {
        bluetoothInputActive && !bluetoothBannerDismissed && phase == .idle
            && !shouldShowReminderTimePrompt && !shouldShowCommandConfirmation
            && !shouldShowDaySummary
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
