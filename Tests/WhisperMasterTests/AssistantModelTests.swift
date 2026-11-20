import XCTest

@testable import WhisperMaster

/// The assistant model is a **separate** model with a **separate** readiness, and
/// a 2 GB download that must never start on its own. Both halves are locked here.
@MainActor
final class AssistantModelTests: XCTestCase {

    // MARK: - When the fetch may start

    func testAChordPressFetchesTheModelWhenTheAssistantIsOnAndItIsMissing() {
        XCTAssertTrue(AssistantModelManager.Policy.shouldFetchOnFirstUse(
            assistantEnabled: true, alreadyInstalled: false,
            alreadyStarted: false, previouslyFailed: false))
    }

    /// The toggle is the permission. Someone who turned the assistant off does not
    /// get 2 GB downloaded because they pressed the chord.
    func testTheToggleBeingOffStopsTheFetchHoweverOftenTheChordIsUsed() {
        for _ in 0..<3 {
            XCTAssertFalse(AssistantModelManager.Policy.shouldFetchOnFirstUse(
                assistantEnabled: false, alreadyInstalled: false,
                alreadyStarted: false, previouslyFailed: false))
        }
    }

    func testAnInstalledModelIsNotFetchedAgain() {
        XCTAssertFalse(AssistantModelManager.Policy.shouldFetchOnFirstUse(
            assistantEnabled: true, alreadyInstalled: true,
            alreadyStarted: false, previouslyFailed: false))
    }

    /// Using the chord repeatedly while the download runs must not queue a second
    /// transfer of the same 2 GB.
    func testASecondChordPressDuringTheDownloadStartsNothing() {
        XCTAssertFalse(AssistantModelManager.Policy.shouldFetchOnFirstUse(
            assistantEnabled: true, alreadyInstalled: false,
            alreadyStarted: true, previouslyFailed: false))
    }

    /// A bad network must not mean re-attempting 2 GB on every spoken command.
    /// The retry lives in Settings, where the user asks for it.
    func testAFailedFetchIsNotRetriedFromTheChord() {
        XCTAssertFalse(AssistantModelManager.Policy.shouldFetchOnFirstUse(
            assistantEnabled: true, alreadyInstalled: false,
            alreadyStarted: false, previouslyFailed: true))
    }

    // MARK: - Two models, two readiness flags

    /// The regression this whole change exists to prevent: cleanup readiness was
    /// read as assistant readiness, so Settings claimed the assistant model was on
    /// the Mac as soon as the (unrelated, much smaller) cleanup model loaded.
    func testCleanupReadinessSaysNothingAboutTheAssistantModel() {
        let state = AppState()
        state.cleanupModelReady = true
        XCTAssertFalse(state.assistantModelReady,
                       "cleanup is S1-mini; the assistant is a different model entirely")
    }

    func testNothingRequestsTheDownloadUntilSomethingAsks() {
        let state = AppState()
        XCTAssertFalse(state.assistantModelDownloadRequested)
        XCTAssertNil(state.assistantModelDownload)
        XCTAssertFalse(state.assistantModelReady)
        XCTAssertFalse(state.assistantModelFailed)
    }

    /// The archive the manager asks the mirror for has to be the one that is
    /// actually pinned, or the installer refuses it.
    func testTheAssistantArchiveIsChecksumPinned() {
        XCTAssertNotNil(ModelChecksums.sha256[CleanupModel.General.archiveName])
    }

    /// Same obligation for the cleanup model — this pin was missing, which is how
    /// the S1-mini archive came to be published to a host the app never reads.
    func testTheCleanupArchiveIsChecksumPinned() {
        XCTAssertNotNil(ModelChecksums.sha256[CleanupModel.archiveName])
    }

    // MARK: - Which assistant loads

    private typealias General = CleanupModel.General

    func testTheShippedModelFromTheMirrorWinsOverEverythingElse() {
        let everything: Set<URL> = [General.shippedDirectory, General.hubCacheDirectory,
                                    General.previousDirectory]
        XCTAssertEqual(General.resolveInstalledDirectory { everything.contains($0) },
                       General.shippedDirectory)
    }

    func testTheHuggingFaceCopyOfTheShippedModelBeatsThePreviousModel() {
        let onDisk: Set<URL> = [General.hubCacheDirectory, General.previousDirectory]
        XCTAssertEqual(General.resolveInstalledDirectory { onDisk.contains($0) },
                       General.hubCacheDirectory)
    }

    /// The update regression: an install that only has the assistant it used before
    /// the switch keeps answering with it rather than going to the keyword gate.
    func testAnInstallWithOnlyThePreviousModelKeepsUsingIt() {
        XCTAssertEqual(General.resolveInstalledDirectory { $0 == General.previousDirectory },
                       General.previousDirectory)
    }

    /// With nothing on disk the answer is where the mirror will unpack, so a fresh
    /// install still writes where it always has.
    func testWithNothingOnDiskTheMirrorPathIsTheAnswer() {
        XCTAssertEqual(General.resolveInstalledDirectory { _ in false }, General.shippedDirectory)
    }

    func testOnlyTheShippedModelIsRunAsReasoning() {
        XCTAssertTrue(General.thinks(loadedFrom: General.shippedDirectory))
        XCTAssertTrue(General.thinks(loadedFrom: General.hubCacheDirectory))
        XCTAssertFalse(General.thinks(loadedFrom: General.previousDirectory),
                       "Instruct-2507 never opens a <think> block")
        XCTAssertFalse(General.thinks(loadedFrom: URL(fileURLWithPath: "/tmp/some-lab-model")))
    }

    /// MLX's hub client writes under Caches; the Lab reads the same place. The first
    /// version of this looked in ~/Documents, which is neither, and probing it on
    /// every tick is what raises the Documents-folder privacy prompt.
    func testTheHuggingFaceFallbackIsLookedForWhereMLXWritesIt() {
        XCTAssertEqual(General.hubCacheDirectory,
                       LabPaths.huggingFaceCacheDirectory(for: General.huggingFaceId))
        XCTAssertFalse(General.hubCacheDirectory.path.contains("/Documents/"))
    }

    /// The previous model has to be one the mirror can still serve, so a reinstall of
    /// it is not refused as unpinned.
    func testThePreviousAssistantArchiveIsStillPinned() {
        XCTAssertNotNil(ModelChecksums.sha256[General.previousArchiveName])
    }

    // MARK: - The chord's wall clock

    func testAReasoningAssistantGetsTheLongerBudget() {
        XCTAssertEqual(AgentLoop.budget(thinks: true), AgentLoop.reasoningBudget)
        XCTAssertEqual(AgentLoop.budget(thinks: false), AgentLoop.defaultBudget)
        XCTAssertGreaterThan(AgentLoop.reasoningBudget, AgentLoop.defaultBudget)
    }

    /// The classifier only refines a reading that already files the words, so its
    /// clock on the reasoning model must stay well under a full reasoning turn.
    func testTheClassifierGivesUpBeforeAFullReasoningTurn() {
        XCTAssertLessThan(IntentPrompt.reasoningTimeoutSeconds,
                          MlxCleanupService.reasoningTimeoutSeconds)
    }
}
