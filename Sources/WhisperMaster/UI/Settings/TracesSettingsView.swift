import SwiftUI

/// Which half of Traces is showing.
///
/// Two tabs because there are two machines. A dictation is a **text pipeline** — one
/// input, a fixed chain of passes, one destination — and the only question it ever
/// raises is "which pass changed my words". An assistant capture is a **decision
/// tree**: several tiers, any of which may decline, and tools that may or may not
/// have been on the table. One list holding both would have to be either a text diff
/// or a decision log, and would be a poor version of whichever it wasn't.
enum TraceTab: String, CaseIterable, Identifiable {
    case dictation
    case assistant

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dictation: return "Dictation"
        case .assistant: return "Assistant"
        }
    }

    var icon: String {
        switch self {
        case .dictation: return "waveform"
        case .assistant: return "sparkles"
        }
    }
}

/// Traces: what actually happened to the last few things you said.
///
/// This replaced the History page, which listed final transcripts and nothing else.
/// The transcript was never the interesting part — it is already in the app you
/// dictated into. What was missing, and what every "why did it do that" question
/// needs, is the *chain*: what the engine heard, which pass changed it, whether the
/// polish ran and what became of its rewrite, where the words were delivered, and —
/// on the assistant side — which tier took the words and why the others didn't.
struct TracesSettingsView: View {
    let viewModel: DictationViewModel
    @Bindable var state: AppState

    @State private var tab: TraceTab
    /// Which rows are open. Ids rather than an index, so the set survives a new
    /// trace arriving at the top of the list mid-read.
    @State private var expanded: Set<UUID>
    @State private var confirmClear = false

    /// `initialTab` / `initiallyExpanded` exist for the headless renderer, which can't
    /// click: a collapsed row is the least interesting thing this page does, so a
    /// snapshot of only that state would review the chrome and never the content.
    /// `NotesSettingsView` takes its tab from outside for the same reason.
    init(viewModel: DictationViewModel,
         state: AppState,
         initialTab: TraceTab = .dictation,
         initiallyExpanded: Set<UUID> = []) {
        self.viewModel = viewModel
        self.state = state
        _tab = State(initialValue: initialTab)
        _expanded = State(initialValue: initiallyExpanded)
    }

    private var store: TraceStore { state.traces }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            switch tab {
            case .dictation: dictationTab
            case .assistant: assistantTab
            }
        }
        .confirmationDialog(
            tab == .dictation ? "Clear dictation traces?" : "Clear assistant traces?",
            isPresented: $confirmClear,
            titleVisibility: .visible
        ) {
            Button("Clear", role: .destructive) {
                switch tab {
                case .dictation: store.clearDictation()
                case .assistant: store.clearAssistant()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Traces are a record of what the app did, not of what you wrote — "
                + "clearing them doesn't touch your transcripts, notes or reminders.")
        }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(alignment: .center, spacing: Theme.Space.md) {
            tabBar
            Spacer(minLength: Theme.Space.sm)
            if !currentIsEmpty {
                Button("Clear") { confirmClear = true }
                    .buttonStyle(.plain)
                    .font(Typography.caption)
                    .foregroundStyle(Theme.danger)
                    .pointerCursor()
            }
        }
    }

    /// Matches the Notes page's switch exactly — a raised `Theme.selection` pill on a
    /// sunken track. Two tab bars in one window that don't agree on what "selected"
    /// looks like is a worse problem than either design being wrong.
    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(TraceTab.allCases) { candidate in
                let isSelected = candidate == tab
                Button { tab = candidate } label: {
                    HStack(spacing: 6) {
                        Image(systemName: candidate.icon)
                            .font(.system(size: 11, weight: .semibold))
                        Text(candidate.title)
                            .font(Typography.sans(13, isSelected ? .semibold : .medium))
                        if let count = count(for: candidate) {
                            Text("\(count)")
                                .font(Typography.sans(10.5, .semibold))
                                .monospacedDigit()
                                .foregroundStyle(isSelected ? Theme.accent.opacity(0.7) : Theme.textFaint)
                        }
                    }
                    .foregroundStyle(isSelected ? Theme.accentText : Theme.textSecondary)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 7)
                    .background {
                        if isSelected {
                            Capsule(style: .continuous)
                                .fill(Theme.selection)
                                .shadow(color: Theme.shadowRaised.color,
                                        radius: Theme.shadowRaised.radius,
                                        y: Theme.shadowRaised.y)
                        }
                    }
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(3)
        .background(Capsule(style: .continuous).fill(Theme.surfaceSunken))
    }

    private func count(for tab: TraceTab) -> Int? {
        let value = tab == .dictation ? store.dictation.count : store.assistant.count
        return value == 0 ? nil : value
    }

    private var currentIsEmpty: Bool {
        tab == .dictation ? store.dictation.isEmpty : store.assistant.isEmpty
    }

    // MARK: - Dictation

    private var dictationTab: some View {
        Group {
            if store.dictation.isEmpty {
                empty(
                    icon: "waveform",
                    title: "No dictations traced yet",
                    body: "Hold your push-to-talk key and say something. Every dictation "
                        + "records what the engine heard, which pass changed it, and where "
                        + "the words landed.")
            } else {
                SettingsCard {
                    ForEach(Array(store.dictation.enumerated()), id: \.element.id) { index, trace in
                        DictationTraceRow(
                            trace: trace,
                            isExpanded: expanded.contains(trace.id),
                            toggle: { toggle(trace.id) },
                            copy: { viewModel.copyToClipboard($0) },
                            delete: { store.deleteDictation(trace.id) })
                        if index < store.dictation.count - 1 { RowDivider() }
                    }
                }
            }
        }
    }

    // MARK: - Assistant

    private var assistantTab: some View {
        Group {
            if store.assistant.isEmpty {
                empty(
                    icon: "sparkles",
                    title: "Nothing asked yet",
                    body: "Hold fn + control and ask something. Every capture records which "
                        + "tier took it and why, the tools the model was offered, and every "
                        + "connector it called.")
            } else {
                SettingsCard {
                    ForEach(Array(store.assistant.enumerated()), id: \.element.id) { index, trace in
                        AssistantTraceRow(
                            trace: trace,
                            isExpanded: expanded.contains(trace.id),
                            toggle: { toggle(trace.id) },
                            copy: { viewModel.copyToClipboard($0) },
                            delete: { store.deleteAssistant(trace.id) })
                        if index < store.assistant.count - 1 { RowDivider() }
                    }
                }
            }
        }
    }

    private func toggle(_ id: UUID) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    private func empty(icon: String, title: String, body: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 32))
                .foregroundStyle(Theme.textTertiary)
            Text(title)
                .font(Typography.title).tracking(Typography.titleTracking)
                .foregroundStyle(Theme.textPrimary)
            Text(body)
                .font(Typography.body)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
        .padding(44)
        .card()
    }
}

// MARK: - Rows

/// One dictation, collapsed to its result and opened to its chain.
private struct DictationTraceRow: View {
    let trace: DictationTrace
    let isExpanded: Bool
    let toggle: () -> Void
    let copy: (String) -> Void
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                Text(TraceFormat.time.string(from: trace.startedAt))
                    .font(Typography.monoSmall)
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 72, alignment: .leading)
                VStack(alignment: .leading, spacing: 7) {
                    Text(trace.deliveredText.isEmpty ? "(nothing)" : trace.deliveredText)
                        .font(Typography.body)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(isExpanded ? nil : 2)
                        .textSelection(.enabled)
                    badges
                }
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    IconButton("doc.on.doc", label: "Copy transcript") { copy(trace.deliveredText) }
                    IconButton(isExpanded ? "chevron.up" : "chevron.down",
                               label: isExpanded ? "Hide trace" : "Show trace",
                               action: toggle)
                    IconButton("trash", label: "Delete trace", role: .destructive, action: delete)
                }
            }
            if isExpanded { detail.padding(.top, 16) }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .contentShape(Rectangle())
    }

    private var badges: some View {
        HStack(spacing: 8) {
            if let engine = trace.engine {
                TraceBadge(text: engine.displayName)
            }
            TraceBadge(text: TraceFormat.duration(trace.durationSeconds))
            if let delivery = trace.delivery {
                TraceBadge(text: delivery.headline,
                           tone: delivery.reachedTheCursor ? .neutral : .warning)
            }
            TraceBadge(text: polishLabel, tone: polishTone)
            if trace.usedSalvage {
                TraceBadge(text: "Salvaged", tone: .warning)
            }
        }
        .font(Typography.caption)
    }

    private var polishLabel: String {
        guard let polish = trace.polish else { return "Polish pending" }
        switch polish.outcome {
        case .off: return "No polish"
        case .modelNotReady: return "Model not loaded"
        case .noOutput: return "Polish returned nothing"
        case .noChange: return "Polish: no change"
        case .rejected: return "Polish rejected"
        case .applied: return "Polished"
        case .notApplied: return "Polish not applied"
        }
    }

    private var polishTone: TraceBadge.Tone {
        guard let polish = trace.polish else { return .neutral }
        if polish.outcome == .applied { return .good }
        return polish.outcome.isFailure ? .warning : .neutral
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            TraceField(label: "What the engine heard", text: trace.rawTranscript, isMono: true)
            if !trace.stages.isEmpty {
                TraceSubhead("Passes")
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(trace.stages) { stage in
                        StageRow(stage: stage)
                    }
                }
            }
            if let polish = trace.polish {
                TraceSubhead("Smart cleanup")
                PolishBlock(polish: polish)
            }
            if let delivery = trace.delivery {
                TraceSubhead("Delivery")
                Text(delivery.headline)
                    .font(Typography.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

/// One assistant capture: the question, the ladder, and every call it made.
private struct AssistantTraceRow: View {
    let trace: AssistantTrace
    let isExpanded: Bool
    let toggle: () -> Void
    let copy: (String) -> Void
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                Text(TraceFormat.time.string(from: trace.askedAt))
                    .font(Typography.monoSmall)
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 72, alignment: .leading)
                VStack(alignment: .leading, spacing: 7) {
                    Text(trace.asked)
                        .font(Typography.body)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(isExpanded ? nil : 2)
                        .textSelection(.enabled)
                    if !trace.answer.isEmpty {
                        Text(trace.answer)
                            .font(Typography.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(isExpanded ? nil : 2)
                            .textSelection(.enabled)
                    }
                    badges
                }
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    IconButton("doc.on.doc", label: "Copy answer") {
                        copy(trace.answer.isEmpty ? trace.asked : trace.answer)
                    }
                    IconButton(isExpanded ? "chevron.up" : "chevron.down",
                               label: isExpanded ? "Hide trace" : "Show trace",
                               action: toggle)
                    IconButton("trash", label: "Delete trace", role: .destructive, action: delete)
                }
            }
            if isExpanded { detail.padding(.top, 16) }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .contentShape(Rectangle())
    }

    private var badges: some View {
        HStack(spacing: 8) {
            if let taken = trace.takenDecision {
                TraceBadge(text: taken.title, tone: .good)
            }
            if !trace.calls.isEmpty {
                TraceBadge(text: "\(trace.calls.count) tool\(trace.calls.count == 1 ? "" : "s")")
            }
            // The setting that makes a connected account unreachable, said out loud on
            // the row rather than buried in the expansion — it is the answer to most
            // "why didn't it read my mail" questions, and nothing else in the app
            // mentions it at the moment it bites.
            if !trace.connectorsAllowed {
                TraceBadge(text: "Connectors off", tone: .warning)
            }
            ForEach(trace.touchedConnectors, id: \.self) { label in
                TraceBadge(text: label, tone: .accent)
            }
            TraceBadge(text: TraceFormat.milliseconds(trace.milliseconds))
        }
        .font(Typography.caption)
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            if trace.heard != trace.asked {
                TraceField(label: "What the engine heard", text: trace.heard, isMono: true)
                TraceField(label: "What the assistant was given", text: trace.asked, isMono: true)
            } else {
                TraceField(label: "What the assistant was given", text: trace.asked, isMono: true)
            }

            TraceSubhead("Decisions")
            VStack(alignment: .leading, spacing: 8) {
                ForEach(trace.decisions) { decision in
                    DecisionRow(decision: decision)
                }
            }

            TraceSubhead("Tools")
            if trace.toolsOffered.isEmpty {
                Text("No tools were available.")
                    .font(Typography.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            } else {
                Text(trace.toolsOffered.joined(separator: ", "))
                    .font(Typography.monoSmall)
                    .foregroundStyle(Theme.textTertiary)
                    .textSelection(.enabled)
            }
            if !trace.connectorsAllowed {
                Text("Your connectors weren't offered — \u{201C}Let it use your connectors\u{201D} "
                    + "is off in Settings → General.")
                    .font(Typography.subheadline)
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !trace.calls.isEmpty {
                TraceSubhead("Calls")
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(trace.calls) { call in
                        CallRow(call: call)
                    }
                }
            }

            // Collapsed: this is the loop's raw transcript, and it is long and
            // JSON-shaped. It is also the only thing that explains a run that called
            // nothing — the calls above are empty in exactly that case.
            if let turns = trace.turns, !turns.isEmpty {
                ModelTurnsBlock(turns: turns)
            }

            if !trace.stages.isEmpty {
                TraceSubhead("Passes before the assistant saw it")
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(trace.stages) { stage in
                        StageRow(stage: stage)
                    }
                }
            }

            if !trace.provenance.isEmpty {
                TraceSubhead("Result")
                Text(trace.provenance)
                    .font(Typography.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

// MARK: - Pieces

private struct DecisionRow: View {
    let decision: TraceDecision

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: decision.taken ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(decision.taken ? Theme.success : Theme.textFaint)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(decision.title)
                    .font(Typography.sans(13, .semibold))
                    .foregroundStyle(decision.taken ? Theme.textPrimary : Theme.textSecondary)
                Text(decision.detail)
                    .font(Typography.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct CallRow: View {
    let call: ToolCallTrace

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: call.ok ? "arrow.right.circle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(call.ok ? Theme.success : Theme.danger)
                Text(call.signature)
                    .font(Typography.monoSmall)
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                if call.isWrite { TraceBadge(text: "write", tone: .warning) }
                // How the write got permission. A read carries none, so the badge is
                // absent rather than saying "not applicable" on every row.
                if let authorization = call.authorization {
                    TraceBadge(text: authorization.label,
                               tone: authorization.isRefusal ? .warning : .neutral)
                }
                ForEach(call.connectors, id: \.self) { label in
                    TraceBadge(text: label, tone: .accent)
                }
                Spacer(minLength: 0)
                // The wait is named beside the call rather than folded into it: the
                // consent card's minute is the user's, not the connector's.
                if let waited = call.approvalMilliseconds, waited > 0 {
                    Text("waited \(TraceFormat.milliseconds(waited))")
                        .font(Typography.caption)
                        .foregroundStyle(Theme.textFaint)
                }
                Text(TraceFormat.milliseconds(call.milliseconds))
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textFaint)
            }
            if !call.result.isEmpty {
                Text(call.result)
                    .font(Typography.monoSmall)
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 20)
            }
        }
    }
}

/// The loop's own transcript, folded away until asked for.
///
/// Shut by default because it is raw JSON and correction notes — the least readable
/// thing on the page — and open on request because it is the only record of a run
/// that never reached a tool. Same plain toggle the note card's "What I heard" uses,
/// rather than a `DisclosureGroup`, so the two read alike.
private struct ModelTurnsBlock: View {
    let turns: [TraceTurn]

    @State private var isOpen = false
    /// The headless renderer can't click, so it sees the open state — a snapshot of a
    /// shut disclosure reviews a chevron, which is the same reason the rows themselves
    /// take `initiallyExpanded`.
    @Environment(\.isSnapshot) private var isSnapshot

    private var showsTurns: Bool { isOpen || isSnapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { isOpen.toggle() } label: {
                HStack(spacing: 5) {
                    Image(systemName: showsTurns ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                    Text("Model turns")
                        .monoLabel()
                    Text("\(turns.count)")
                        .font(Typography.caption)
                        .monospacedDigit()
                }
                .foregroundStyle(Theme.textTertiary)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .accessibilityLabel(showsTurns
                ? "Hide what the model said"
                : "Show what the model said, \(turns.count) turns")
            if showsTurns {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(turns) { turn in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(turn.speaker)
                                .font(Typography.caption)
                                .foregroundStyle(Theme.textFaint)
                            Text(turn.text)
                                .font(Typography.monoSmall)
                                .foregroundStyle(Theme.textSecondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }
}

private struct StageRow: View {
    let stage: TraceStage

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // An unchanged pass is dimmed rather than hidden: "this ran and did
            // nothing" and "this never ran" are different answers.
            Image(systemName: stage.changed ? "arrow.triangle.branch" : "equal")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(stage.changed ? Theme.accent : Theme.textFaint)
                .frame(width: 14)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(stage.label)
                        .font(Typography.sans(12.5, stage.changed ? .semibold : .regular))
                        .foregroundStyle(stage.changed ? Theme.textPrimary : Theme.textTertiary)
                    if !stage.note.isEmpty {
                        Text(stage.note)
                            .font(Typography.caption)
                            .foregroundStyle(Theme.textFaint)
                    }
                }
                if stage.changed {
                    Text(stage.text)
                        .font(Typography.monoSmall)
                        .foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct PolishBlock: View {
    let polish: PolishTrace

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(polish.reason)
                .font(Typography.subheadline)
                .foregroundStyle(polish.outcome.isFailure ? Theme.warning : Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if !polish.mode.isEmpty || polish.milliseconds > 0 {
                HStack(spacing: 8) {
                    if !polish.mode.isEmpty { TraceBadge(text: polish.mode) }
                    if polish.milliseconds > 0 {
                        TraceBadge(text: TraceFormat.milliseconds(polish.milliseconds))
                    }
                }
            }
            // The rewrite is shown even when it was thrown away — that is the whole
            // reason it's kept. Seeing *what* the guard refused is what turns "the
            // polish never works" into an actionable report.
            if !polish.after.isEmpty, polish.after != polish.before {
                TraceField(label: polish.outcome == .applied ? "Rewrote it to" : "It wanted to write",
                           text: polish.after,
                           isMono: true)
            }
        }
    }
}

private struct TraceSubhead: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .monoLabel()
            .foregroundStyle(Theme.textTertiary)
    }
}

private struct TraceField: View {
    let label: String
    let text: String
    var isMono = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(Typography.caption)
                .foregroundStyle(Theme.textFaint)
            Text(text.isEmpty ? "(empty)" : text)
                .font(isMono ? Typography.monoSmall : Typography.body)
                .foregroundStyle(Theme.textSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A small status pill. Deliberately quieter than `Chip` — a row can carry five of
/// these, and five `Chip`s would out-shout the transcript they describe.
private struct TraceBadge: View {
    enum Tone { case neutral, good, warning, accent }

    let text: String
    var tone: Tone = .neutral

    var body: some View {
        Text(text)
            .font(Typography.caption)
            .foregroundStyle(foreground)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule(style: .continuous).fill(background))
    }

    private var foreground: Color {
        switch tone {
        case .neutral: return Theme.textTertiary
        case .good: return Theme.success
        case .warning: return Theme.warning
        case .accent: return Theme.accentText
        }
    }

    private var background: Color {
        switch tone {
        case .neutral: return Theme.surfaceSunken
        case .good: return Theme.successSoft
        case .warning: return Theme.warningSoft
        case .accent: return Theme.selection
        }
    }
}

enum TraceFormat {
    static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter
    }()

    static func duration(_ seconds: Double) -> String {
        guard seconds >= 1 else { return "<1s" }
        return "\(Int(seconds.rounded()))s"
    }

    /// Sub-second work reads in milliseconds; past that a second count is what a
    /// person is actually judging ("did that take four seconds or forty").
    static func milliseconds(_ value: Int) -> String {
        guard value >= 1000 else { return "\(value)ms" }
        return String(format: "%.1fs", Double(value) / 1000)
    }
}
