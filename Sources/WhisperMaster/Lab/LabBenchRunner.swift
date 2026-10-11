import AVFoundation
import Foundation
import MLX
import MLXLMCommon

#if SWIFT_PACKAGE
import EvalScoreKit
#endif

/// One line in the run log.
struct LabLogLine: Identifiable, Sendable {
    enum Kind: Sendable { case info, good, bad }
    let id = UUID()
    let at: Date
    let kind: Kind
    let text: String
}

/// Runs a suite against a list of models and records what it cost.
///
/// **One model is resident at a time, and that is a measurement decision.** Two
/// models loaded together share one GPU allocator, so neither one's peak is its
/// own and the comparison silently becomes a comparison of load order. Each model
/// is loaded, warmed, run, released, and the buffer pool cleared before the next
/// starts — which is also why a four-model run takes four load times.
///
/// The engine is `@MainActor` for its published progress and does its waiting on
/// `MlxCleanupService`, an actor: the generation happens off the main thread even
/// though the bookkeeping does not.
@MainActor
@Observable
final class LabBenchRunner {
    /// Live state of the run in flight. `run` is the same value that gets saved,
    /// filled in as it goes, so a stopped run keeps everything it had finished.
    private(set) var run: LabRun?
    private(set) var isRunning = false
    private(set) var log: [LabLogLine] = []
    private(set) var modelIndex = 0
    private(set) var modelCount = 0
    private(set) var caseIndex = 0
    private(set) var caseCount = 0
    private(set) var currentModelName = ""
    private(set) var startedAt: Date?
    /// Set when the run could not start at all (no checkout, unusable suite).
    private(set) var failure: String?

    private var task: Task<Void, Never>?
    private let memory: LabMemorySource
    private let store: LabRunStore

    /// How often the run log is trimmed back. A 92-case run over four models
    /// writes several hundred lines and the view keeps all of them alive.
    private let logLimit = 400

    init(store: LabRunStore, memory: LabMemorySource = LabGPUMemorySource()) {
        self.store = store
        self.memory = memory
    }

    var progressFraction: Double {
        guard modelCount > 0, caseCount > 0 else { return 0 }
        let done = Double(modelIndex * caseCount + caseIndex)
        return min(1, done / Double(modelCount * caseCount))
    }

    // MARK: - Lifecycle

    /// `limit` runs only the first N cases. Used by the headless bench for a
    /// quick pass; **it is logged, never silent** — a bench that ran 10 of 92 and
    /// reported a score without saying so is a lie by omission.
    func start(suite: LabSuite, models: [LabModel], repoRoot: URL?, limit: Int? = nil) {
        guard !isRunning, !models.isEmpty else { return }
        failure = nil
        log = []

        var loaded: LabSuiteCases
        do {
            loaded = try LabSuiteLoader.load(suite, repoRoot: repoRoot)
        } catch {
            failure = error.localizedDescription
            append(.bad, error.localizedDescription)
            return
        }
        if let limit, limit > 0, limit < loaded.cases.count {
            append(.info, "limited to the first \(limit) of \(loaded.cases.count) cases")
            loaded = LabSuiteCases(cases: Array(loaded.cases.prefix(limit)), sources: loaded.sources)
        }

        var newRun = LabRun(
            id: store.nextRunID, suite: suite, startedAt: Date(),
            appVersion: AppInfo.version, machine: LabMachine.summary)
        newRun.models = models.map { LabModelResult(modelID: $0.id, modelName: $0.name) }

        run = newRun
        isRunning = true
        startedAt = Date()
        modelIndex = 0
        caseIndex = 0
        modelCount = models.count
        caseCount = loaded.cases.count
        currentModelName = models[0].name
        append(.info, "\(suite.title): \(loaded.cases.count) cases, \(models.count) model\(models.count == 1 ? "" : "s")")

        task = Task { [weak self] in
            await self?.execute(suite: suite, models: models, loaded: loaded)
        }
    }

    /// Stop after the case in flight. A generation is not interruptible from
    /// outside MLX, so "stop" means "no further cases" rather than "stop now" —
    /// which for a 12-second timeout is a couple of seconds at worst.
    func stop() {
        guard isRunning else { return }
        append(.info, "stopping after the current case")
        task?.cancel()
    }

    // MARK: - Execution

    private func execute(suite: LabSuite, models: [LabModel], loaded: LabSuiteCases) async {
        // ASR is the same work for every model, so a recording is transcribed once
        // and the text reused. Running it per model would triple an audio run and
        // measure the ASR three times instead of the cleanup three times.
        var transcripts: [String: (text: String, ms: Int)] = [:]

        for (index, model) in models.enumerated() {
            if Task.isCancelled { break }
            modelIndex = index
            caseIndex = 0
            currentModelName = model.name

            var result = LabModelResult(modelID: model.id, modelName: model.name)
            let service = MlxCleanupService()
            memory.resetPeak()
            let before = memory.sample(atMs: 0)

            if LabPaths.installedDirectory(for: model) == nil {
                do {
                    try await download(model)
                } catch {
                    if Task.isCancelled { break }
                    result.failure = "Download failed: \(error.localizedDescription)"
                    append(.bad, "\(model.name): \(result.failure!)")
                    update(result, at: index)
                    persist()
                    continue
                }
                if Task.isCancelled { break }
            }
            guard let configuration = configuration(for: model) else {
                result.failure = "Downloaded, but the files MLX needs are not all there."
                append(.bad, "\(model.name): \(result.failure!)")
                update(result, at: index)
                persist()
                continue
            }
            append(.info, "\(model.name): loading")

            let loadMs = await service.prepareTimed(configuration: configuration)
            guard await service.isReady else {
                result.loadMs = loadMs
                result.failure = "Failed to load. See the log in Console for the MLX error."
                append(.bad, "\(model.name): load failed after \(LabFormat.milliseconds(loadMs))")
                update(result, at: index)
                persist()
                await service.release()
                continue
            }
            let afterLoad = memory.sample(atMs: loadMs)
            result.loadMs = loadMs
            result.loadGPUBytes = max(0, afterLoad.activeBytes - before.activeBytes)
            result.diskBytes = LabPaths.installedDirectory(for: model)
                .map { LabPaths.directorySize($0) } ?? 0
            result.memory = [afterLoad]
            append(.good, "\(model.name): ready in \(LabFormat.milliseconds(loadMs)), "
                + "\(LabFormat.bytes(result.loadGPUBytes)) resident")

            let toolSetup = suite == .tools ? LabToolBench.setup() : nil
            let modelStarted = Date()

            for (caseNumber, labCase) in loaded.cases.enumerated() {
                if Task.isCancelled { break }
                caseIndex = caseNumber

                let caseResult = await evaluate(
                    labCase, with: service, source: loaded.sources[labCase.id],
                    toolSetup: toolSetup, transcripts: &transcripts)
                result.cases.append(caseResult)

                // Sampled at case boundaries, not on a timer: a timer racing an
                // MLX generation adds Metal traffic to the thing being measured.
                // The peak is MLX's own high-water mark, so nothing is missed
                // between samples.
                let sample = memory.sample(atMs: Int(Date().timeIntervalSince(modelStarted) * 1000))
                result.memory.append(sample)
                // **Peak over the baseline, not the raw high-water mark.** MLX
                // accounts for the whole process, and the shipped cleanup model is
                // often already resident (Smart cleanup on) — charging its 335 MB
                // to every candidate would make each one look bigger than it is,
                // and by a different amount depending on what else was loaded.
                result.peakGPUBytes = max(result.peakGPUBytes,
                                          max(0, sample.peakBytes - before.activeBytes))
                result.peakFootprintBytes = max(result.peakFootprintBytes, sample.footprintBytes)

                if !caseResult.passed {
                    append(.bad, "\(labCase.id): \(caseResult.reasons.first ?? "failed")")
                }
                // In memory every case so the table fills in live; to disk only at
                // the end of a model, because a 92-case run would otherwise rewrite
                // a growing JSON file 92 times.
                update(result, at: index)
            }

            append(.good, "\(model.name): \(result.passed)/\(result.total) at "
                + "\(LabFormat.milliseconds(result.p50LatencyMs)) p50, peak "
                + "\(LabFormat.bytes(result.peakGPUBytes))")
            update(result, at: index)
            persist()

            // Release before the next model, and clear MLX's buffer pool: freed
            // Metal buffers are pooled for reuse rather than returned to the OS,
            // so without this the next model's "peak" includes this one's.
            await service.release()
            append(.info, "released \(model.name)")
        }

        finish()
    }

    private func finish() {
        isRunning = false
        caseIndex = caseCount
        if var current = run {
            current.finishedAt = Date()
            current.stopped = Task.isCancelled
            run = current
            store.save(current)
        }
        append(.info, Task.isCancelled ? "stopped" : "done")
    }

    private func update(_ result: LabModelResult, at index: Int) {
        guard var current = run, index < current.models.count else { return }
        current.models[index] = result
        run = current
    }

    private func persist() {
        guard let current = run else { return }
        store.save(current)
    }

    // MARK: - One case

    private func evaluate(
        _ labCase: LabCase, with service: MlxCleanupService,
        source: EvalCase?, toolSetup: LabToolBench.Setup?,
        transcripts: inout [String: (text: String, ms: Int)]
    ) async -> LabCaseResult {
        switch labCase.input {
        case .text(let text):
            return await cleanupCase(labCase, input: text, asrMs: nil, wer: nil,
                                     source: source, service: service)

        case .audio(let url, let reference):
            var asrText = ""
            var asrMs = 0
            if let cached = transcripts[labCase.id] {
                asrText = cached.text
                asrMs = cached.ms
            } else if let fresh = await Self.transcribe(url) {
                asrText = fresh.text
                asrMs = fresh.ms
                transcripts[labCase.id] = fresh
            }
            let wer = WER.score(reference: reference, hypothesis: asrText)
            return await cleanupCase(labCase, input: asrText, asrMs: asrMs, wer: wer,
                                     source: source, service: service,
                                     asrText: asrText, asrReference: reference)

        case .spokenCommand(let spoken, let expectedTool):
            return await toolCase(labCase, spoken: spoken, expectedTool: expectedTool,
                                  setup: toolSetup, service: service)
        }
    }

    /// A cleanup case: the deterministic passes exactly as the app runs them, then
    /// the model, then the real guard, then the mechanical score.
    private func cleanupCase(
        _ labCase: LabCase, input: String, asrMs: Int?, wer: Double?,
        source: EvalCase?, service: MlxCleanupService,
        asrText: String? = nil, asrReference: String? = nil
    ) async -> LabCaseResult {
        let deterministic = LabDeterministicPipeline.run(input)
        let started = Date()
        let (cleaned, cost) = await service.cleanMeasured(
            deterministic, systemPrompt: labCase.target.prompt, target: labCase.target)
        let latencyMs = Int(Date().timeIntervalSince(started) * 1000)

        let modelOutput = cleaned ?? ""
        let accepted = cleaned.map {
            CleanupFaithfulnessGuard.accept(
                original: deterministic, cleaned: $0, allowRephrase: labCase.target.allowsRephrase)
        } ?? false
        let finalOutput = accepted ? modelOutput : deterministic

        var passed: Bool
        var reasons: [String] = []
        var attribution: String?
        if let source {
            let row = ResultRow(
                id: labCase.id, target: labCase.target.rawValue, inputKind: labCase.inputKind,
                asrText: nil, asrReference: nil, llmOutput: finalOutput,
                guardVerdict: GuardVerdict(accepted: accepted),
                latencyMs: ["llm": latencyMs], wer: wer)
            let score = Scorer.score(evalCase: source, row: row)
            passed = score.mechanicalPass
            reasons = score.reasons
            attribution = score.attribution
        } else if let wer {
            // An audio case has no keyword rules: the question is whether the words
            // were heard, and `Scorer`'s own threshold is the arbiter.
            passed = wer <= Scorer.werFailThreshold
            if !passed { reasons = ["asr wer \(Int(wer * 100))%"]; attribution = "asr" }
        } else {
            // No rules to break. Producing *something* the guard accepted is the
            // only claim being made, and it is labelled as such in the table.
            passed = accepted
            if !accepted { reasons = ["guard rejected the rewrite"]; attribution = "cleanup" }
        }

        return LabCaseResult(
            id: labCase.id, category: labCase.category, target: labCase.target.rawValue,
            inputKind: labCase.inputKind, prompt: labCase.prompt,
            deterministic: deterministic, modelOutput: modelOutput, finalOutput: finalOutput,
            guardAccepted: accepted, passed: passed, reasons: reasons, attribution: attribution,
            latencyMs: latencyMs, asrMs: asrMs, wer: wer,
            promptTokens: cost.promptTokens, generatedTokens: cost.generatedTokens,
            tokensPerSecond: cost.tokensPerSecond,
            asrText: asrText, asrReference: asrReference)
    }

    /// A tool case: first model turn only, native tool schemas, pass when the
    /// parser reads a call to the expected tool.
    private func toolCase(
        _ labCase: LabCase, spoken: String, expectedTool: String,
        setup: LabToolBench.Setup?, service: MlxCleanupService
    ) async -> LabCaseResult {
        guard let setup else {
            return LabCaseResult(
                id: labCase.id, category: labCase.category, target: "tools",
                inputKind: labCase.inputKind, prompt: spoken, deterministic: "",
                modelOutput: "", finalOutput: "", guardAccepted: false, passed: false,
                reasons: ["tool set unavailable"], latencyMs: 0, expectedTool: expectedTool)
        }
        let started = Date()
        let (raw, cost) = await service.generateWithToolsMeasured(
            messages: LabToolBench.messages(for: spoken, setup: setup),
            toolSchemasJSON: setup.schemas)
        let latencyMs = Int(Date().timeIntervalSince(started) * 1000)
        let output = raw ?? ""
        let called = LabToolBench.calledTool(in: output, setup: setup)
        let passed = called == expectedTool
        var reasons: [String] = []
        if called == nil {
            reasons = ["no parseable tool call"]
        } else if !passed {
            reasons = ["called \(called!), expected \(expectedTool)"]
        }

        return LabCaseResult(
            id: labCase.id, category: labCase.category, target: "tools",
            inputKind: labCase.inputKind, prompt: spoken, deterministic: "",
            modelOutput: output, finalOutput: output, guardAccepted: called != nil,
            passed: passed, reasons: reasons, attribution: passed ? nil : "cleanup",
            latencyMs: latencyMs,
            promptTokens: cost.promptTokens, generatedTokens: cost.generatedTokens,
            tokensPerSecond: cost.tokensPerSecond,
            expectedTool: expectedTool, calledTool: called)
    }

    // MARK: - Helpers

    /// Load from disk only. `execute` downloads first, because a load that has
    /// to fetch spends its 60-second timeout on the network.
    private func configuration(for model: LabModel) -> ModelConfiguration? {
        LabPaths.installedDirectory(for: model).map { ModelConfiguration(directory: $0) }
    }

    /// Fetch a model before its load, logging every tenth of the way. The log is
    /// the only progress there is, and a 4 GB fetch with no word for minutes
    /// reads as a hang.
    private func download(_ model: LabModel) async throws {
        append(.info, "\(model.name): downloading about \(LabFormat.bytes(model.approximateDownloadBytes))")
        let started = Date()
        let tenths = LabDownloadTenths()
        _ = try await LabHuggingFace.download(model) { [weak self] fraction in
            guard let tenth = tenths.crossed(fraction) else { return }
            Task { @MainActor in
                self?.append(.info, "\(model.name): downloaded \(tenth * 10)%")
            }
        }
        append(.good, "\(model.name): downloaded in \(LabFormat.duration(Date().timeIntervalSince(started)))")
    }

    /// Replay a recording through the real streaming transcriber in ~100 ms
    /// chunks, the way the live mic tap feeds it (mirrors `AudioReplayTests` and
    /// `EvalRunner`) — windowing keys off absolute sample position, so a file
    /// reproduces live streaming exactly.
    nonisolated static func transcribe(_ url: URL) async -> (text: String, ms: Int)? {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0 else { return nil }
        let transcriber = FluidAudioStreamingTranscriber()
        let format = file.processingFormat
        let chunk = AVAudioFrameCount(format.sampleRate * 0.1)
        let started = Date()
        do {
            try await transcriber.prepareModels { _ in }
            try await transcriber.start { _ in }
            while file.framePosition < file.length {
                let remaining = AVAudioFrameCount(file.length - file.framePosition)
                guard let buffer = AVAudioPCMBuffer(
                    pcmFormat: format, frameCapacity: min(chunk, remaining)) else { break }
                try file.read(into: buffer, frameCount: min(chunk, remaining))
                try await transcriber.append(buffer)
            }
            let text = try await transcriber.stop()
            return (text, Int(Date().timeIntervalSince(started) * 1000))
        } catch {
            return nil
        }
    }

    private func append(_ kind: LabLogLine.Kind, _ text: String) {
        log.append(LabLogLine(at: Date(), kind: kind, text: text))
        if log.count > logLimit { log.removeFirst(log.count - logLimit) }
    }
}

/// Which tenth of a download was last reported. A class with a lock because the
/// progress callback arrives on whatever queue the hub client uses.
final class LabDownloadTenths: @unchecked Sendable {
    private let lock = NSLock()
    private var reported = 0

    /// The new tenth when `fraction` crosses one, else nil. Never repeats one and
    /// never goes backward, whatever order the callbacks land in.
    func crossed(_ fraction: Double) -> Int? {
        let tenth = Int((min(1, max(0, fraction)) * 10).rounded(.down))
        return lock.withLock {
            guard tenth > reported else { return nil }
            reported = tenth
            return tenth
        }
    }
}

/// The app's non-LLM pipeline, in the app's order.
///
/// **Kept in one place because it has drifted before.** `DictationViewModel` and
/// `EvalRunner` each spell this sequence out, and the ordering rule (self-correction
/// collapse *before* ITN, so "twenty no forty dollars" is not digitised twice) only
/// holds if every copy agrees. The lab reads through here, and `EvalRunner` now does
/// too, so there is one list to keep in step with the view model instead of two.
enum LabDeterministicPipeline {
    /// Empty glossary and always-on ITN + filler removal, so a bench result does
    /// not move because the user edited their vocabulary.
    static func run(_ raw: String) -> String {
        let spaced = TranscriptSpacingRepair.repair(raw)
        let corrected = SelfCorrectionCollapser.collapse(spaced)
        let itn = DeterministicITN.normalize(corrected)
        let deFillered = FillerWordFilter.clean(itn)
        return VocabularyPostProcessor.apply(deFillered, glossary: [])
    }
}
