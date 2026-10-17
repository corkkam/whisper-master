import AppKit
import Foundation
import Observation

/// Meeting notes end to end: notice a call, offer to take notes, record, and
/// file a note with the summary, the local transcript and the recording.
///
/// Lives on `AppState` (`state.meetings`) like `agents` and `now`, and starts
/// dormant: `start(state:)` runs post-auth, so `swift test` and the snapshot
/// renderer never poll Core Audio. The notch reads `prompt` and `readyNote`;
/// the live window reads `session`.
@MainActor
@Observable
final class MeetingController {
    /// A call that was just detected and that we are offering to take notes for.
    private(set) var prompt: DetectedCall?
    private(set) var promptAt: Date?
    /// The meeting being recorded, if any.
    private(set) var session: MeetingSession?
    /// True while the notes pass runs after a meeting ends.
    private(set) var isWritingNotes = false
    /// The note filed for the last meeting, announced once on the notch.
    private(set) var readyNoteTitle: String?
    private(set) var readyAt: Date?
    /// Why the last start failed, shown in the live window and Settings.
    private(set) var lastError: String?

    /// How long the "meeting detected" banner stays down if it is not answered.
    static let promptDuration: TimeInterval = 20
    static let readyDuration: TimeInterval = 8
    static let pollInterval: TimeInterval = 2

    @ObservationIgnored private weak var state: AppState?
    @ObservationIgnored private var detector = CallDetector()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var polling = false
    @ObservationIgnored private lazy var window = MeetingLiveWindow(controller: self)

    var isRecording: Bool { session != nil }

    var showsPrompt: Bool {
        guard let promptAt, prompt != nil, session == nil else { return false }
        return Date().timeIntervalSince(promptAt) < Self.promptDuration
    }

    var showsReady: Bool {
        guard let readyAt, readyNoteTitle != nil else { return false }
        return Date().timeIntervalSince(readyAt) < Self.readyDuration
    }

    // MARK: - Lifecycle

    func start(state: AppState) {
        guard FeatureFlags.meetingNotesAvailable, timer == nil else { return }
        self.state = state
        // A quit or a crash mid-meeting leaves both sides of the call in the
        // temporary folder; nothing else would ever remove them.
        Task.detached(priority: .utility) { MeetingAudioRecorder.removeLeftovers() }
        let timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let session {
            self.session = nil
            Task { await session.cancel() }
        }
    }

    /// The app is quitting. There is no time left to mix or transcribe, so the
    /// recording is dropped rather than left in the temporary folder.
    func discardForTermination() {
        timer?.invalidate()
        timer = nil
        session?.discardForTermination()
        session = nil
    }

    /// Keep the banners' clocks still while something else holds the notch, so
    /// they count only time on screen — the `dueReminderAt` shape. An offer that
    /// ran out behind a dictation was never made. Called from the refresh tick.
    /// Only a window still running is held: `prompt` and `readyNoteTitle` outlive
    /// their windows, and holding those would bring an old banner back.
    func holdBannerClocks(now: Date = Date()) {
        if showsPrompt { promptAt = now }
        if showsReady { readyAt = now }
    }

    // MARK: - Detection

    private func poll() {
        guard let state, !polling else { return }
        // Off: still watch an active recording so it can stop by itself, but
        // offer nothing new.
        guard state.meetingDetectionEnabled || session != nil else { return }
        polling = true
        let calendarTitle = Self.calendarMeetingTitle(in: state.now.events, at: Date())
        Task.detached(priority: .utility) { [weak self] in
            let evidence = Self.gatherEvidence(calendarTitle: calendarTitle)
            await self?.apply(evidence)
        }
    }

    nonisolated private static func gatherEvidence(calendarTitle: String?) -> CallEvidence {
        let ids = AudioOutputActivity.runningInputBundleIDs()
        var titles: [String: [String]] = [:]
        for id in ids where MeetingAppCatalog.isBrowser(id) {
            guard let family = MeetingAppCatalog.family(of: id), titles[family] == nil else { continue }
            titles[family] = BrowserMeetingProbe.windowTitles(family: family)
        }
        // A second process-list read, paid only when an app that records voice
        // messages is on the mic and the detector needs to tell the two apart.
        let needsOutput = ids.contains {
            MeetingAppCatalog.family(of: $0).map(MeetingAppCatalog.voiceMessageApps.contains) ?? false
        }
        return CallEvidence(
            micBundleIDs: ids, browserTitles: titles, calendarTitle: calendarTitle,
            outputBundleIDs: needsOutput ? AudioOutputActivity.runningOutputBundleIDs() : [])
    }

    private func apply(_ evidence: CallEvidence) {
        polling = false
        guard let state else { return }
        let ignored = Set(state.meetingIgnoredApps)
        switch detector.update(evidence, ignoring: ignored, now: Date()) {
        case .started(let call):
            guard session == nil, state.meetingDetectionEnabled else { return }
            Log.meetings.notice("call detected: \(call.name, privacy: .public)")
            prompt = call
            promptAt = Date()
        case .ended:
            prompt = nil
            promptAt = nil
            // Only a meeting that started from detection ends from detection. One
            // started by hand runs until the user stops it.
            if let session, !session.call.bundleFamily.isEmpty {
                stopNotes()
            }
        case nil:
            break
        }
    }

    /// The calendar event happening now, latest-started first — a standup inside
    /// a long focus block is the one you are in.
    nonisolated static func calendarMeetingTitle(in events: [DayEvent], at now: Date) -> String? {
        events
            .filter { !$0.isAllDay && $0.start <= now && $0.end > now }
            .max { $0.start < $1.start }?
            .title
    }

    // MARK: - Actions (notch banner, tray, live window)

    func dismissPrompt() {
        prompt = nil
        promptAt = nil
    }

    /// "Never for Slack": the family is stored and never offered again.
    func ignorePromptApp() {
        guard let family = prompt?.bundleFamily, !family.isEmpty, let state else { return }
        if !state.meetingIgnoredApps.contains(family) {
            state.meetingIgnoredApps.append(family)
        }
        dismissPrompt()
    }

    /// Start taking notes for the detected call, or for an unnamed meeting when
    /// started by hand.
    func takeNotes() {
        guard session == nil, let state else { return }
        let call = prompt ?? DetectedCall(
            name: "Meeting", bundleFamily: "",
            calendarTitle: Self.calendarMeetingTitle(in: state.now.events, at: Date()))
        dismissPrompt()
        lastError = nil
        let session = MeetingSession(call: call)
        self.session = session
        window.show()
        Task {
            do {
                try await session.start()
            } catch {
                Log.meetings.error("meeting start failed: \(error.localizedDescription, privacy: .public)")
                // Stopped while it was still starting: the user already has their
                // answer, and `stop` owns the teardown (`cancel` is a no-op then).
                if self.session === session {
                    lastError = error.localizedDescription
                    self.session = nil
                }
                await session.cancel()
            }
        }
    }

    func stopNotes() {
        guard let session, let state else { return }
        self.session = nil
        isWritingNotes = true
        let store = state.notesStore
        let noteID = UUID()
        let title = Self.noteTitle(for: session.call, startedAt: session.startedAt)
        Task {
            let (transcript, audio) = await session.stop(noteID: noteID)
            let ownNotes = session.ownNotes
            guard !transcript.isEmpty || audio != nil || !ownNotes.isEmpty else {
                isWritingNotes = false
                lastError = "Nothing was recorded."
                return
            }
            // File the note first, so a crash during the notes pass loses nothing.
            let hasModel = CleanupModel.General.isInstalled
            var note = Note(
                id: noteID, title: title,
                body: Self.placeholderBody(hasModel: hasModel, transcriptEmpty: transcript.isEmpty, ownNotes: ownNotes),
                transcript: transcript.isEmpty ? nil : transcript,
                audio: audio)
            store.upsertNote(note)

            if hasModel, !transcript.isEmpty {
                await MlxCleanupService.prepareGeneralIfInstalled()
                if let body = await MeetingNotesGenerator.live.finalNotes(
                    transcript: transcript, ownNotes: ownNotes) {
                    note.body = body
                    note.updatedAt = Date()
                    store.upsertNote(note)
                }
            }
            isWritingNotes = false
            readyNoteTitle = title
            readyAt = Date()
        }
    }

    func showLiveWindow() {
        window.show()
    }

    // MARK: - Snapshot seeding

    /// Fixed states for the PNG renderer. Nothing is polled or recorded.
    func seedPromptForSnapshot(_ call: DetectedCall) {
        prompt = call
        promptAt = Date()
    }

    func seedReadyForSnapshot(title: String) {
        readyNoteTitle = title
        readyAt = Date()
    }

    func seedSessionForSnapshot(_ session: MeetingSession) {
        self.session = session
    }

    // MARK: - Copy

    nonisolated static func noteTitle(for call: DetectedCall, startedAt: Date) -> String {
        if let calendar = call.calendarTitle, !calendar.isEmpty { return calendar }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm a"
        return "\(call.name) \(formatter.string(from: startedAt))"
    }

    nonisolated static func placeholderBody(hasModel: Bool, transcriptEmpty: Bool, ownNotes: String) -> String {
        let status: String
        if transcriptEmpty {
            status = "No speech was transcribed. The recording is saved."
        } else if hasModel {
            status = "Writing notes..."
        } else {
            status = "Transcript and recording saved. Install the assistant model in Settings to get meeting notes."
        }
        return MeetingNotesGenerator.appendingOwnNotes(status, ownNotes)
    }
}
