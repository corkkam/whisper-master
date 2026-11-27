import Foundation
import Observation

/// The Crew tasks this app starts: `crew run` in a Crew project, the question a run
/// stopped on, and the answer that continues it. The rail (`CrewAgents`) shows the
/// agents at work; this class owns the runs.
///
/// - One run at a time, because the crew has one writer.
/// - A run that ends with `needs_approval` becomes `pending` and raises a choice card
///   (`ask`). **Approve and continue**, or a task handed off while the run waits, starts
///   the same task again with `--task-id <id> --approved`, the spoken answer added to
///   the task text. **Not now** drops it. **Skip** only hides the card; a click on a
///   face shows it again.
/// - Every other result goes to `onResult`, which shows the final text on the notch
///   and reads its first sentence aloud.
///
/// The task goes to `crew run` in a file (`--file`), never on a command line, and the
/// child gets a fixed environment, never this app's own.
@MainActor
@Observable
final class CrewRuns {
    struct Run: Equatable, Sendable {
        var task: String
        var project: String
        var taskID: String?
    }

    /// What one `crew run` printed: the final text on stdout, the `crew:` lines on stderr.
    struct Output: Equatable, Sendable {
        var status: Int32
        var stdout: String
        var stderr: String
    }

    typealias Launcher = @Sendable (_ arguments: [String], _ folder: String,
                                    _ environment: [String: String]) async -> Output

    nonisolated static let approve = "Approve and continue"
    nonisolated static let notNow = "Not now"
    nonisolated static let busy = "The Crew is still on the last task, so this one wasn't sent."
    nonisolated static let notInstalled = "Crew is not installed on this Mac, so nothing was sent."

    /// The run in flight.
    private(set) var running: Run?
    /// The run that stopped on a question and waits for the owner.
    private(set) var pending: Run?
    /// The card on the notch for `pending`. Nil while hidden.
    private(set) var ask: AgentAsk?
    /// The last final text, for a click on a face.
    private(set) var lastResult: String?

    /// Show a final text: the task, the text, and where it came from.
    @ObservationIgnored var onResult: ((_ task: String, _ text: String, _ from: String) -> Void)?
    /// The run's work, so a test can wait for it.
    @ObservationIgnored private(set) var job: Task<Void, Never>?

    @ObservationIgnored private var card: AgentAsk?
    @ObservationIgnored private let crewHome: URL
    @ObservationIgnored private let home: URL
    @ObservationIgnored private let launch: Launcher

    init(crewHome: URL = CrewAgents.defaultHome(),
         home: URL = FileManager.default.homeDirectoryForCurrentUser,
         launch: @escaping Launcher = { await CrewRuns.runProcess($0, $1, $2) }) {
        self.crewHome = crewHome
        self.home = home
        self.launch = launch
    }

    private var shim: URL { crewHome.appendingPathComponent("bin/crew") }

    // MARK: Actions

    /// Start `task` in `project`, or, while a run waits, send it as the answer. Nil
    /// when it went, else why not.
    func start(_ task: String, project: String) -> String? {
        let text = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "The task is empty." }
        guard running == nil else { return Self.busy }
        guard FileManager.default.isExecutableFile(atPath: shim.path) else { return Self.notInstalled }
        if let waiting = pending {
            begin(waiting, answer: text)
        } else {
            begin(Run(task: text, project: project), answer: nil)
        }
        return nil
    }

    /// Answer the card. An empty selection is Skip: the run keeps waiting.
    func answer(_ choice: AgentChoice, selected: [String]) {
        guard choice.requestID == ask?.requestID, let waiting = pending else { return }
        ask = nil
        switch selected.first {
        case Self.approve?:
            if running == nil { begin(waiting, answer: nil) }
        case Self.notNow?:
            pending = nil
            card = nil
        default:
            break
        }
    }

    /// A click on a face: the waiting question again, else the last result.
    func showLast() {
        if pending != nil, let card {
            ask = card
        } else if let lastResult, let onResult {
            onResult("", lastResult, "Crew")
        }
    }

    // MARK: One run

    private func begin(_ run: Run, answer: String?) {
        pending = nil
        ask = nil
        card = nil
        running = run
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("crew-task-\(UUID().uuidString).txt")
        let text = Self.taskText(run, answer: answer)
        do {
            try text.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            finish(run, Output(status: -1, stdout: "", stderr: "crew: cannot write the task file"))
            return
        }
        let arguments = Self.arguments(shim: shim.path, taskFile: file.path, taskID: run.taskID)
        let environment = Self.environment(home: home, claude: ConnectedTool.locate(.claudeCode, home: home))
        let launch = self.launch
        job = Task { [weak self] in
            let output = await launch(arguments, run.project, environment)
            try? FileManager.default.removeItem(at: file)
            self?.finish(run, output)
        }
    }

    private func finish(_ run: Run, _ output: Output) {
        running = nil
        let result = CrewResult(output: output.stdout)
        let from = "Crew · \(AgentSession.repoName(fromPath: run.project))"
        if result.word == "needs_approval", let id = result.taskID ?? run.taskID {
            let waiting = Run(task: run.task, project: run.project, taskID: id)
            let plan = try? String(contentsOfFile: run.project + "/.crew/tasks/\(id)/plan.md", encoding: .utf8)
            // A gate plan asks an open question; a fast-path plan only states its goal.
            let question = plan.flatMap { Self.section("Open question", inPlan: $0) }
                ?? plan.flatMap { Self.section("Goal", inPlan: $0) }.map { "Approve this plan?\n" + $0 }
                ?? Self.firstParagraph(result.text)
                ?? "The Crew has a plan for this task and waits for your approval."
            pending = waiting
            card = Self.card(for: waiting, question: question, from: from)
            ask = card
            return
        }
        let text = result.text.isEmpty ? Self.failureLine(output) : result.text
        lastResult = text
        onResult?(run.task, text, from)
    }

    // MARK: Pure parts

    /// The task text for `crew run`. A continued run says it was approved and carries
    /// the owner's answer.
    nonisolated static func taskText(_ run: Run, answer: String?) -> String {
        guard run.taskID != nil else { return run.task }
        var text = run.task + "\n\nThe owner approved this task in the Typing.sucks app."
        if let answer { text += "\nThe owner's answer to the open question: " + answer }
        return text
    }

    nonisolated static func arguments(shim: String, taskFile: String, taskID: String?) -> [String] {
        var arguments = [shim, "run", "--quiet", "--file", taskFile]
        if let taskID { arguments += ["--task-id", taskID, "--approved"] }
        return arguments
    }

    /// The child's whole environment. An app started from Finder has launchd's PATH,
    /// which has neither `claude` nor the project tools, and this app's own
    /// environment may carry keys a terminal set.
    nonisolated static func environment(
        home: URL, claude: URL?,
        inherited: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = ["HOME": home.path, "PATH": path(home: home),
                           "LANG": inherited["LANG"] ?? "en_US.UTF-8"]
        for key in ["USER", "LOGNAME", "SHELL", "TMPDIR"] {
            if let value = inherited[key] { environment[key] = value }
        }
        if let claude { environment["CREW_CLAUDE_BIN"] = claude.path }
        return environment
    }

    nonisolated static func path(home: URL) -> String {
        var folders = [".crew/bin", ".local/bin", "Library/pnpm/bin"].map { home.appendingPathComponent($0).path }
        // shortcut: the newest nvm Node, not the user's nvm default; read the login
        // shell's PATH if a project needs another Node.
        let nvm = home.appendingPathComponent(".nvm/versions/node")
        if let newest = (try? FileManager.default.contentsOfDirectory(atPath: nvm.path))?
            .filter({ $0.hasPrefix("v") })
            .max(by: { $0.compare($1, options: .numeric) == .orderedAscending }) {
            folders.append(nvm.appendingPathComponent(newest).appendingPathComponent("bin").path)
        }
        folders += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        return folders.joined(separator: ":")
    }

    /// One `## <name>` section of a task's `plan.md`, or nil when it is missing, empty
    /// or says none.
    nonisolated static func section(_ name: String, inPlan plan: String) -> String? {
        var lines: [String] = []
        var inside = false
        for line in plan.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                if inside { break }
                inside = line.trimmingCharacters(in: .whitespaces).lowercased() == "## " + name.lowercased()
                continue
            }
            if inside { lines.append(line) }
        }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let bare = text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return text.isEmpty || bare == "none" || bare == "none yet" ? nil : text
    }

    /// The first paragraph of a final text, without the terminal commands the lead
    /// prints for a person at a terminal.
    nonisolated static func firstParagraph(_ text: String) -> String? {
        let kept = text.components(separatedBy: "\n").filter { !$0.contains("crew run --task-id") }
        let paragraph = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\n\n").first?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (paragraph?.isEmpty ?? true) ? nil : paragraph
    }

    /// The last `crew:` line, for a run that printed no final text (stopped, over
    /// budget, refused before it started).
    nonisolated static func failureLine(_ output: Output) -> String {
        let line = output.stderr.components(separatedBy: "\n").last { $0.hasPrefix("crew: ") }
        if let line { return "The Crew stopped: " + line.dropFirst("crew: ".count) }
        return "The Crew run ended with no answer (exit \(output.status))."
    }

    /// The receiver's name on the approval card and in the tool result.
    nonisolated static func destination(project: String) -> String {
        "the Crew in \(AgentSession.repoName(fromPath: project))"
    }

    nonisolated static func card(for run: Run, question: String, from: String) -> AgentAsk {
        .choice(AgentChoice(
            requestID: "crew:" + (run.taskID ?? ""),
            questions: [.init(text: question, header: "Crew", multiSelect: false,
                              options: [approve, notNow])],
            context: from + " · or answer with fn + control",
            isShed: true))
    }

    // MARK: The process

    /// Run `crew run` to its end. Both pipes are read to the end before the wait, or
    /// a full pipe would block the child.
    nonisolated static func runProcess(_ arguments: [String], _ folder: String,
                                       _ environment: [String: String]) async -> Output {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: arguments[0])
                process.arguments = Array(arguments.dropFirst())
                process.currentDirectoryURL = URL(fileURLWithPath: folder)
                process.environment = environment
                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: Output(
                        status: -1, stdout: "", stderr: "crew: \(error.localizedDescription)"))
                    return
                }
                let errData = PipeReader(err.fileHandleForReading)
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: Output(
                    status: process.terminationStatus,
                    stdout: String(decoding: outData, as: UTF8.self),
                    stderr: String(decoding: errData.wait(), as: UTF8.self)))
            }
        }
    }
}

/// Reads one pipe to its end on its own thread.
private final class PipeReader: @unchecked Sendable {
    private var data = Data()
    private let done = DispatchSemaphore(value: 0)

    init(_ handle: FileHandle) {
        DispatchQueue.global(qos: .utility).async {
            self.data = handle.readDataToEndOfFile()
            self.done.signal()
        }
    }

    func wait() -> Data {
        done.wait()
        return data
    }
}

/// The last `{"crew_result": …}` line of a run's final text, and the text without it.
struct CrewResult: Equatable, Sendable {
    var word: String?
    var taskID: String?
    var text: String

    init(output: String) {
        var lines = output.components(separatedBy: "\n")
        if let index = lines.lastIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("{\"crew_result\"")
        }) {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            if let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] {
                word = object["crew_result"] as? String
                taskID = object["task_id"] as? String
            }
            lines.remove(at: index)
        }
        text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
