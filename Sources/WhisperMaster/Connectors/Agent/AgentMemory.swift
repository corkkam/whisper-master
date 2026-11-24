import Foundation
import Observation

/// One thing the user asked the assistant to remember ("my manager is Priya").
///
/// **The `Codable` is hand-written, like `Note`'s.** The file is on the user's disk
/// and the store swallows nothing silently, but a bare non-optional field added later
/// would make the synthesized decode throw `keyNotFound` on every fact already saved.
/// Every field added from here on takes `decodeIfPresent` and a default.
struct AgentMemoryFact: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var text: String
    var createdAt: Date

    init(id: UUID = UUID(), text: String, createdAt: Date = Date()) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id, text, createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}

/// What the assistant was asked to remember, on this Mac, for the signed-in account.
///
/// **A fact is written only because the user said so** (`remember`, or the Settings
/// list), never extracted from a conversation, and never synced. Per account, the
/// way `UsageStore` is: one file per account at `Application Support/WhisperMaster/
/// Memory/<userId>.json`, and `AppDelegate` activates it on sign-in and deactivates it
/// on sign-out. With no account active nothing can be added, so a run that outlives a
/// sign-out cannot leave a fact for the next account.
///
/// The facts go into the command prompt (`promptBlock`) as the user's own words. They
/// do not taint a run: the only way in is the user's speech, and a run that read
/// outside text cannot add one (`LocalToolRunner.runMemory`).
@MainActor
@Observable
final class AgentMemoryStore {
    static let maxFacts = 50
    static let maxFactLength = 200
    /// Characters the prompt block may take, heading included.
    static let maxPromptLength = 1_500
    static let promptHeading = "Things the user asked you to remember:"

    /// Oldest first.
    private(set) var facts: [AgentMemoryFact] = []
    private(set) var currentUserID: String?

    /// When false, changes stay in memory. Set by the headless snapshot renderer.
    var persistenceEnabled = true

    /// True when the account's file existed but could not be read. While set, nothing
    /// is added or written, because writing would replace the file with what landed since.
    private var loadFailed = false

    /// Injectable so a test can redirect the per-account files into a temp folder.
    private let fileURLForUser: (String) -> URL

    init(fileURLForUser: @escaping (String) -> URL = AgentMemoryStore.fileURL(forUserID:)) {
        self.fileURLForUser = fileURLForUser
    }

    /// `…/WhisperMaster/Memory/<userId>.json`. The id is sanitized before it reaches a path.
    nonisolated static func fileURL(forUserID userID: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let safe = String(userID.map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" ? $0 : "_" })
        return base.appendingPathComponent("WhisperMaster/Memory/\(safe).json", isDirectory: false)
    }

    var hasFacts: Bool { !facts.isEmpty }

    // MARK: - Per-account activation

    /// Idempotent: the 0.5 s auth reconcile tick calls it freely.
    func activate(userID: String) {
        guard !userID.isEmpty, userID != currentUserID else { return }
        currentUserID = userID
        facts = []
        loadFromDisk()
    }

    /// Sign-out: drop what is loaded. The file stays on disk for when the account returns.
    func deactivate() {
        guard currentUserID != nil else { return }
        currentUserID = nil
        facts = []
        loadFailed = false
    }

    // MARK: - Changes

    enum AddOutcome: Equatable {
        case added(AgentMemoryFact)
        case alreadyKnown
        case empty
        /// The length that was refused. A long fact is refused, never cut.
        case tooLong(Int)
        case full
        /// No account is active, or its file could not be read.
        case unavailable
    }

    func add(_ text: String) -> AddOutcome {
        guard currentUserID != nil, !loadFailed else { return .unavailable }
        let text = Self.oneLine(text)
        guard !text.isEmpty else { return .empty }
        guard text.count <= Self.maxFactLength else { return .tooLong(text.count) }
        if facts.contains(where: { $0.text.caseInsensitiveCompare(text) == .orderedSame }) {
            return .alreadyKnown
        }
        guard facts.count < Self.maxFacts else { return .full }
        let fact = AgentMemoryFact(text: text)
        facts.append(fact)
        persist()
        return .added(fact)
    }

    /// The Settings delete button.
    func remove(id: UUID) {
        guard facts.contains(where: { $0.id == id }) else { return }
        facts.removeAll { $0.id == id }
        persist()
    }

    /// Remove every fact that holds all the words of `query`, and return them. Words
    /// are `ToolPackRouter.keywords` (lowercase, three letters or more, a plural `s`
    /// dropped). A query with no such word removes nothing.
    func forget(matching query: String) -> [AgentMemoryFact] {
        let words = ToolPackRouter.keywords(query)
        guard !words.isEmpty, !loadFailed else { return [] }
        let removed = facts.filter { words.isSubset(of: ToolPackRouter.keywords($0.text)) }
        guard !removed.isEmpty else { return [] }
        facts.removeAll { fact in removed.contains { $0.id == fact.id } }
        persist()
        return removed
    }

    /// A fact is one line: the prompt block is one line per fact.
    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: - The prompt

    /// The block the command prompt carries, or nil with no facts. Newest first, whole
    /// facts only, and never more than `maxPromptLength` characters: a fact that does
    /// not fit is left out, not cut. The rest stay in Settings.
    var promptBlock: String? {
        var lines: [String] = []
        var length = Self.promptHeading.count
        for fact in facts.reversed() {
            let line = "- " + fact.text
            guard length + 1 + line.count <= Self.maxPromptLength else { continue }
            lines.append(line)
            length += 1 + line.count
        }
        return lines.isEmpty ? nil : ([Self.promptHeading] + lines).joined(separator: "\n")
    }

    // MARK: - Disk

    private struct Snapshot: Codable {
        var facts: [AgentMemoryFact]

        enum CodingKeys: String, CodingKey {
            case facts
        }

        init(facts: [AgentMemoryFact]) {
            self.facts = facts
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            facts = try c.decodeIfPresent([AgentMemoryFact].self, forKey: .facts) ?? []
        }
    }

    private func persist() {
        guard persistenceEnabled, let userID = currentUserID, !loadFailed else { return }
        let url = fileURLForUser(userID)
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(Snapshot(facts: facts)).write(to: url, options: .atomic)
        } catch {
            Log.agents.error("memory persist failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func loadFromDisk() {
        loadFailed = false
        guard let userID = currentUserID else { return }
        let url = fileURLForUser(userID)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let snapshot = try decoder.decode(Snapshot.self, from: try Data(contentsOf: url))
            facts = snapshot.facts.filter { !$0.text.isEmpty }
        } catch {
            Log.agents.error("memory load failed: \(error.localizedDescription, privacy: .public)")
            loadFailed = true
        }
    }
}

/// The two memory tools. Both are `.local`: the facts are the user's own on-device data
/// and the chord is the consent, so no card. What stands in for the card is the refusal
/// in a run that read outside text (`LocalToolRunner.runMemory`).
///
/// Not in `LocalToolCatalog.all`, which the tool benches share. `CommandAgentService`
/// adds them when it has a store, and `forget` only when there is a fact to forget.
enum AgentMemoryCatalog {
    static let remember = ToolDescriptor(
        name: "remember",
        summary: "Save a fact about the user for later commands. Use only when the user says \"remember that ...\". \"Remember to do something\" is a reminder, not this.",
        access: .local,
        capability: nil,
        targetArg: nil,
        parameters: [
            ToolParameter("fact", isRequired: true,
                          description: "The fact, in the user's own words. 200 characters at most."),
        ])

    static let forget = ToolDescriptor(
        name: "forget",
        summary: "Remove a fact the user asked you to remember. Use only when the user says to forget it.",
        access: .local,
        capability: nil,
        targetArg: nil,
        parameters: [
            ToolParameter("fact", isRequired: true,
                          description: "Words from the fact to remove."),
        ])

    static let names: Set<String> = [remember.name, forget.name]

    static func descriptor(named name: String) -> ToolDescriptor? {
        [remember, forget].first { $0.name == name }
    }

    static func offered(hasFacts: Bool) -> [ToolDescriptor] {
        hasFacts ? [remember, forget] : [remember]
    }
}

extension LocalToolRunner {
    /// Runs `remember` and `forget`.
    ///
    /// **A run that read outside text (`Taint`) refuses both.** Memory feeds every later
    /// prompt, and a fact the model was talked into saving would steer a later
    /// recipient or a later write with no card in the way. Forgetting is refused too:
    /// planted text must not be able to wipe what the user saved.
    func runMemory(_ call: ToolCall) -> (ToolResult, Effect?) {
        guard !taint.isSet else {
            return (.failure("Memory was not changed. This run read text from outside "
                + "(a selection, mail or a message), and that text could plant a fact. "
                + "Tell the user, and ask them to say it again as a new command."), nil)
        }
        guard let memory else {
            return (.failure("Memory is not available right now. Nothing was changed."), nil)
        }
        let fact = call.arguments["fact"] ?? ""

        if call.tool == AgentMemoryCatalog.forget.name {
            let removed = memory.forget(matching: fact)
            guard !removed.isEmpty else {
                return (.failure("No remembered fact has those words. Nothing was removed."), nil)
            }
            let text = "Forgot \(removed.count) fact\(removed.count == 1 ? "" : "s"): "
                + removed.map(\.text).joined(separator: "; ")
            return (ToolResult(ok: true, text: text, instanceLabels: []), .memoryChanged)
        }

        switch memory.add(fact) {
        case .added(let added):
            return (ToolResult(ok: true, text: "Remembered: \(added.text)", instanceLabels: []),
                    .memoryChanged)
        case .alreadyKnown:
            return (ToolResult(ok: true, text: "That is already remembered.", instanceLabels: []), nil)
        case .empty:
            return (.failure("remember needs a non-empty fact."), nil)
        case .tooLong(let length):
            return (.failure("That fact is \(length) characters. The limit is "
                + "\(AgentMemoryStore.maxFactLength). Nothing was saved. Ask the user for a shorter fact."), nil)
        case .full:
            return (.failure("Memory is full (\(AgentMemoryStore.maxFacts) facts). Nothing was saved. "
                + "Ask the user to forget a fact first."), nil)
        case .unavailable:
            return (.failure("Memory is not available right now. Nothing was saved."), nil)
        }
    }
}
