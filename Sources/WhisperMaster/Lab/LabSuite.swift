import Foundation

#if SWIFT_PACKAGE
// SwiftPM builds the scorer as its own module; the Xcode app target compiles the
// same files straight into the app (see project.yml), where there is nothing to
// import. One copy of the code either way — see Lab/CLAUDE.md.
import EvalScoreKit
#endif

/// The benches the lab can run. Each one already exists somewhere in this repo;
/// the lab is where they become runnable per model, against a real load, with the
/// memory and latency recorded.
enum LabSuite: String, CaseIterable, Identifiable, Codable, Sendable {
    /// `cases.jsonl` through the shipped light-cleanup prompt.
    case cleanup
    /// The same cases through the heavier rephrase prompt.
    case polish
    /// `flow-cases.jsonl` — the app-aware destinations (slack, email, code).
    case destinations
    /// The 16 spoken commands from `AgentToolEval`, scored on whether the model
    /// emitted a parseable call to the right tool.
    case tools
    /// The committed recordings, replayed through the real streaming ASR, scored
    /// on word error rate and then cleaned.
    case audio

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cleanup: return "Cleanup"
        case .polish: return "Polish"
        case .destinations: return "Destinations"
        case .tools: return "Tool calling"
        case .audio: return "Audio"
        }
    }

    var detail: String {
        switch self {
        case .cleanup: return "The shipped light-cleanup prompt over every text case."
        case .polish: return "The heavier rephrase prompt, where the guard loosens."
        case .destinations: return "Slack, email and code formatting."
        case .tools: return "Does the model call the right tool, first turn."
        case .audio: return "Real recordings through the streaming ASR, then cleanup."
        }
    }

    /// A suite that needs the model to hold a conversation and emit a tool call
    /// can only be run by a model that can. S1-mini in this slot returns prose,
    /// nothing parses, and the bench would report a normalizer as a broken
    /// tool-caller rather than as the wrong tool for the job.
    var requiredRole: LabRole {
        switch self {
        case .tools: return .assistant
        default: return .cleanup
        }
    }

    /// The cleanup prompt this suite drives, where there is one. `destinations`
    /// takes its target from each case, so it has none of its own.
    var fixedTarget: CleanupTarget? {
        switch self {
        case .cleanup, .audio: return .light
        case .polish: return .polish
        case .destinations, .tools: return nil
        }
    }

    /// Repo-relative case file, for the suites that read one.
    var casesRelativePath: String? {
        switch self {
        case .cleanup, .polish: return "eval/text-cleanup/cases.jsonl"
        case .destinations: return "eval/text-cleanup/flow-cases.jsonl"
        case .tools, .audio: return nil
        }
    }
}

/// One thing a suite asks a model to do.
struct LabCase: Identifiable, Sendable {
    enum Input: Sendable {
        /// Text injected at the deterministic stage, exactly like a finished ASR.
        case text(String)
        /// A recording replayed through the real streaming transcriber, with the
        /// words that were actually said.
        case audio(url: URL, reference: String)
        /// A spoken command and the tool a correct run calls.
        case spokenCommand(String, expectedTool: String)
    }

    let id: String
    let category: String
    let input: Input
    let target: CleanupTarget
    let mustContain: [String]
    let mustNotContain: [String]

    var inputKind: String {
        switch input {
        case .text: return "text"
        case .audio: return "audio"
        case .spokenCommand: return "tool"
        }
    }

    /// The prompt text as it reads in the UI, whatever kind of case this is.
    var prompt: String {
        switch input {
        case .text(let text): return text
        case .audio(let url, _): return url.lastPathComponent
        case .spokenCommand(let spoken, _): return spoken
        }
    }
}

/// A loaded suite: the cases to run, plus the `EvalCase` each text row was
/// decoded from.
///
/// The sources are kept because **`Scorer` is the mechanical arbiter and it takes
/// an `EvalCase`**. Re-deriving pass/fail from the copies in `LabCase` would be a
/// second implementation of the eval's own rules, which is exactly the drift the
/// offline pipeline avoided by never porting the guard. Not `Sendable` — it never
/// leaves the main actor; only the `LabCase` values cross into the model actor.
struct LabSuiteCases {
    let cases: [LabCase]
    let sources: [String: EvalCase]
}

/// Loads a suite's cases off disk. Every failure is reported rather than silently
/// producing a shorter suite: a bench that quietly ran 40 of 92 cases and called
/// it 100% is worse than one that refuses to start.
enum LabSuiteLoader {
    enum LoadError: LocalizedError {
        case noRepo
        case missingFile(String)
        case unreadable(String, String)
        case empty(String)

        var errorDescription: String? {
            switch self {
            case .noRepo:
                return "Point the lab at your whisper-master checkout to load the case files."
            case .missingFile(let path):
                return "Missing \(path) in the checkout."
            case .unreadable(let path, let reason):
                return "Could not read \(path): \(reason)"
            case .empty(let path):
                return "\(path) holds no cases."
            }
        }
    }

    /// The 16 spoken commands the tool-calling bench runs. **The one source of
    /// truth** — `AgentToolEval` reads this list too, so the terminal bench and
    /// the in-app one can never measure different things.
    static let toolCases: [(spoken: String, expectedTool: String)] = [
        ("what's on my calendar tomorrow", "list_calendar_events"),
        ("send a slack to the ops channel saying I'll be late", "send_message"),
        ("remind me to call mom at 6", "create_reminder"),
        ("add a dentist appointment to my personal calendar friday at 3", "create_calendar_event"),
        ("what are my unread emails", "list_mail"),
        ("what tasks are assigned to me", "list_tasks"),
        ("show me my recent messages", "list_messages"),
        ("make a note that the wifi password is basalt harbor nineteen", "create_note"),
        ("what files are in my drive", "list_files"),
        ("what accounts do i have connected", "list_connectors"),
        ("post to the eng channel that the build is green", "send_message"),
        ("remind me to submit the report tomorrow morning", "create_reminder"),
        // Messier, dictation-shaped: run-ons, a self-correction, an implicit time,
        // and a bare thought with nothing to act on. These are where two prompt
        // shapes are more likely to separate than on the clean commands above.
        ("uh can you check what meetings I've got going on later today", "list_calendar_events"),
        ("message the design channel no wait the ops channel and tell them the deploy is done", "send_message"),
        ("book thirty minutes with the personal calendar for a review tomorrow at four", "create_calendar_event"),
        ("just jot down that I should follow up with the vendor about pricing", "create_note"),
    ]

    static func load(_ suite: LabSuite, repoRoot: URL?) throws -> LabSuiteCases {
        switch suite {
        case .tools:
            let cases = toolCases.map {
                LabCase(id: "tool-" + slug($0.spoken), category: "tools",
                        input: .spokenCommand($0.spoken, expectedTool: $0.expectedTool),
                        target: .light, mustContain: [], mustNotContain: [])
            }
            return LabSuiteCases(cases: cases, sources: [:])
        case .audio:
            guard let repoRoot else { throw LoadError.noRepo }
            return LabSuiteCases(cases: try audioCases(repoRoot: repoRoot), sources: [:])
        case .cleanup, .polish, .destinations:
            guard let repoRoot else { throw LoadError.noRepo }
            return try textCases(suite, repoRoot: repoRoot)
        }
    }

    // MARK: - Text

    private static func textCases(_ suite: LabSuite, repoRoot: URL) throws -> LabSuiteCases {
        let relative = suite.casesRelativePath!
        let url = repoRoot.appendingPathComponent(relative)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LoadError.missingFile(relative)
        }
        let evalCases: [EvalCase]
        do {
            evalCases = try EvalCase.load(url.path)
        } catch {
            throw LoadError.unreadable(relative, error.localizedDescription)
        }
        var out: [LabCase] = []
        var sources: [String: EvalCase] = [:]
        for evalCase in evalCases {
            guard let text = evalCase.inputText else { continue }
            for target in targets(for: suite, declaredBy: evalCase) {
                // A destinations case can run against three destinations, so the
                // target joins the id: three rows sharing one id would collide in
                // every table and comparison downstream.
                let id = suite.fixedTarget == nil ? "\(evalCase.id)/\(target.rawValue)" : evalCase.id
                out.append(LabCase(
                    id: id,
                    category: evalCase.category,
                    input: .text(text), target: target,
                    mustContain: evalCase.mustContain,
                    mustNotContain: evalCase.mustNotContain))
                sources[id] = evalCase
            }
        }
        guard !out.isEmpty else { throw LoadError.empty(relative) }
        return LabSuiteCases(cases: out, sources: sources)
    }

    /// Which cleanup targets a case contributes. A fixed-target suite runs every
    /// case once; `destinations` runs each case against the destinations it
    /// declares, so one case can become three rows.
    private static func targets(for suite: LabSuite, declaredBy evalCase: EvalCase) -> [CleanupTarget] {
        if let fixed = suite.fixedTarget { return [fixed] }
        let declared = evalCase.targets.compactMap(CleanupTarget.init(rawValue:))
        return declared.isEmpty ? [.light] : declared
    }

    // MARK: - Audio

    /// The committed recordings plus the words that were read into them.
    /// `paragraphs.md` names each file as a `.wav` while the committed fixtures
    /// are `.m4a`, so files are matched on the stem, not the extension.
    static func audioCases(repoRoot: URL) throws -> [LabCase] {
        let dir = repoRoot.appendingPathComponent("Tests/WhisperMasterTests/Fixtures/audio", isDirectory: true)
        let markdownURL = dir.appendingPathComponent("paragraphs.md")
        guard let markdown = try? String(contentsOf: markdownURL, encoding: .utf8) else {
            throw LoadError.missingFile("Tests/WhisperMasterTests/Fixtures/audio/paragraphs.md")
        }
        let references = parseReferences(markdown)
        let audioExtensions: Set<String> = ["wav", "m4a", "caf", "mp3", "aiff", "aif"]
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { audioExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var out: [LabCase] = []
        for file in files {
            let stem = file.deletingPathExtension().lastPathComponent
            guard let reference = references[stem] else { continue }
            out.append(LabCase(id: stem, category: "audio",
                               input: .audio(url: file, reference: reference),
                               target: .light, mustContain: [], mustNotContain: []))
        }
        guard !out.isEmpty else { throw LoadError.empty("Fixtures/audio") }
        return out
    }

    /// Pull `**File: \`paragraph-1.wav\`**` headers and the `>` blockquote under
    /// each one out of the fixtures' README. Pure, so it is tested on a literal.
    static func parseReferences(_ markdown: String) -> [String: String] {
        var out: [String: String] = [:]
        var currentStem: String?
        var buffer: [String] = []

        func flush() {
            guard let stem = currentStem else { return }
            let text = buffer.joined(separator: " ")
                .replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "(um)", with: "um")
                .replacingOccurrences(of: "(uh)", with: "uh")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { out[stem] = text }
            currentStem = nil
            buffer = []
        }

        for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("**File:") {
                flush()
                if let start = line.firstIndex(of: "`"),
                   let end = line[line.index(after: start)...].firstIndex(of: "`") {
                    let name = String(line[line.index(after: start) ..< end])
                    currentStem = (name as NSString).deletingPathExtension
                }
            } else if line.hasPrefix(">") {
                buffer.append(line.dropFirst().trimmingCharacters(in: .whitespaces))
            } else if line.hasPrefix("##") {
                flush()
            }
        }
        flush()
        return out
    }

    private static func slug(_ text: String) -> String {
        let allowed = text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(allowed).split(separator: "-").prefix(4).joined(separator: "-")
    }
}
