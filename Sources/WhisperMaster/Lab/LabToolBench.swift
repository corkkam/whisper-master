import Foundation

/// The tool set and the parse used by both tool-calling benches: the terminal one
/// (`AgentToolEval`, hand-rolled against native) and the lab's per-model suite.
///
/// **One definition, because the two benches must not measure different things.**
/// The mistake this guards against already happened once in the other direction:
/// the terminal bench was pointed at the cleanup slot, so a text normalizer was
/// graded as a failed tool-caller. Sharing the tool set at least means a
/// disagreement between the two benches is about the model, not the setup.
@MainActor
enum LabToolBench {
    /// The tools a real spoken command sees: the on-device local tools plus a
    /// representative spread of connectors, expanded exactly as
    /// `CommandAgentService` does it. Persistence is off, so seeding never touches
    /// a real account file.
    static func buildTools() -> [ToolDescriptor] {
        // `load: false`: the default init reads the user's own connections first, and
        // a bench whose tool list depends on the Mac it runs on is not a bench.
        let store = ConnectorInstanceStore(load: false)
        store.persistenceEnabled = false
        store.add(ConnectorInstance(
            kind: .googleCalendar, label: "Work", identity: "sam@acme.com",
            config: .calendars(identifiers: ["mock-work"], sourceTitle: "Google")))
        store.add(ConnectorInstance(
            kind: .googleCalendar, label: "Personal", identity: "sam@gmail.com",
            config: .calendars(identifiers: ["mock-personal"], sourceTitle: "Google")))
        store.add(ConnectorInstance(kind: .slack, label: "Work chat", identity: "Acme"))
        store.add(ConnectorInstance(kind: .gmail, label: "Gmail", identity: "sam@gmail.com"))
        store.add(ConnectorInstance(kind: .googleDrive, label: "Drive", identity: "sam@gmail.com"))
        store.add(ConnectorInstance(kind: .linear, label: "Linear", identity: "Acme"))
        // `CommandAgentService`'s order, with no selection and an app in front. The pool
        // is past `ToolPackRouter.limit`, so a case sees `packed(_:for:)`, as the app does.
        return LocalToolCatalog.all + AgentMemoryCatalog.offered(hasFacts: false)
            + DeviceToolCatalog.offered(selection: false, frontApp: true)
            + ToolRegistry.available(store: store, includeWrites: true)
    }

    /// The tools one command sees: the app packs the pool per command.
    static func packed(_ setup: Setup, for spoken: String) -> Setup {
        let tools = ToolPackRouter.pack(setup.tools, spoken: spoken)
        return Setup(tools: tools, schemas: ToolSchema.functionSchemas(for: tools), system: setup.system)
    }

    /// Everything a run needs, built once per bench rather than per case.
    struct Setup {
        let tools: [ToolDescriptor]
        let schemas: [String]
        let system: String
    }

    static func setup() -> Setup {
        let tools = buildTools()
        return Setup(tools: tools,
                     schemas: ToolSchema.functionSchemas(for: tools),
                     system: AgentPrompt.commandNative())
    }

    /// The wire messages for one spoken command's first turn.
    static func messages(for spoken: String, setup: Setup) -> [[String: String]] {
        AgentLoop.wireMessages(system: setup.system, [.init(role: .user, text: spoken)])
    }

    /// Which tool the model called, if it called one at all.
    ///
    /// **The lab grades the native path only.** `AgentToolEval` exists to compare
    /// the two prompt shapes; the lab asks a different question — whether *this
    /// model* can drive the shape the app already ships — so measuring both here
    /// would double every run to answer something already answered.
    static func calledTool(in raw: String, setup: Setup) -> String? {
        switch NativeToolCallParser.parse(raw, tools: setup.tools) {
        case .success(.call(let call)): return call.tool
        case .success(.answer), .failure: return nil
        }
    }
}
