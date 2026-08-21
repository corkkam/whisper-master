import Foundation

/// Owns the lifecycle of the **assistant** model — the general instruct model
/// behind the chord (`CleanupModel.General`, `MlxCleanupService.general`).
///
/// This exists because cleanup and tool calling split onto two models. Before the
/// split there was one model and one download: turning on Smart cleanup fetched it,
/// and the assistant got a tool-caller for free. After the split, Smart cleanup
/// fetches a 335 MB text normalizer that **cannot tool-call**, and nothing fetched
/// the assistant's model at all — so `AgentLoop` and the intent classifier found it
/// missing, took the deterministic path, and the whole assistant degraded to the
/// keyword gate with no error anywhere. That silence is the bug this closes.
///
/// **Nothing here downloads at launch.** The model is 2 GB and the chord is a
/// feature many installs never touch, so the fetch has exactly two triggers:
///
/// 1. **First use of the chord**, when the user has left the assistant enabled.
///    Permission is the toggle they already answered; the download is deferred to
///    the moment it is actually wanted. The capture in flight is *not* blocked —
///    it takes the deterministic path as it does today — because a spoken command
///    must never wait on a cold 2 GB download.
/// 2. **The explicit button in Settings**, so the fetch is discoverable and
///    startable before the first use rather than being a mystery.
///
/// Shaped after `CleanupModelManager` (same owner, same `AppState`-bridge role,
/// same "publish progress to Settings only" rule) and deliberately kept as a
/// separate type: the two models have different sizes, different triggers, and
/// different failure consequences, and folding them into one manager is what
/// would tempt a future reader to reuse one readiness flag for both.
@MainActor
final class AssistantModelManager {
    private let state: AppState
    private let service: MlxCleanupService
    private var isPreparing = false
    /// Set once we have kicked off an on-demand fetch this launch, so a person
    /// using the chord repeatedly while a 2 GB download runs doesn't queue more.
    private var didStartOnDemand = false

    init(state: AppState, service: MlxCleanupService = .general) {
        self.state = state
        self.service = service
    }

    /// Drain the Settings button and keep `assistantModelReady` honest. Cheap and
    /// idempotent — called from the refresh loop beside `syncWithToggle`.
    func sync() {
        if state.assistantModelDownloadRequested {
            state.assistantModelDownloadRequested = false
            state.assistantModelFailed = false
            Task { await ensureAvailable() }
            return
        }
        // Reflect a model that some other path already loaded (a previous launch's
        // install, or the on-demand fetch below) without doing any work.
        if !state.assistantModelReady, CleanupModel.General.isInstalled {
            Task { [service] in
                if await service.isReady { state.assistantModelReady = true }
            }
        }
    }

    /// Called when the chord is actually used. Starts the fetch **in the
    /// background** and returns immediately: this capture is already being handled
    /// by the deterministic path, and the model becomes available for the next one.
    ///
    /// Does nothing when the user has turned the assistant off — the toggle is the
    /// permission, and a 2 GB download for a feature they declined is exactly the
    /// imposition the two-trigger rule exists to prevent.
    func prepareForFirstUse() {
        guard Policy.shouldFetchOnFirstUse(
            assistantEnabled: state.connectorAgentEnabled,
            alreadyInstalled: CleanupModel.General.isInstalled,
            alreadyStarted: didStartOnDemand,
            previouslyFailed: state.assistantModelFailed)
        else { return }
        didStartOnDemand = true
        Log.modelPrep.notice("Assistant model missing on first chord use; fetching in background")
        Task { await ensureAvailable() }
    }

    /// When a chord press should start the 2 GB fetch. Pure, so the rule can be
    /// tested without a filesystem, a network, or a 2 GB download — which is the
    /// only way to test a decision whose "yes" branch is that expensive.
    enum Policy {
        static func shouldFetchOnFirstUse(
            assistantEnabled: Bool,
            alreadyInstalled: Bool,
            alreadyStarted: Bool,
            previouslyFailed: Bool
        ) -> Bool {
            // The toggle is the permission. Off means off, however often the chord
            // is pressed — the other tiers behind it still work without a model.
            guard assistantEnabled else { return false }
            guard !alreadyInstalled else { return false }
            // One fetch per launch. Someone using the chord while 2 GB is in flight
            // must not queue a second transfer.
            guard !alreadyStarted else { return false }
            // A failed fetch is not retried from the chord — retrying a 2 GB
            // download on every command would be the worst possible response to a
            // bad network. Settings has the button.
            return !previouslyFailed
        }
    }

    /// Free the model when the user turns the assistant off. The bytes on disk
    /// stay — re-enabling should not mean downloading 2 GB again.
    func releaseIfDisabled() {
        guard !state.connectorAgentEnabled, state.assistantModelReady else { return }
        state.assistantModelReady = false
        state.assistantModelDownload = nil
        Task { await service.release() }
    }

    // MARK: - Internals

    private func ensureAvailable() async {
        guard !isPreparing else { return }
        if await service.isReady { state.assistantModelReady = true; return }
        isPreparing = true
        defer {
            isPreparing = false
            state.assistantModelDownload = nil
        }
        state.assistantModelFailed = false

        if !CleanupModel.General.isInstalled {
            await download()
        }

        // Same retry shape as the cleanup model: each MLX load attempt is
        // timeout-bounded in the service, and a stalled Metal init under launch
        // contention should not read as a permanent failure.
        var attempt = 0
        while !(await service.isReady), attempt < 3 {
            attempt += 1
            await service.prepare(
                configuration: .init(directory: CleanupModel.General.directory))
            if await service.isReady { break }
            Log.modelPrep.error("Assistant model load attempt \(attempt) not ready; retrying")
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }

        if await service.isReady {
            state.assistantModelReady = true
            Log.modelPrep.notice("Assistant model ready")
        } else {
            state.assistantModelFailed = true
            Log.modelPrep.error("Assistant model failed to load after \(attempt) attempts")
        }
    }

    /// R2 mirror first (real byte counts, resumable, checksum-pinned), Hugging
    /// Face as the loud fallback — the same order and the same honesty as every
    /// other model in the app.
    private func download() async {
        do {
            try await ModelInstaller.installIfNeeded(
                archiveName: CleanupModel.General.archiveName,
                destinationRoot: CleanupModel.modelsRoot,
                label: CleanupModel.General.label,
                isInstalled: { CleanupModel.General.isInstalled },
                onProgress: { [weak self] progress in
                    Task { @MainActor in self?.state.assistantModelDownload = progress }
                }
            )
        } catch {
            Log.modelPrep.error(
                "Assistant model mirror unavailable, falling back to Hugging Face: \(error.localizedDescription, privacy: .public)")
            await service.prepare(configuration: .init(id: CleanupModel.General.huggingFaceId)) {
                [weak self] fraction in
                Task { @MainActor in
                    self?.state.assistantModelDownload = ModelInstaller.Progress(
                        fractionCompleted: fraction,
                        detail: "Downloading from backup source (slower)")
                }
            }
        }
    }
}
