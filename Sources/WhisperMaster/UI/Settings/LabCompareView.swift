import SwiftUI

/// Baseline against candidate: four deltas, then every case where the two
/// disagreed, with the actual words.
///
/// **The words are the point.** A score of 87 against 85 does not tell you
/// whether the two you lost were room numbers or a whole sentence, and that is
/// the difference between shipping a model and not. So the default filter is
/// "disagreements", and a row opens to the raw input, the deterministic text, and
/// both outputs.
struct LabCompareView: View {
    let lab: LabController

    private var summary: LabComparison.Summary { lab.comparisonSummary }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            if let run = lab.activeRun, !run.models.isEmpty {
                pickers(run)
                deltas
                rows
            } else {
                LabEmptyState(
                    title: "Nothing benched yet",
                    detail: "Tick two models on the left and run a suite. "
                        + "The first one is the baseline, the second the candidate.")
            }
        }
    }

    // MARK: Which two

    private func pickers(_ run: LabRun) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            picker(title: "Baseline", run: run, selected: lab.baselineID) { lab.baselineID = $0 }
            picker(title: "Candidate", run: run, selected: lab.candidateID ?? "") { lab.candidateID = $0 }
        }
    }

    /// Chips rather than a `Menu`: a run holds a handful of models, and an
    /// AppKit-backed menu does not draw in the headless snapshot pass.
    private func picker(
        title: String, run: LabRun, selected: String, choose: @escaping (String) -> Void
    ) -> some View {
        HStack(spacing: Theme.Space.sm) {
            Text(title)
                .font(Typography.monoSmall)
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 62, alignment: .leading)
            ForEach(run.models) { result in
                LabChip(title: result.modelName, isOn: selected == result.modelID) {
                    choose(result.modelID)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: The four figures

    /// Two by two rather than four across. At the page's measure a row of four
    /// leaves each tile ~145pt, which wraps "410 MB" onto three lines — a figure
    /// broken across lines is not a figure you can read at a glance.
    private var deltas: some View {
        VStack(spacing: Theme.Space.md) {
            HStack(alignment: .top, spacing: Theme.Space.md) {
                LabDeltaTile(
                    label: "Score",
                    left: "\(summary.baselineScore)", right: "\(summary.candidateScore)",
                    caption: "of \(summary.total) cases",
                    delta: Double(summary.candidateScore - summary.baselineScore),
                    higherIsBetter: true)
                LabDeltaTile(
                    label: "p50 latency",
                    left: LabFormat.milliseconds(summary.baselineP50),
                    right: LabFormat.milliseconds(summary.candidateP50),
                    caption: "per case",
                    delta: Double(summary.candidateP50 - summary.baselineP50),
                    higherIsBetter: false)
            }
            HStack(alignment: .top, spacing: Theme.Space.md) {
                LabDeltaTile(
                    label: "Peak GPU",
                    left: LabFormat.bytes(summary.baselinePeakGPU),
                    right: LabFormat.bytes(summary.candidatePeakGPU),
                    caption: "resident, model only",
                    delta: Double(summary.candidatePeakGPU - summary.baselinePeakGPU),
                    higherIsBetter: false)
                LabDeltaTile(
                    label: "Guard rejects",
                    left: "\(summary.baselineGuardRejects)", right: "\(summary.candidateGuardRejects)",
                    caption: "output discarded",
                    delta: Double(summary.candidateGuardRejects - summary.baselineGuardRejects),
                    higherIsBetter: false)
            }
        }
    }

    // MARK: Case rows

    private var rows: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(spacing: Theme.Space.sm) {
                ForEach(LabRowFilter.allCases) { option in
                    LabChip(title: option.title, isOn: lab.filter == option) { lab.filter = option }
                }
                Spacer(minLength: 0)
                Text(countLine)
                    .font(Typography.monoSmall)
                    .foregroundStyle(Theme.textTertiary)
            }

            let visible = lab.comparisonRows
            if visible.isEmpty {
                LabEmptyState(
                    title: lab.filter == .regressions ? "No regressions" : "No disagreements",
                    detail: "The two models answered every case the same way.")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(visible.prefix(80).enumerated()), id: \.element.id) { index, row in
                        if index > 0 { RowDivider() }
                        LabCaseRow(
                            row: row,
                            isExpanded: lab.expandedCaseID == row.id,
                            toggle: {
                                lab.expandedCaseID = lab.expandedCaseID == row.id ? nil : row.id
                            })
                    }
                    if visible.count > 80 {
                        Text("\(visible.count - 80) more not shown. Export the run to read them all.")
                            .font(Typography.monoSmall)
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, Theme.Space.lg)
                .card()
            }
        }
    }

    private var countLine: String {
        let summary = self.summary
        return "\(summary.regressions) regression\(summary.regressions == 1 ? "" : "s"), "
            + "\(summary.improvements) improvement\(summary.improvements == 1 ? "" : "s")"
    }
}

// MARK: - Tiles

/// Two figures and which way the difference points. The arrow is not left to the
/// sign of the number: fewer milliseconds and more passes are both good, and a
/// tile that made the reader work that out would be a tile nobody trusts.
struct LabDeltaTile: View {
    let label: String
    let left: String
    let right: String
    let caption: String
    let delta: Double
    let higherIsBetter: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(Typography.kicker)
                .tracking(0.6)
                .foregroundStyle(Theme.textFaint)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(left)
                    .font(Typography.heading(19, .bold, relativeTo: .title3))
                    .lineLimit(1)
                    .foregroundStyle(Theme.textPrimary)
                Text("vs")
                    .font(Typography.monoSmall)
                    .foregroundStyle(Theme.textFaint)
                Text(right)
                    .font(Typography.heading(19, .bold, relativeTo: .title3))
                    .lineLimit(1)
                    .foregroundStyle(Theme.textPrimary)
            }
            Text(verdict)
                .font(Typography.monoSmall)
                .foregroundStyle(verdictColour)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text(caption)
                .font(Typography.monoSmall)
                .foregroundStyle(Theme.textFaint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.md)
        .card()
    }

    private var isBetter: Bool { higherIsBetter ? delta > 0 : delta < 0 }

    private var verdict: String {
        if delta == 0 { return "no change" }
        return isBetter ? "candidate wins" : "candidate loses"
    }

    private var verdictColour: Color {
        if delta == 0 { return Theme.textTertiary }
        return isBetter ? Theme.accent2 : Theme.danger
    }
}

// MARK: - One case

private struct LabCaseRow: View {
    let row: LabComparisonRow
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: toggle) {
                HStack(alignment: .top, spacing: Theme.Space.md) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.id)
                            .font(Typography.monoSmall)
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        Text(row.category)
                            .font(Typography.monoSmall)
                            .foregroundStyle(Theme.textFaint)
                    }
                    .frame(width: 132, alignment: .leading)

                    side(row.baseline)
                    side(row.candidate)
                }
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()

            if isExpanded { detail }
        }
    }

    private func side(_ result: LabCaseResult?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(result?.finalOutput.isEmpty == false ? result!.finalOutput : "—")
                .font(Typography.monoSmall)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                if let result {
                    StatusPill(text: result.passed ? "pass" : (result.reasons.first ?? "fail"),
                               tone: result.passed ? .positive : .danger)
                    if !result.guardAccepted && result.inputKind != "tool" {
                        RowTag("guard")
                    }
                    Text(LabFormat.milliseconds(result.latencyMs))
                        .font(Typography.monoSmall)
                        .foregroundStyle(Theme.textFaint)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The whole chain for one case. This is where "why did it do that" is
    /// answerable — the same argument the Traces page makes for a real dictation.
    private var detail: some View {
        VStack(alignment: .leading, spacing: 6) {
            field("said", row.prompt)
            if let deterministic = (row.baseline ?? row.candidate)?.deterministic, !deterministic.isEmpty {
                field("deterministic", deterministic)
            }
            if let baseline = row.baseline {
                field("baseline raw", baseline.modelOutput)
                if let expected = baseline.expectedTool {
                    field("tool", "expected \(expected), called \(baseline.calledTool ?? "nothing")")
                }
                if let wer = baseline.wer {
                    field("wer", String(format: "%.1f%%", wer * 100))
                }
            }
            if let candidate = row.candidate {
                field("candidate raw", candidate.modelOutput)
                if let expected = candidate.expectedTool {
                    field("tool", "expected \(expected), called \(candidate.calledTool ?? "nothing")")
                }
                field("tokens", "\(candidate.generatedTokens) out at "
                    + String(format: "%.0f", candidate.tokensPerSecond) + " tok/s")
            }
        }
        .padding(Theme.Space.md)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.surfaceSunken))
        .padding(.bottom, 9)
    }

    private func field(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.sm) {
            Text(label)
                .font(Typography.monoSmall)
                .foregroundStyle(Theme.textFaint)
                .frame(width: 96, alignment: .leading)
            Text(value.isEmpty ? "—" : value)
                .font(Typography.monoSmall)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

struct LabEmptyState: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(Typography.headline)
                .foregroundStyle(Theme.textPrimary)
            Text(detail)
                .font(Typography.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.lg)
        .card()
    }
}
