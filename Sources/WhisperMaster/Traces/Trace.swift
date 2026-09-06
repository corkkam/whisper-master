import Foundation

/// One stage of the text pipeline, with what it produced and whether it changed
/// anything.
///
/// `changed` is computed by `DictationTraceBuilder` against the text the stage was
/// *handed*, not re-derived at render time: a trace read back off disk months later
/// must say the same thing it said when it was written, and the comparison is the
/// whole point of the row. A stage that changed nothing is still listed — "the
/// glossary was consulted and had nothing to say" is an answer, and hiding it would
/// make the chain look like it skipped a step.
struct TraceStage: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    /// Human name of the pass, never the type name — this is read by whoever is
    /// wondering what happened to their words.
    let label: String
    /// The text as it stood *after* this stage.
    let text: String
    let changed: Bool
    /// What it did, when there's a count worth stating ("2 filler words").
    var note: String = ""
}

/// What the optional on-device polish did — **including when it did nothing, and
/// why**.
///
/// The absence of a polish is the case worth recording. "Smart cleanup is off",
/// "the model isn't loaded", "the model rewrote it and the faithfulness guard threw
/// the rewrite away" and "it had nothing to add" are four completely different
/// answers to "why does this read like raw speech", and until this existed all four
/// looked identical from the outside — the deterministic text simply appeared and
/// nothing said whether a 3B had ever been consulted.
struct PolishTrace: Codable, Hashable, Sendable {
    enum Outcome: String, Codable, Sendable {
        /// Smart cleanup is switched off. Not a failure — the expected state.
        case off
        /// Enabled, but the model wasn't loaded when the words landed.
        case modelNotReady
        /// The model ran and returned nothing usable.
        case noOutput
        /// The model ran and returned the same text.
        case noChange
        /// The model rewrote it and `CleanupFaithfulnessGuard` refused the rewrite.
        case rejected
        /// Accepted, and the user got it.
        case applied
        /// Accepted, but the in-place edit into the focused field didn't take, so
        /// the deterministic text is still what's on screen.
        case notApplied

        var isFailure: Bool {
            switch self {
            case .rejected, .noOutput, .notApplied: return true
            case .off, .modelNotReady, .noChange, .applied: return false
            }
        }
    }

    /// `var` only so `settled(as:reason:)` can restamp it — see that method.
    var outcome: Outcome
    /// "Light cleanup" or "Polish my English" — which prompt ran.
    var mode: String = ""
    /// The deterministic text the model was handed.
    var before: String = ""
    /// The model's raw output, kept **even when it was rejected** — a rewrite the
    /// guard threw away is the single most useful thing on this surface when someone
    /// reports "it keeps ignoring my cleanup setting", and it's already gone from
    /// everywhere else by the time they ask.
    var after: String = ""
    /// One line saying why, written for a person.
    var reason: String = ""
    var milliseconds: Int = 0

    static let off = PolishTrace(outcome: .off, reason: "Smart cleanup is off.")

    /// Same attempt, different fate. The polish is *judged* where the model runs and
    /// *delivered* somewhere else — an accepted rewrite still fails if the in-place
    /// edit into the focused field doesn't take — so the call site that knows whether
    /// it landed restamps the outcome rather than the guard guessing.
    func settled(as outcome: Outcome, reason: String) -> PolishTrace {
        var next = self
        next.outcome = outcome
        next.reason = reason
        return next
    }
}

/// A polish run: the text to use (nil = keep the deterministic paste) and the record
/// of what happened either way.
///
/// The pair exists because the two consumers want different halves — the paste path
/// wants the text, the Traces surface wants the verdict — and returning only the text
/// is what made every failure mode indistinguishable from "off".
struct PolishAttempt: Sendable {
    let text: String?
    let trace: PolishTrace
}

/// Where the words actually went.
struct DeliveryTrace: Codable, Hashable, Sendable {
    /// The route `pasteFinal` took, verbatim — the same string the diagnostics
    /// tracer and the paste analytics use, so three surfaces can't disagree about
    /// what happened.
    let route: String
    var appName: String = ""

    /// The route in words. An unknown route reads as itself rather than being
    /// dropped, so a route added later degrades to something honest.
    var headline: String {
        let target = appName.isEmpty ? "the frontmost app" : appName
        switch route {
        case "native": return "Typed into \(target)"
        case "web": return "Pasted into \(target)"
        case "terminal": return "Pasted into \(target)"
        case "clipboard": return "No text field — left on the clipboard"
        case "noAccessibility": return "Accessibility off — left on the clipboard"
        case "secureInput": return "Secure Keyboard Entry — left on the clipboard"
        case "historyOnly": return "Auto-paste off — kept here only"
        case "empty": return "Nothing to deliver"
        default: return route
        }
    }

    var reachedTheCursor: Bool {
        ["native", "web", "terminal"].contains(route)
    }
}

/// One dictation, from what the engine heard to where the words landed.
///
/// **Disposable by design.** Traces are regenerated by every dictation and capped at
/// `TraceStore.limit`, so unlike `Note` (whose hand-written `Codable` exists because
/// a decode failure destroys irreplaceable user content) this uses the synthesized
/// conformance and a `try?` load: the worst a shape change can cost is a list that
/// refills within a few minutes of use. Bump the defaults key if the shape changes
/// incompatibly rather than growing an init nobody needs.
struct DictationTrace: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var startedAt = Date()
    var engineRawValue: String = ""
    var durationSeconds: Double = 0
    /// What the engine returned, before a single one of our passes touched it. The
    /// row that answers "did it mishear me, or did we break it afterwards" — which
    /// is the first fork in every "it got that wrong" report.
    var rawTranscript: String = ""
    /// True when the final decode failed and the streamed text was used instead.
    var usedSalvage: Bool = false
    var stages: [TraceStage] = []
    /// The deterministic result — what was pasted, before any polish.
    var finalText: String = ""
    /// Attached later: polish runs after the paste on the native path.
    var polish: PolishTrace?
    var delivery: DeliveryTrace?

    var engine: TranscriberEngine? { TranscriberEngine(rawValue: engineRawValue) }

    /// The text as it finally stood, polish included. What the user is looking at.
    var deliveredText: String {
        if let polish, polish.outcome == .applied, !polish.after.isEmpty { return polish.after }
        return finalText
    }

    /// Did any of our passes change what the engine heard? A trace where nothing
    /// changed and the result is still wrong points squarely at the engine.
    var wasRewritten: Bool {
        rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            != deliveredText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// One rung of `routeCommandCapture`'s ladder, and why it was taken or skipped.
///
/// A list rather than a single "route" field, because the useful question is not
/// only *what handled this* but *what didn't, and why not* — "the agent was skipped
/// because the cleanup model isn't loaded" is the answer to almost every "the
/// assistant ignores me" report, and a single route field can only ever say
/// "deterministic".
struct TraceDecision: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    /// The rung: "Agent", "Day summary", "Filed locally".
    let title: String
    /// Why, in one sentence, for a person.
    let detail: String
    /// True for the rung that actually handled the words.
    let taken: Bool
}

/// How a write got permission to run.
///
/// A read carries none — there was nothing to authorize — so the field is optional
/// rather than gaining a `notApplicable` case nobody would read. The two refusals are
/// separate on purpose: "the user said no" and "nobody answered the card" mean
/// opposite things about the design, the same distinction `ApprovalOutcome` draws.
enum ToolAuthorization: String, Codable, Hashable, Sendable {
    /// A standing grant covered it, so no card was raised.
    case standingGrant
    case allowedOnce
    case allowedAlways
    case denied
    case timedOut

    /// The badge on the call row, in the card's own words.
    var label: String {
        switch self {
        case .standingGrant: return "standing grant"
        case .allowedOnce: return "allowed once"
        case .allowedAlways: return "allowed always"
        case .denied: return "declined"
        case .timedOut: return "no answer"
        }
    }

    var isRefusal: Bool {
        switch self {
        case .denied, .timedOut: return true
        case .standingGrant, .allowedOnce, .allowedAlways: return false
        }
    }
}

/// One tool the agent ran, with the connector that served it and what came back.
struct ToolCallTrace: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    /// The catalog name (`list_mail`). Shown here on purpose — the notch withholds
    /// it because a bezel band is not a debugger, but this surface *is* one.
    let tool: String
    var arguments: [String: String] = [:]
    /// Instance labels that contributed, from the tool result's own provenance.
    var connectors: [String] = []
    var ok: Bool = true
    /// What the tool handed back to the model, capped by `TraceText.clamp`.
    var result: String = ""
    /// How long the call itself took, **with the approval wait taken out**. A write
    /// that sat 58 seconds on the consent card is not a slow provider, and charging
    /// the user's own thinking time to the connector made every approved write look
    /// like one.
    var milliseconds: Int = 0
    /// How long the card was up, and nil in a trace written before this was recorded.
    ///
    /// **⚠️ Optional because the synthesized `Codable` does not fall back to a
    /// property's default value for a missing key** — it calls `decode`, which throws.
    /// A bare `var x: Int = 0` added here therefore fails the decode of every trace
    /// already in `UserDefaults`, and `TraceStore`'s `try?` load turns that into a
    /// silently empty page. Every field added from here on is optional, the same rule
    /// `Note` follows with `decodeIfPresent`.
    var approvalMilliseconds: Int?
    /// How the write was permitted, or nil for a read.
    var authorization: ToolAuthorization?

    var isWrite: Bool { ToolCatalog.descriptor(named: tool)?.access == .write }
    var isLocal: Bool { LocalToolCatalog.names.contains(tool) }

    /// `list_mail connector=corkkam` — the call as it was actually made.
    var signature: String {
        guard !arguments.isEmpty else { return tool }
        let rendered = arguments
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        return "\(tool) \(rendered)"
    }
}

/// One raw turn of the agent loop — what the model emitted, or what the loop told it
/// back.
///
/// The tool turns are deliberately **not** kept here: their text is already in
/// `AssistantTrace.calls`, and a trace holding every result twice is exactly the bloat
/// `TraceText.clamp` exists to prevent. What was missing is the model's own side of
/// the conversation — ten malformed JSON calls and the corrections they earned read
/// as "the model answered without calling a tool" everywhere else.
struct TraceTurn: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    /// `AgentTurn.Role`'s raw value, kept as text so a role added to the loop later
    /// reads as itself rather than failing the decode of every trace beside it.
    let role: String
    /// Verbatim, capped by `TraceText.clamp` — a model that runs away produces the
    /// longest turns of all.
    let text: String

    /// "The model said" / "It was told", for the surface.
    var speaker: String {
        switch role {
        case AgentTurn.Role.model.rawValue: return "The model said"
        case AgentTurn.Role.system.rawValue: return "It was told"
        case AgentTurn.Role.tool.rawValue: return "A tool returned"
        default: return role
        }
    }
}

/// One thing said to the assistant: what it heard, what it decided, what it called,
/// and what it answered.
struct AssistantTrace: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var askedAt = Date()
    /// The engine's own words, before our passes. Kept for the same reason as
    /// `DictationTrace.rawTranscript`: an assistant that answered the wrong question
    /// may simply have been handed the wrong words.
    var heard: String = ""
    /// The text the assistant was actually given — the deterministic pipeline's
    /// output, which is what routing and every tool call saw.
    var asked: String = ""
    /// The same stage chain the dictation tab shows, so "what was polished before
    /// the assistant saw it" is answerable here too rather than only for text that
    /// got pasted.
    var stages: [TraceStage] = []
    var decisions: [TraceDecision] = []
    /// Whether the assistant was allowed near the user's connectors at all
    /// (`connectorAgentEnabled`). False is the state that makes a connected mailbox
    /// unreachable, and it is invisible everywhere else.
    var connectorsAllowed: Bool = false
    /// Every tool the model was offered, whether or not it called one. A question
    /// that couldn't be answered because the tool was never on the list is the
    /// commonest assistant failure and the hardest to see.
    var toolsOffered: [String] = []
    var calls: [ToolCallTrace] = []
    /// What the model actually emitted, and what the loop said back. A run that
    /// called nothing has an empty `calls` list and everything interesting in here.
    ///
    /// Optional, not a defaulted array, for the reason spelled out on
    /// `ToolCallTrace.approvalMilliseconds`: a new non-optional field breaks the
    /// decode of every assistant trace already on disk.
    var turns: [TraceTurn]?
    var answer: String = ""
    /// "From corkkam" / "Saved to Notes & Reminders".
    var provenance: String = ""
    var createdSomething: Bool = false
    var milliseconds: Int = 0

    /// The rung that handled it, for the row's badge.
    var takenDecision: TraceDecision? { decisions.first { $0.taken } }

    /// Did any connector serve this? Distinct from `connectorsAllowed`: allowed and
    /// never called is its own story.
    var touchedConnectors: [String] {
        var seen: [String] = []
        for call in calls where !call.isLocal {
            for label in call.connectors where !seen.contains(label) { seen.append(label) }
        }
        return seen
    }
}

/// Length caps for text kept in a trace.
///
/// A trace holds several copies of the same words (raw, per stage, polished), so a
/// long dictation is stored many times over — and `TraceStore` keeps 40 of them in
/// `UserDefaults`, which is read in full at launch. The cap is generous enough that
/// a normal dictation is never touched and mean enough that a ten-minute monologue
/// can't turn the preferences file into a megabyte.
enum TraceText {
    static let limit = 4_000

    static func clamp(_ text: String, limit: Int = limit) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "… (truncated)"
    }
}
