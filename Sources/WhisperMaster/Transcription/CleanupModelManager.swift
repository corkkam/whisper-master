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
        guard state.llmCleanupEnabled != lastSyncedEnabled else { return }
        lastSyncedEnabled = state.llmCleanupEnabled

        if state.llmCleanupEnabled {
            Task { await ensureAvailable() }
        } else {
            state.cleanupModelDownload = nil
            state.cleanupModelReady = false
            Task { await service.release() }
        }
    }

    // MARK: - Internals

    private func ensureAvailable() async {
        guard !isPreparing else { return }
        if await service.isReady { return }
        isPreparing = true
        defer {
            isPreparing = false
            state.cleanupModelDownload = nil
        }

        if CleanupModel.isInstalled {
            // Already downloaded (a prior session): warm it, no "ready" banner.
            await service.prepare(configuration: .init(directory: CleanupModel.directory))
            state.cleanupModelReady = await service.isReady
            return
        }

        await downloadAndWarm()

        // Announce readiness exactly once — this is the only notch signal; the
        // download progress above never touches the notch or tray.
        if await service.isReady {
            state.cleanupModelReady = true
            state.cleanupModelReadyAt = Date()
            Log.modelPrep.notice("Smart cleanup model downloaded and ready")
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
