import AppKit
import Foundation

/// Run a lab bench from the terminal, with no window and nobody clicking.
///
/// ```
/// WM_LAB_BENCH=cleanup WM_LAB_MODELS=s1-mini-4bit,qwen3-4b-instruct-2507-4bit \
///   open -a "/Applications/Whisper Master Dev.app"
/// ```
///
/// **Why this exists rather than "open the page and press Run".** MLX inference
/// cannot run under `swift test` (its Metal shaders only compile through
/// xcodebuild), so the only way to prove the bench end to end is inside a real
/// built app — and a bench that can only be started by a person clicking is a
/// bench that never runs twice the same way. Same env-hook posture as
/// `SnapshotMode`, `EvalRunner` and `AgentToolEval`, and like them it is
/// dev-only: it refuses on any channel but `dev`.
///
/// Launch through LaunchServices (`open`) with the environment handed over by
/// `launchctl setenv`, exactly as `run-eval.sh` does — a directly-exec'd bundle
/// fails TCC's Info.plist lookup and the mesh Bluetooth scan hard-crashes.
///
/// Writes the run to the normal history (so the page shows it afterwards), plus
/// `results.json` in the offline scorer's shape, and prints a summary table.
@MainActor
enum LabHeadlessBench {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["WM_LAB_BENCH"] != nil
    }

    static func runIfRequested() async {
        let environment = ProcessInfo.processInfo.environment
        guard let suiteName = environment["WM_LAB_BENCH"] else { return }
        guard FeatureFlags.modelLabAvailable else {
            print("WM_LAB_BENCH: the Model Lab is dev-only, and this is a \(ReleaseChannel.current.rawValue) build.")
            return exit(2)
        }
        guard let suite = LabSuite(rawValue: suiteName) else {
            print("WM_LAB_BENCH: unknown suite '\(suiteName)'. One of: "
                + LabSuite.allCases.map(\.rawValue).joined(separator: ", "))
            return exit(2)
        }

        let requested = (environment["WM_LAB_MODELS"] ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let models = requested.compactMap(LabCatalog.model(id:))
        let unknown = requested.filter { LabCatalog.model(id: $0) == nil }
        guard unknown.isEmpty else {
            print("WM_LAB_BENCH: unknown model id(s): \(unknown.joined(separator: ", "))")
            print("Known: \(LabCatalog.all.map(\.id).joined(separator: ", "))")
            return exit(2)
        }
        guard !models.isEmpty else {
            print("WM_LAB_BENCH: set WM_LAB_MODELS to a comma-separated list of catalogue ids.")
            return exit(2)
        }
        // Not silently dropped: a model that cannot run the suite would otherwise
        // score zero for a reason that is not about the model.
        let ineligible = models.filter { !$0.supports(suite.requiredRole) }
        guard ineligible.isEmpty else {
            print("WM_LAB_BENCH: \(ineligible.map(\.name).joined(separator: ", ")) cannot run the "
                + "\(suite.title.lowercased()) suite (needs a \(suite.requiredRole.rawValue) model).")
            return exit(2)
        }

        let controller = LabController(load: true)
        let limit = environment["WM_LAB_LIMIT"].flatMap(Int.init)
        print("Model Lab bench: \(suite.title), \(models.map(\.name).joined(separator: " vs "))")
        print("Machine: \(LabMachine.summary), app \(AppInfo.version)")

        controller.runner.start(suite: suite, models: models,
                                repoRoot: controller.repoRoot, limit: limit)
        if let failure = controller.runner.failure {
            print("WM_LAB_BENCH: \(failure)")
            return exit(1)
        }

        var lastLogged = 0
        while controller.runner.isRunning {
            try? await Task.sleep(nanoseconds: 500_000_000)
            let count = controller.runner.log.count
            if count > lastLogged {
                for line in controller.runner.log[lastLogged ..< count] { print("  " + line.text) }
                lastLogged = count
            }
        }
        for line in controller.runner.log.dropFirst(lastLogged) { print("  " + line.text) }

        guard let run = controller.runner.run else { return exit(1) }
        printSummary(run)
        if let out = environment["WM_LAB_OUT"] {
            let written = LabRunExport.write(run: run, to: URL(fileURLWithPath: out, isDirectory: true))
            for url in written { print("wrote \(url.path)") }
        }
        print("Saved as run \(run.id); open Settings, Model Lab to read it.")
        exit(run.models.contains { $0.failure != nil } ? 1 : 0)
    }

    private static func printSummary(_ run: LabRun) {
        print("")
        print(row("model", "score", "p50", "p95", "tok/s", "peak GPU", "load"))
        for result in run.ranked {
            if let failure = result.failure {
                print(row(result.modelName, "FAILED", failure, "", "", "", ""))
                continue
            }
            print(row(
                result.modelName,
                "\(result.passed)/\(result.total)",
                LabFormat.milliseconds(result.p50LatencyMs),
                LabFormat.milliseconds(result.p95LatencyMs),
                String(format: "%.0f", result.medianTokensPerSecond),
                LabFormat.bytes(result.peakGPUBytes),
                LabFormat.milliseconds(result.loadMs)))
        }
        print("")
        for result in run.models where result.failure == nil {
            let failures = result.cases.filter { !$0.passed }
            guard !failures.isEmpty else { continue }
            print("\(result.modelName) missed \(failures.count):")
            for item in failures {
                print("  \(item.id): \(item.reasons.first ?? "failed")")
            }
        }
    }

    private static func row(_ columns: String...) -> String {
        let widths = [30, 8, 9, 9, 7, 10, 9]
        return zip(columns, widths)
            .map { $0.padding(toLength: max($1, $0.count + 1), withPad: " ", startingAt: 0) }
            .joined()
    }

    /// The app is a GUI process with no window here, so the run loop would spin
    /// forever after the bench finishes. Leave, with the exit code saying whether
    /// every model actually ran.
    private static func exit(_ code: Int32) {
        Foundation.exit(code)
    }
}
