import Foundation

/// Owns the lifecycle of the on-device cleanup model on behalf of the view
/// model: it reconciles the `llmCleanupEnabled` toggle with what's on disk and
/// loaded, drives the **background** download, and publishes everything the UI
/// needs — download progress to `AppState.cleanupModelDownload` (Settings only)
/// and a one-shot ready signal to `AppState.cleanupModelReadyAt` (the notch).
///
/// Owned by `DictationViewModel` (the sole `AppState` writer), same arrangement
/// as `ReminderScheduler`. The `MlxCleanupService` stays UI-unaware; this type
/// is the only bridge between it and app state. Nothing here blocks dictation —
/// the download and load run in detached tasks.
@MainActor
final class CleanupModelManager {
    private let state: AppState
    private let service: MlxCleanupService
    private var isPreparing = false
    /// The toggle value we last reconciled, so `syncWithToggle` (called every
    /// refresh tick) only acts on an actual change.
    private var lastSyncedEnabled: Bool?

    init(state: AppState, service: MlxCleanupService = .shared) {
        self.state = state
        self.service = service
    }

    /// Reconcile the model with the toggle. Cheap and idempotent — safe to call
    /// on launch and from the AppDelegate refresh loop. Enabling kicks a
    /// background download+warm; disabling frees the model.
    func syncWithToggle() {
        // Manual retry after a surfaced failure (the Settings "Retry" button).
        if state.cleanupRetryRequested {
            state.cleanupRetryRequested = false
            if state.llmCleanupEnabled, !state.cleanupModelReady {
                state.cleanupModelFailed = false
                Task { await ensureAvailable() }
            }
        }

        guard state.llmCleanupEnabled != lastSyncedEnabled else { return }
        lastSyncedEnabled = state.llmCleanupEnabled

        if state.llmCleanupEnabled {
            Task { await ensureAvailable() }
        } else {
            state.cleanupModelDownload = nil
            state.cleanupModelReady = false
            state.cleanupModelFailed = false
            Task { await service.release() }
        }
    }

    // MARK: - Internals

    private func ensureAvailable() async {
        guard !isPreparing else { return }
        if await service.isReady { state.cleanupModelReady = true; return }
        isPreparing = true
        defer {
            isPreparing = false
            state.cleanupModelDownload = nil
        }
        state.cleanupModelFailed = false

        // Download first if it isn't on disk (progress → Settings only). This also
        // makes one load attempt (and the HF fallback) inside downloadAndWarm.
        let freshDownload = !CleanupModel.isInstalled
        if freshDownload {
            await downloadAndWarm()
        }

        // The model is on disk now, but the MLX load itself can stall under
        // launch-time GPU contention. Each attempt is timeout-bounded in the
        // service, so retry a few times before surfacing an honest failure rather
        // than spinning on "Preparing…" forever.
        var attempt = 0
        while !(await service.isReady), attempt < 3 {
            attempt += 1
            await service.prepare(configuration: .init(directory: CleanupModel.directory))
            if await service.isReady { break }
            Log.modelPrep.error("Smart cleanup load attempt \(attempt) not ready; retrying")
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }

        if await service.isReady {
            state.cleanupModelReady = true
            // Announce readiness exactly once, and only for a fresh download — the
            // only notch signal; nothing else here touches the notch or tray.
            if freshDownload {
                state.cleanupModelReadyAt = Date()
                Analytics.shared.send(.cleanupModelDownloaded)
                Log.modelPrep.notice("Smart cleanup model downloaded and ready")
            }
        } else {
            state.cleanupModelFailed = true
            Log.modelPrep.error("Smart cleanup model failed to load after \(attempt) attempts")
        }
    }

    /// R2 mirror first (own progress %), Hugging Face as the loud fallback.
    private func downloadAndWarm() async {
        do {
            try await ModelInstaller.installIfNeeded(
                archiveName: CleanupModel.archiveName,
                destinationRoot: CleanupModel.modelsRoot,
                label: CleanupModel.label,
                isInstalled: { CleanupModel.isInstalled },
                onProgress: { [weak self] progress in
                    Task { @MainActor in self?.state.cleanupModelDownload = progress }
                }
            )
            await service.prepare(configuration: .init(directory: CleanupModel.directory))
        } catch {
            Log.modelPrep.error(
                "Cleanup model mirror unavailable, falling back to Hugging Face: \(error.localizedDescription, privacy: .public)")
            await service.prepare(configuration: .init(id: CleanupModel.huggingFaceId)) { [weak self] fraction in
                Task { @MainActor in
                    self?.state.cleanupModelDownload = ModelInstaller.Progress(
                        fractionCompleted: fraction,
                        detail: "Downloading from backup source (slower)")
                }
            }
        }
    }
}
