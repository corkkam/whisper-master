import XCTest

@testable import WhisperMaster

/// The Model Lab's pure half: the catalogue, the suite loader, the comparison,
/// the run store, and the fences on pointing a shipped slot at another model.
///
/// Nothing here loads a model — `swift test` cannot run MLX at all (its Metal
/// shaders only compile under xcodebuild), which is exactly why the lab's
/// decisions live in pure types and only the generation itself is behind the
/// actor.
@MainActor
final class ModelLabTests: XCTestCase {

    // MARK: - Catalogue

    func testCatalogueIDsAreUniqueBecauseRunsAreKeyedOnThem() {
        let ids = LabCatalog.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "a duplicate id would collide in every saved run")
    }

    func testEveryModelCanBeFetchedAndDeclaresARole() {
        for model in LabCatalog.all {
            XCTAssertFalse(model.huggingFaceId.isEmpty, "\(model.id) has nowhere to be fetched from")
            XCTAssertFalse(model.roles.isEmpty, "\(model.id) can run no suite")
            XCTAssertGreaterThan(model.approximateDownloadBytes, 0, "\(model.id) has no size to warn about")
        }
    }

    func testTheShippedModelsAreInTheCatalogueAsBaselines() {
        XCTAssertEqual(LabCatalog.shippedCleanup.archiveName, CleanupModel.archiveName)
        XCTAssertEqual(LabCatalog.shippedAssistant.archiveName, CleanupModel.General.archiveName)
    }

    /// A normalizer offered for the tool-calling suite would score zero for a
    /// reason that has nothing to do with its quality.
    func testToolSuiteOnlyOffersModelsThatCanToolCall() {
        let eligible = LabCatalog.models(for: LabSuite.tools.requiredRole)
        XCTAssertFalse(eligible.contains { $0.id == LabCatalog.shippedCleanup.id })
        XCTAssertTrue(eligible.contains { $0.id == LabCatalog.shippedAssistant.id })
    }

    // MARK: - The gate

    func testTheLabIsDevOnly() {
        XCTAssertTrue(FeatureFlags.modelLabAvailable(on: .dev))
        XCTAssertFalse(FeatureFlags.modelLabAvailable(on: .beta))
        XCTAssertFalse(FeatureFlags.modelLabAvailable(on: .stable))
    }

    /// An unreleased product page stays listed and reads "Soon"; a dev bench is
    /// not a roadmap entry, so it is absent instead of promised.
    func testUnlistedRatherThanComingSoonWhenUnavailable() {
        XCTAssertTrue(SettingsSection.mesh.isListed, "Nearby Macs is a roadmap entry")
        XCTAssertEqual(SettingsSection.lab.isListed, FeatureFlags.modelLabAvailable)
    }

    // MARK: - Where things are

    func testRepoRootIsFoundByWalkingUpFromASourceFile() {
        let root = LabPaths.repoRoot(
            containing: "/Users/dev/code/whisper-master/Sources/WhisperMaster/Lab/LabPaths.swift")
        XCTAssertEqual(root?.path, "/Users/dev/code/whisper-master")
    }

    func testRepoRootIsNilForAPathOutsideTheSources() {
        XCTAssertNil(LabPaths.repoRoot(containing: "/tmp/somewhere/else.swift"))
    }

    func testAModelIsOnlyInstalledWhenWeightsTokenizerAndConfigAreAllThere() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lab-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        func write(_ name: String) throws {
            try Data("{}".utf8).write(to: directory.appendingPathComponent(name))
        }

        XCTAssertFalse(LabPaths.isInstalled(at: directory))
        try write("config.json")
        XCTAssertFalse(LabPaths.isInstalled(at: directory), "no tokenizer yet")
        try write("tokenizer.json")
        XCTAssertFalse(LabPaths.isInstalled(at: directory), "no weights yet — a half-download")
        try write("model.safetensors")
        XCTAssertTrue(LabPaths.isInstalled(at: directory))
    }

    // MARK: - Suites

    func testToolSuiteLoadsWithoutACheckoutBecauseItsCasesAreInSwift() throws {
        let loaded = try LabSuiteLoader.load(.tools, repoRoot: nil)
        XCTAssertEqual(loaded.cases.count, LabSuiteLoader.toolCases.count)
        XCTAssertEqual(Set(loaded.cases.map(\.id)).count, loaded.cases.count, "ids collide")
        for labCase in loaded.cases {
            guard case .spokenCommand(_, let expected) = labCase.input else {
                return XCTFail("\(labCase.id) is not a spoken command")
            }
            XCTAssertFalse(expected.isEmpty)
        }
    }

    func testATextSuiteWithoutACheckoutFailsLoudlyRatherThanRunningNothing() {
        XCTAssertThrowsError(try LabSuiteLoader.load(.cleanup, repoRoot: nil)) { error in
            XCTAssertTrue(error is LabSuiteLoader.LoadError)
        }
    }

    /// The real `cases.jsonl`, so a schema change in the eval breaks here rather
    /// than at the start of a 15 minute run. Skips when the test is run from
    /// somewhere other than the checkout.
    func testTheRealCleanupSuiteLoads() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        try XCTSkipUnless(LabPaths.isUsableRepoRoot(root), "not running from the checkout")

        let loaded = try LabSuiteLoader.load(.cleanup, repoRoot: root)
        XCTAssertGreaterThan(loaded.cases.count, 50)
        XCTAssertEqual(Set(loaded.cases.map(\.id)).count, loaded.cases.count)
        XCTAssertEqual(loaded.sources.count, loaded.cases.count, "every text case keeps its EvalCase")
        XCTAssertTrue(loaded.cases.allSatisfy { $0.target == .light })
    }

    /// One case can run against three destinations, so the target has to join the
    /// id or the three rows collide in every table downstream.
    func testDestinationCasesAreOnePerTarget() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        try XCTSkipUnless(LabPaths.isUsableRepoRoot(root), "not running from the checkout")

        let loaded = try LabSuiteLoader.load(.destinations, repoRoot: root)
        XCTAssertEqual(Set(loaded.cases.map(\.id)).count, loaded.cases.count)
        XCTAssertTrue(loaded.cases.allSatisfy { $0.id.contains("/") })
    }

    func testAudioReferencesAreReadOutOfTheFixturesReadme() {
        let markdown = """
        ## P1 — long, clean
        **File: `paragraph-1.wav`**

        > The morning light came through the kitchen window
        > and fell across the table.

        ## P2 — with fillers
        **File: `paragraph-2.wav`**

        > So (um) I was thinking about the project.
        """
        let references = LabSuiteLoader.parseReferences(markdown)
        XCTAssertEqual(references["paragraph-1"],
                       "The morning light came through the kitchen window and fell across the table.")
        XCTAssertEqual(references["paragraph-2"], "So um I was thinking about the project.")
    }

    // MARK: - Statistics

    func testPercentileIsNearestRankAndSurvivesTinySamples() {
        XCTAssertEqual(LabStats.percentile([], 0.5), 0)
        XCTAssertEqual(LabStats.percentile([7], 0.95), 7)
        XCTAssertEqual(LabStats.percentile([1, 2, 3, 4], 0.5), 2)
        XCTAssertEqual(LabStats.percentile([1, 2, 3, 4], 0.95), 4)
    }

    func testAModelThatRanNothingScoresZeroRatherThanPerfect() {
        let empty = LabModelResult(modelID: "x", modelName: "X")
        XCTAssertEqual(empty.scoreFraction, 0)
        XCTAssertNil(empty.meanWER)
    }

    // MARK: - Comparison

    func testVerdictsSeparateRegressionsFromImprovements() {
        let pass = caseResult(id: "a", passed: true)
        let fail = caseResult(id: "a", passed: false)
        XCTAssertEqual(LabComparison.verdict(baseline: pass, candidate: fail), .regression)
        XCTAssertEqual(LabComparison.verdict(baseline: fail, candidate: pass), .improvement)
        XCTAssertEqual(LabComparison.verdict(baseline: pass, candidate: pass), .agree)
        XCTAssertEqual(LabComparison.verdict(baseline: fail, candidate: fail), .agree)
        XCTAssertEqual(LabComparison.verdict(baseline: pass, candidate: nil), .missing)
    }

    func testComparisonKeepsACaseOnlyOneSideRan() {
        var baseline = LabModelResult(modelID: "base", modelName: "Base")
        baseline.cases = [caseResult(id: "shared", passed: true)]
        var candidate = LabModelResult(modelID: "cand", modelName: "Cand")
        candidate.cases = [caseResult(id: "shared", passed: false),
                           caseResult(id: "extra", passed: true)]

        let rows = LabComparison.rows(baseline: baseline, candidate: candidate)
        XCTAssertEqual(rows.map(\.id), ["shared", "extra"], "baseline order first, then the rest")
        XCTAssertEqual(rows[0].verdict, .regression)
        XCTAssertEqual(rows[1].verdict, .missing, "a row only one side ran is not an improvement")
    }

    func testSummaryCountsBothDirections() {
        var baseline = LabModelResult(modelID: "base", modelName: "Base")
        baseline.cases = [caseResult(id: "a", passed: true, latencyMs: 100),
                          caseResult(id: "b", passed: false, latencyMs: 100)]
        baseline.peakGPUBytes = 400_000_000
        var candidate = LabModelResult(modelID: "cand", modelName: "Cand")
        candidate.cases = [caseResult(id: "a", passed: false, latencyMs: 200),
                           caseResult(id: "b", passed: true, latencyMs: 200)]
        candidate.peakGPUBytes = 1_200_000_000

        let summary = LabComparison.summary(baseline: baseline, candidate: candidate)
        XCTAssertEqual(summary.regressions, 1)
        XCTAssertEqual(summary.improvements, 1)
        XCTAssertEqual(summary.baselineScore, 1)
        XCTAssertEqual(summary.candidateScore, 1)
        XCTAssertEqual(summary.baselineP50, 100)
        XCTAssertEqual(summary.candidateP50, 200)
        XCTAssertEqual(summary.candidatePeakGPU, 1_200_000_000)
    }

    func testRankingPutsTheBestScoreFirstThenTheFastest() {
        var slowButGood = LabModelResult(modelID: "good", modelName: "Good")
        slowButGood.cases = [caseResult(id: "a", passed: true, latencyMs: 900)]
        var fastButBad = LabModelResult(modelID: "bad", modelName: "Bad")
        fastButBad.cases = [caseResult(id: "a", passed: false, latencyMs: 10)]

        var run = LabRun(id: 1, suite: .cleanup, startedAt: Date(),
                         appVersion: "1.0", machine: "test")
        run.models = [fastButBad, slowButGood]
        XCTAssertEqual(run.ranked.map(\.modelID), ["good", "bad"])
    }

    // MARK: - Run store

    func testRunsSurviveASaveAndReload() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lab-runs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = LabRunStore(directory: directory, keep: 3, load: false)
        XCTAssertEqual(store.nextRunID, 1)

        var run = LabRun(id: store.nextRunID, suite: .tools, startedAt: Date(),
                         appVersion: "1.0", machine: "test")
        var result = LabModelResult(modelID: "m", modelName: "M")
        result.cases = [caseResult(id: "a", passed: true)]
        run.models = [result]
        store.save(run)

        let reopened = LabRunStore(directory: directory, keep: 3, load: true)
        XCTAssertEqual(reopened.runs.count, 1)
        XCTAssertEqual(reopened.run(id: 1)?.models.first?.passed, 1)
        XCTAssertEqual(reopened.nextRunID, 2)
    }

    func testSavingTheSameRunAgainReplacesItRatherThanAppending() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lab-runs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LabRunStore(directory: directory, keep: 3, load: false)

        var run = LabRun(id: 1, suite: .cleanup, startedAt: Date(), appVersion: "1.0", machine: "test")
        store.save(run)
        run.stopped = true
        store.save(run)

        XCTAssertEqual(store.runs.count, 1)
        XCTAssertTrue(store.runs[0].stopped)
    }

    func testOldRunsArePrunedOldestFirst() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lab-runs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LabRunStore(directory: directory, keep: 2, load: false)

        for id in 1 ... 4 {
            store.save(LabRun(id: id, suite: .cleanup, startedAt: Date(),
                              appVersion: "1.0", machine: "test"))
        }
        XCTAssertEqual(store.runs.map(\.id), [4, 3])
        XCTAssertNil(LabRunStore(directory: directory, keep: 2, load: true).run(id: 1))
    }

    // MARK: - Export

    /// The offline scorer and the dashboard were written against `EvalRunner`'s
    /// `results.json`, so a lab run has to arrive in that shape.
    func testExportMatchesTheShapeTheOfflineScorerReads() throws {
        var result = LabModelResult(modelID: "m", modelName: "M")
        result.cases = [
            LabCaseResult(
                id: "audio-1", category: "audio", target: "light", inputKind: "audio",
                prompt: "paragraph-1.m4a", deterministic: "heard words",
                modelOutput: "heard words", finalOutput: "heard words",
                guardAccepted: true, passed: true, latencyMs: 120, asrMs: 900, wer: 0.04,
                asrText: "heard words", asrReference: "heard words"),
        ]
        let rows = LabRunExport.rows(for: result)
        let row = try XCTUnwrap(rows.first)

        XCTAssertEqual(row["id"] as? String, "audio-1")
        XCTAssertEqual(row["input_kind"] as? String, "audio")
        XCTAssertEqual(row["llm_output"] as? String, "heard words")
        XCTAssertEqual((row["guard"] as? [String: Bool])?["accepted"], true)
        XCTAssertEqual((row["latency_ms"] as? [String: Int])?["asr"], 900)
        XCTAssertEqual((row["latency_ms"] as? [String: Int])?["total"], 1020)
        XCTAssertEqual(row["asr_reference"] as? String, "heard words",
                       "the reference, not the filename")
        XCTAssertNotNil(try? JSONSerialization.data(withJSONObject: rows))
    }

    // MARK: - The override on the shipped slots

    func testAnOverrideIsIgnoredWhenTheModelIsNotOnDisk() throws {
        let defaults = try scratchDefaults()
        LabModelOverride.set("llama-3.2-1b-instruct-4bit", for: .cleanup, defaults: defaults)

        XCTAssertEqual(LabModelOverride.modelID(for: .cleanup, defaults: defaults),
                       "llama-3.2-1b-instruct-4bit", "the choice is remembered, so it can be shown")
        XCTAssertNil(LabModelOverride.directory(for: .cleanup, defaults: defaults),
                     "but a model that is not installed must not be loaded")
        XCTAssertFalse(LabModelOverride.isOverridden(.cleanup, defaults: defaults))
    }

    func testAnUnknownModelIDNeverResolves() throws {
        let defaults = try scratchDefaults()
        LabModelOverride.set("something-that-was-deleted", for: .assistant, defaults: defaults)
        XCTAssertNil(LabModelOverride.model(for: .assistant, defaults: defaults))
        XCTAssertNil(LabModelOverride.directory(for: .assistant, defaults: defaults))
    }

    /// With no override the shipped paths must be untouched — this is the test
    /// that would fail if the lab ever started deciding what a normal build loads.
    func testTheShippedDirectoriesAreUnchangedWithoutAnOverride() {
        let defaults = UserDefaults.standard
        let hadCleanup = defaults.object(forKey: LabModelOverride.cleanupKey)
        defaults.removeObject(forKey: LabModelOverride.cleanupKey)
        defer { if let hadCleanup { defaults.set(hadCleanup, forKey: LabModelOverride.cleanupKey) } }

        XCTAssertEqual(CleanupModel.directory, CleanupModel.shippedDirectory)
        XCTAssertEqual(CleanupModel.General.directory, CleanupModel.General.shippedDirectory)
    }

    // MARK: - Controller

    func testTheControllerIsDormantUntilItIsActivated() {
        let lab = LabController(load: false)
        XCTAssertFalse(lab.isActive)
        XCTAssertTrue(lab.installStates.isEmpty, "no disk read before the page is opened")
        XCTAssertTrue(lab.runStore.runs.isEmpty)
    }

    func testChangingSuiteDropsModelsThatCannotRunIt() {
        let lab = LabController(load: false)
        lab.selectedModelIDs = [LabCatalog.shippedCleanup.id, LabCatalog.shippedAssistant.id]
        lab.suite = .tools
        // The rail applies this when the chip is tapped; the controller's own
        // `selectedModels` must already refuse to hand a normalizer to the runner.
        XCTAssertEqual(lab.selectedModels.map(\.id), [LabCatalog.shippedAssistant.id])
    }

    func testReconcileKeepsTheComparedPairInsideTheRunBeingShown() {
        let lab = LabController(load: false)
        var run = LabRun(id: 9, suite: .cleanup, startedAt: Date(), appVersion: "1", machine: "test")
        run.models = [LabModelResult(modelID: "a", modelName: "A"),
                      LabModelResult(modelID: "b", modelName: "B")]
        lab.seedForSnapshot(runs: [run], installedIDs: [])

        lab.baselineID = "gone"
        lab.candidateID = "also-gone"
        lab.reconcileSelection()
        XCTAssertEqual(lab.baselineID, "a")
        XCTAssertEqual(lab.candidateID, "b")
    }

    // MARK: - Helpers

    private func caseResult(id: String, passed: Bool, latencyMs: Int = 100) -> LabCaseResult {
        LabCaseResult(
            id: id, category: "test", target: "light", inputKind: "text", prompt: id,
            deterministic: id, modelOutput: id, finalOutput: id,
            guardAccepted: true, passed: passed, latencyMs: latencyMs)
    }

    /// A defaults suite of its own, so a test can never write into the real app's
    /// preferences (an override left behind there would change which model a dev
    /// build dictates with).
    private func scratchDefaults() throws -> UserDefaults {
        let name = "lab-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return defaults
    }
}
