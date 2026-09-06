import Foundation

/// What the lab knows about a catalogue entry on *this* Mac.
struct LabInstallState: Sendable, Equatable {
    var isInstalled = false
    var directory: URL?
    var bytes: Int64 = 0
}

/// Which half of the page is showing.
enum LabTab: String, CaseIterable, Identifiable {
    /// Baseline against candidate, case by case. The page's reason to exist.
    case compare
    /// Every model in the run, ranked. Breadth, when the question is "which of
    /// these is worth a closer look".
    case leaderboard

    var id: String { rawValue }
    var title: String { self == .compare ? "Compare" : "Leaderboard" }
}

/// Which comparison rows to show. The default hides agreements: on a 92-case
/// suite, 80 rows of "both did the same thing" is where the 11 that matter hide.
enum LabRowFilter: String, CaseIterable, Identifiable {
    case disagreements
    case regressions
    case all

    var id: String { rawValue }
    var title: String {
        switch self {
        case .disagreements: return "Disagreements"
        case .regressions: return "Regressions"
        case .all: return "All cases"
        }
    }
}

/// Everything the Model Lab page reads and writes. Owned by `AppState`, dormant
/// until the page is opened — nothing here touches the disk or a model until
/// somebody asks for it, so `swift test` and the headless snapshot renderer build
/// an `AppState` without scanning for models. Same posture as
/// `UsageStore(load: false)` and `AgentSurfaceController`.
@MainActor
@Observable
final class LabController {
    // MARK: Selection

    var suite: LabSuite = .cleanup
    var tab: LabTab = .compare
    var filter: LabRowFilter = .disagreements
    /// Models ticked for the next run. Seeded with the shipped cleanup model so
    /// the first run has a baseline without anyone having to know that it needs one.
    var selectedModelIDs: Set<String> = [LabCatalog.shippedCleanup.id]
    var baselineID: String = LabCatalog.shippedCleanup.id
    var candidateID: String?
    /// Which stored run the page is showing. Nil means the newest.
    var selectedRunID: Int?
    /// Case row opened for its full text.
    var expandedCaseID: String?

    // MARK: State

    private(set) var installStates: [String: LabInstallState] = [:]
    private(set) var repoRoot: URL?
    private(set) var isActive = false

    let runStore: LabRunStore
    let runner: LabBenchRunner

    private let defaults: UserDefaults

    init(load: Bool = false, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let store = LabRunStore(load: load)
        runStore = store
        runner = LabBenchRunner(store: store)
        if load { activate() }
    }

    /// Read the disk once the page is actually on screen.
    func activate() {
        guard !isActive else { return }
        isActive = true
        refresh()
    }

    func refresh() {
        runStore.reload()
        repoRoot = LabPaths.resolvedRepoRoot(defaults: defaults)
        var states: [String: LabInstallState] = [:]
        for model in LabCatalog.all {
            if let directory = LabPaths.installedDirectory(for: model) {
                states[model.id] = LabInstallState(
                    isInstalled: true, directory: directory,
                    bytes: LabPaths.directorySize(directory))
            } else {
                states[model.id] = LabInstallState()
            }
        }
        installStates = states
    }

    #if DEBUG
    /// Fill the page for the headless snapshot pass. Marks the controller active
    /// so the view's `activate()` does not immediately re-read the real disk over
    /// the seed.
    func seedForSnapshot(runs: [LabRun], installedIDs: Set<String>) {
        isActive = true
        runStore.seedForSnapshot(runs)
        installStates = Dictionary(uniqueKeysWithValues: LabCatalog.all.map { model in
            (model.id, LabInstallState(
                isInstalled: installedIDs.contains(model.id),
                // A path that cannot exist: the seeded state feeds a Delete
                // button, and a real directory here would make the snapshot pass
                // one stray click away from deleting something.
                directory: installedIDs.contains(model.id)
                    ? URL(fileURLWithPath: "/dev/null/model-lab-snapshot") : nil,
                bytes: installedIDs.contains(model.id) ? model.approximateDownloadBytes : 0))
        })
        repoRoot = URL(fileURLWithPath: "/repo")
        selectedRunID = runs.first?.id
        selectedModelIDs = Set(runs.first?.models.map(\.modelID) ?? [])
        reconcileSelection()
    }
    #endif

    func state(for model: LabModel) -> LabInstallState {
        installStates[model.id] ?? LabInstallState()
    }

    // MARK: Repo

    var repoPath: String { repoRoot?.path ?? "" }

    /// Point the lab at a checkout. Only accepted when the cases file is really
    /// there, so a wrong folder says so at the moment of choosing rather than at
    /// the start of a 15 minute run.
    @discardableResult
    func setRepoRoot(_ url: URL) -> Bool {
        guard LabPaths.isUsableRepoRoot(url) else { return false }
        defaults.set(url.path, forKey: LabPaths.repoOverrideKey)
        repoRoot = url
        return true
    }

    // MARK: Models

    /// Models that can run the chosen suite. A normalizer offered for the
    /// tool-calling suite would score zero for a reason that has nothing to do
    /// with its quality, so it is not offered.
    var eligibleModels: [LabModel] {
        LabCatalog.models(for: suite.requiredRole)
    }

    var selectedModels: [LabModel] {
        eligibleModels.filter { selectedModelIDs.contains($0.id) }
    }

    func toggle(_ model: LabModel) {
        if selectedModelIDs.contains(model.id) {
            selectedModelIDs.remove(model.id)
        } else {
            selectedModelIDs.insert(model.id)
        }
    }

    /// Total bytes a run would have to fetch first, so the page can say so before
    /// anything starts downloading.
    var pendingDownloadBytes: Int64 {
        selectedModels.filter { !state(for: $0).isInstalled }
            .reduce(0) { $0 + $1.approximateDownloadBytes }
    }

    /// Delete a model's files. Never offered for a model this build ships with:
    /// deleting the cleanup model from a page about benchmarks would break
    /// dictation, and the lab is not where that decision belongs.
    func canDelete(_ model: LabModel) -> Bool {
        guard state(for: model).isInstalled else { return false }
        return model.provenance == .candidate || model.provenance == .retired
    }

    func delete(_ model: LabModel) {
        guard canDelete(model), let directory = state(for: model).directory else { return }
        try? FileManager.default.removeItem(at: directory)
        if LabModelOverride.modelID(for: .cleanup, defaults: defaults) == model.id {
            LabModelOverride.set(nil, for: .cleanup, defaults: defaults)
        }
        if LabModelOverride.modelID(for: .assistant, defaults: defaults) == model.id {
            LabModelOverride.set(nil, for: .assistant, defaults: defaults)
        }
        refresh()
    }

    // MARK: Overrides

    func overrideModel(for role: LabRole) -> LabModel? {
        LabModelOverride.model(for: role, defaults: defaults)
    }

    /// Point a shipped slot at a model, or hand it back with nil. Only takes
    /// effect on the next load of that model, which the copy beside the button
    /// says: the running app has the old one resident.
    func use(_ model: LabModel?, for role: LabRole) {
        LabModelOverride.set(model?.id, for: role, defaults: defaults)
    }

    func canUse(_ model: LabModel, for role: LabRole) -> Bool {
        LabModelOverride.isPermitted && model.supports(role) && state(for: model).isInstalled
    }

    // MARK: Runs

    /// The run being shown: the one in flight, else the one picked from history,
    /// else the newest saved.
    var activeRun: LabRun? {
        if let live = runner.run, runner.isRunning { return live }
        if let id = selectedRunID, let stored = runStore.run(id: id) { return stored }
        return runner.run ?? runStore.runs.first
    }

    var baselineResult: LabModelResult? { activeRun?.result(modelID: baselineID) }

    var candidateResult: LabModelResult? {
        guard let candidateID else { return nil }
        return activeRun?.result(modelID: candidateID)
    }

    var comparisonRows: [LabComparisonRow] {
        let rows = LabComparison.rows(baseline: baselineResult, candidate: candidateResult)
        switch filter {
        case .all: return rows
        case .disagreements: return rows.filter { !$0.isAgreement }
        case .regressions: return rows.filter { $0.verdict == .regression }
        }
    }

    var comparisonSummary: LabComparison.Summary {
        LabComparison.summary(baseline: baselineResult, candidate: candidateResult)
    }

    /// Keep the two compared slots pointing at models the shown run actually has,
    /// so opening an old run does not leave the page comparing nothing.
    func reconcileSelection() {
        guard let run = activeRun, !run.models.isEmpty else { return }
        let ids = run.models.map(\.modelID)
        if !ids.contains(baselineID) { baselineID = ids[0] }
        if candidateID == nil || !ids.contains(candidateID!) {
            candidateID = ids.first { $0 != baselineID }
        }
    }

    func start() {
        guard !runner.isRunning else { return }
        runner.start(suite: suite, models: selectedModels, repoRoot: repoRoot)
        selectedRunID = runner.run?.id
        reconcileSelection()
    }

    func stop() { runner.stop() }

    /// Write the shown run out in the shape `eval-score` and the run-history
    /// dashboard already read, and return where it went.
    @discardableResult
    func export() -> URL? {
        guard let run = activeRun else { return nil }
        let directory = LabPaths.runsDirectory.appendingPathComponent("export", isDirectory: true)
        let written = LabRunExport.write(run: run, to: directory)
        return written.isEmpty ? nil : directory
    }
}
