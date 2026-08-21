import Foundation

/// Accumulates a dictation's stage chain as the pipeline runs.
///
/// Pure and value-typed, so the whole "what happened to my words" chain is testable
/// without a microphone, a model or a main actor — the same reason
/// `DictationViewModel.usageRecord` and `SessionAccounting` were pulled out.
///
/// It sits **beside** the existing `Diagnostics.shared.noteStage` calls rather than
/// replacing them, and the two are deliberately different instruments: diagnostics is
/// a developer-only build that also writes the audio and latency timeline to disk,
/// this is a surface a user can open in a shipped app. Add a stage to both or the
/// chains disagree.
struct DictationTraceBuilder {
    private var trace: DictationTrace
    /// The text as the last stage left it, so `changed` compares against what the
    /// next stage was actually handed rather than against the raw transcript.
    private var current: String

    init(engine: TranscriberEngine,
         raw: String,
         usedSalvage: Bool,
         startedAt: Date,
         duration: TimeInterval) {
        let clamped = TraceText.clamp(raw)
        trace = DictationTrace(
            startedAt: startedAt,
            engineRawValue: engine.rawValue,
            durationSeconds: duration,
            rawTranscript: clamped,
            usedSalvage: usedSalvage)
        current = clamped
    }

    /// Record what a pass produced. `note` is for a count worth stating; an empty
    /// one renders as nothing rather than as an empty row.
    mutating func stage(_ label: String, _ text: String, note: String = "") {
        let clamped = TraceText.clamp(text)
        trace.stages.append(TraceStage(
            label: label,
            text: clamped,
            changed: clamped != current,
            note: note))
        current = clamped
    }

    /// A pass that was **skipped**, and why — recorded rather than omitted, because a
    /// missing row reads as "this never happens" when the truth is "this is switched
    /// off". That distinction is the whole reason someone opens this surface.
    mutating func skipped(_ label: String, why: String) {
        trace.stages.append(TraceStage(
            label: label,
            text: current,
            changed: false,
            note: why))
    }

    var stages: [TraceStage] { trace.stages }

    /// Seal it. `finalText` is the deterministic result — the text that gets pasted
    /// — with polish and delivery attached later by the store, since both land after
    /// the words have already gone out.
    func build(finalText: String) -> DictationTrace {
        var built = trace
        built.finalText = TraceText.clamp(finalText)
        return built
    }

    /// Plural-safe count note: "1 fix" / "3 fixes", or nothing at all for zero.
    static func fixNote(_ count: Int, _ noun: String) -> String {
        guard count > 0 else { return "" }
        return "\(count) \(noun)\(count == 1 ? "" : "s")"
    }
}
