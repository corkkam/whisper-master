import AppKit
import XCTest

@testable import WhisperMaster

/// Owner decision D2, 2026-11-27: a user can dictate before sign-in, and sign-in is
/// still required for sync, the assistant and the beta track. These tests pin each
/// side of that line, so a change that re-gates dictation, or opens one of the three
/// to a signed-out person, fails here.
///
/// The decision lives in `AccountFeature`. `AppDelegate` asks it (through
/// `ensureCanDictate` / `ensureCanUseAssistant` and the `enabled:` of both sync
/// calls), and `BetaAccess` asks it for the update channels, so the table is what
/// the app obeys. The sync clients and the view model are tested where they act.
@MainActor
final class AccountGateTests: XCTestCase {

    // MARK: - The table

    func testDictationIsAllowedWhileSignedOut() {
        XCTAssertFalse(AccountFeature.dictation.needsAccount)
        XCTAssertTrue(AccountFeature.dictation.isAllowed(signedIn: false))
        XCTAssertTrue(AccountFeature.dictation.isAllowed(signedIn: true))
    }

    func testSyncTheAssistantAndTheBetaTrackAreRefusedWhileSignedOut() {
        for feature in [AccountFeature.sync, .assistant, .betaUpdates] {
            XCTAssertTrue(feature.needsAccount, "\(feature) is behind an account")
            XCTAssertFalse(feature.isAllowed(signedIn: false), "\(feature) must refuse a signed-out user")
            XCTAssertTrue(feature.isAllowed(signedIn: true), "\(feature) opens with a session")
        }
    }

    /// A new case is behind an account until someone decides otherwise on purpose:
    /// only dictation is open, so adding a case without reading this table cannot
    /// open it to a signed-out user by accident.
    func testDictationIsTheOnlyFeatureOpenWithoutAnAccount() {
        let open = AccountFeature.allCases.filter { $0.isAllowed(signedIn: false) }
        XCTAssertEqual(open, [.dictation])
    }

    // MARK: - The beta track

    func testBetaChannelsAreEmptyWhileSignedOutWhateverTheFlagSays() {
        XCTAssertEqual(BetaAccess.allowedChannels(signedIn: false, betaFlag: true), [])
        XCTAssertEqual(BetaAccess.allowedChannels(signedIn: false, betaFlag: false), [])
    }

    /// An empty set is "stable only" to Sparkle, so it must be the signed-out answer
    /// and not a missing one.
    func testASignedInBetaUserStillGetsTheBetaChannel() {
        XCTAssertEqual(BetaAccess.allowedChannels(signedIn: true, betaFlag: true), ["beta"])
        XCTAssertEqual(BetaAccess.allowedChannels(signedIn: true, betaFlag: false), [])
    }

    // MARK: - Sync sends nothing without a session

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
    }

    private func countingSession() -> URLSession {
        CapturingURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CapturingURLProtocol.self]
        return URLSession(configuration: config)
    }

    /// No identity is what the App layer returns with no session
    /// (`currentUsageIdentity`). Rollups exist and are dirty, and nothing leaves.
    func testUsageSyncSendsNothingWithNoSession() async {
        let store = UsageStore(fileURL: tempURL(), load: false)
        store.record(DictationRecord(
            timestamp: Date(), wordCount: 5, durationSeconds: 5,
            appName: "Notes", appBundleID: "com.apple.Notes",
            engineRawValue: "slidingWindow", fixes: .zero))
        XCTAssertFalse(store.dirtyDays.isEmpty, "there is something to send")

        let client = UsageSyncClient(
            store: store, identity: { nil },
            endpoint: URL(string: "https://usage.invalid/api/usage"), session: countingSession())
        await client.push(days: store.dirtyDays)

        XCTAssertEqual(CapturingURLProtocol.requestCount(), 0, "usage must not be sent without a session")
        XCTAssertFalse(store.dirtyDays.isEmpty, "the day stays dirty for the sign-in that comes later")
    }

    func testNotesSyncSendsNothingWithNoSession() async {
        let store = NotesStore(fileURL: tempURL(), load: false)
        store.upsertNote(Note(title: "kept on this Mac"))
        XCTAssertFalse(store.dirtyIDs.isEmpty)

        let client = NotesSyncClient(
            store: store, identity: { nil },
            endpoint: URL(string: "https://notes.invalid/api/notes"), session: countingSession())
        await client.push(ids: store.dirtyIDs)
        await client.pull(expectedUserID: "user_a")

        XCTAssertEqual(CapturingURLProtocol.requestCount(), 0, "notes must be neither pushed nor pulled without a session")
    }

    /// The call `AppDelegate` makes on every tick passes `AccountFeature.sync`'s answer
    /// as `enabled:`. With changes waiting, a signed-out answer starts no push and a
    /// signed-in one does, so the flag is what holds the tick back, not an empty store.
    func testTheTickStartsNoSyncWhileSignedOut() {
        let usageStore = UsageStore(fileURL: tempURL(), load: false)
        usageStore.record(DictationRecord(
            timestamp: Date(), wordCount: 5, durationSeconds: 5,
            appName: "Notes", appBundleID: "com.apple.Notes",
            engineRawValue: "slidingWindow", fixes: .zero))
        let usage = UsageSyncClient(
            store: usageStore, identity: { nil },
            endpoint: URL(string: "https://usage.invalid/api/usage"), session: countingSession())
        let notesStore = NotesStore(fileURL: tempURL(), load: false)
        notesStore.upsertNote(Note(title: "waiting"))
        let notes = NotesSyncClient(
            store: notesStore, identity: { nil },
            endpoint: URL(string: "https://notes.invalid/api/notes"), session: countingSession())

        let signedOut = AccountFeature.sync.isAllowed(signedIn: false)
        XCTAssertFalse(usage.syncIfNeeded(enabled: signedOut))
        XCTAssertFalse(notes.syncIfNeeded(enabled: signedOut))
        XCTAssertFalse(notes.pullIfNeeded(enabled: signedOut))

        let signedIn = AccountFeature.sync.isAllowed(signedIn: true)
        XCTAssertTrue(usage.syncIfNeeded(enabled: signedIn), "control: the same store does start a push when allowed")
        XCTAssertTrue(notes.syncIfNeeded(enabled: signedIn))
    }

    // MARK: - The assistant chord while signed out

    /// fn is usually down first, so a push-to-talk recording is already running when
    /// control joins. Its words are held, never typed.
    func testTheChordWithADictationRunningHoldsItsWords() {
        let viewModel = DictationViewModel()
        viewModel.state.phase = .recording

        viewModel.refuseForSignIn("Sign in to use the assistant")

        XCTAssertTrue(viewModel.holdWordsForSignIn, "the running session's words are held at the stop")
        XCTAssertFalse(viewModel.state.commandCaptureArmed, "the assistant is not armed: nothing may run")
        XCTAssertEqual(viewModel.state.commandConfirmation, "Sign in to use the assistant")
    }

    /// With nothing running there are no words: the prompt is the whole answer, and
    /// nothing is armed or started.
    func testTheChordWithNothingRunningOnlyShowsThePrompt() {
        let viewModel = DictationViewModel()

        viewModel.refuseForSignIn("Sign in to use the assistant")

        XCTAssertFalse(viewModel.holdWordsForSignIn)
        XCTAssertFalse(viewModel.state.commandCaptureArmed)
        XCTAssertEqual(viewModel.state.phase, .idle, "a refused chord starts no recording")
        XCTAssertEqual(viewModel.state.commandConfirmation, "Sign in to use the assistant")
        XCTAssertTrue(viewModel.state.commandConfirmationDetail.contains("sign in"))
        XCTAssertNil(viewModel.state.undeliveredText)
    }

    /// The words of a refused capture are neither typed nor dropped: they are on the
    /// clipboard and in the history, and the band says so. The clipboard is saved
    /// and put back, so the test does not leave its own words in the developer's.
    func testHeldWordsAreKeptNotTypedNorDropped() {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let saved { pasteboard.setString(saved, forType: .string) }
        }
        let viewModel = DictationViewModel()
        let words = "remind me to call the dentist tomorrow \(UUID())"
        let spoken = DictationViewModel.SpokenCapture(heard: words, asked: words, stages: [])

        let suppressPaste = viewModel.holdWordsUntilSignedIn(words, spoken: spoken)

        XCTAssertTrue(suppressPaste, "the words must not be typed into the app in front")
        XCTAssertEqual(pasteboard.string(forType: .string), words, "the words are on the clipboard")
        XCTAssertEqual(viewModel.state.history.first?.text, words, "and in the history, for Paste Last Transcript")
        XCTAssertEqual(viewModel.state.commandConfirmation, "Sign in to use the assistant")
        XCTAssertTrue(viewModel.state.commandConfirmationDetail.contains("copied"))
    }

    func testTheAccountMirrorForTheViewsFollowsTheSession() {
        let viewModel = DictationViewModel()
        XCTAssertFalse(viewModel.state.accountSignedIn, "a launch with no session yet is signed out")
        viewModel.setAccountSignedIn(true)
        XCTAssertTrue(viewModel.state.accountSignedIn)
        viewModel.setAccountSignedIn(false)
        XCTAssertFalse(viewModel.state.accountSignedIn)
    }

    // MARK: - Setup and the pages made of an account

    /// Setup needs no account, so a signed-out person finishes it once and is not
    /// shown it at every launch. The scope cannot be a Clerk user id.
    func testSignedOutSetupIsRememberedUnderItsOwnScope() {
        let key = "WhisperMaster.onboardingSeenSteps.v1"
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.removeObject(forKey: key)
        let scope = OnboardingProgress.signedOutScope

        XCTAssertFalse(scope.hasPrefix("user_"), "Clerk ids start with user_, so this scope cannot collide")
        XCTAssertFalse(OnboardingProgress.isComplete(userID: scope))
        OnboardingProgress.markSeen(OnboardingStep.allCases.map(\.id), userID: scope)
        XCTAssertTrue(OnboardingProgress.isComplete(userID: scope))
        XCTAssertEqual(
            OnboardingLaunchDecision.resolve(
                userID: scope, micGranted: true, accessibilityGranted: true, signOutInFlight: false),
            .skip)
    }

    func testOnlyThePagesMadeOfAnAccountNeedOne() {
        for section in [SettingsSection.notes, .connectors, .insights] {
            XCTAssertTrue(section.requiresAccount, "\(section) is made of the account's own data")
        }
        for section in [SettingsSection.today, .settings, .engine, .permissions, .about, .traces, .agents, .coding] {
            XCTAssertFalse(section.requiresAccount, "\(section) opens with no account")
        }
    }

    // MARK: - The launch waits for Clerk, but not for ever

    func testTheLaunchWaitsForTheSessionThenStopsWaiting() {
        XCTAssertFalse(SessionResolution.isResolved(sessionLoaded: false, secondsSinceLaunch: 0.5))
        XCTAssertTrue(SessionResolution.isResolved(sessionLoaded: true, secondsSinceLaunch: 0.5))
        XCTAssertTrue(
            SessionResolution.isResolved(sessionLoaded: false, secondsSinceLaunch: SessionResolution.grace),
            "offline, Clerk may never answer, and dictation must not wait on it")
    }
}
