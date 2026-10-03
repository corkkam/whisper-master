import SwiftUI

/// Every model in the run, ranked, with what each one cost.
///
/// The breadth tab. It answers "which of these is worth a closer look", and each
/// row hands the answer to the compare tab rather than trying to be it: a table
/// is a weak place to read two sentences side by side.
struct LabLeaderboardView: View {
    let lab: LabController

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            if let run = lab.activeRun, !run.models.isEmpty {
                table(run)
                if let result = detailResult(run) {
                    LabModelDetail(lab: lab, result: result)
                }
            } else {
                LabEmptyState(
                    title: "Nothing benched yet",
                    detail: "Tick the models on the left and run a suite.")
            }
        }
    }

    private func detailResult(_ run: LabRun) -> LabModelResult? {
        run.result(modelID: lab.candidateID ?? lab.baselineID) ?? run.ranked.first
    }

    private func table(_ run: LabRun) -> some View {
        VStack(spacing: 0) {
            header
            ForEach(run.ranked) { result in
                RowDivider()
                row(result, run: run)
            }
        }
        .padding(.horizontal, Theme.Space.lg)
        .card()
    }

    private var header: some View {
        HStack(spacing: 0) {
            cell("Model", width: 168, align: .leading)
            cell("Score", width: 62)
            cell("p50", width: 60)
            cell("p95", width: 60)
            cell("tok/s", width: 54)
            cell("Peak GPU", width: 76)
            cell("On disk", width: 70)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.textFaint)
        .font(Typography.kicker)
        .padding(.vertical, 8)
    }

    private func row(_ result: LabModelResult, run: LabRun) -> some View {
        let model = lab.allModels.first { $0.id == result.modelID }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    Text(result.modelName)
                        .font(Typography.caption)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if let badge = model?.provenance.badge { RowTag(badge) }
                }
                .frame(width: 168, alignment: .leading)

                value(result.failure == nil ? "\(result.passed)/\(result.total)" : "—", width: 62)
                value(result.total > 0 ? LabFormat.milliseconds(result.p50LatencyMs) : "—", width: 60)
                value(result.total > 0 ? LabFormat.milliseconds(result.p95LatencyMs) : "—", width: 60)
                value(result.medianTokensPerSecond > 0
                    ? String(format: "%.0f", result.medianTokensPerSecond) : "—", width: 54)
                value(LabFormat.bytes(result.peakGPUBytes), width: 76)
                value(LabFormat.bytes(result.diskBytes), width: 70)
                Spacer(minLength: Theme.Space.sm)
                LabMiniButton(title: "Compare", isOn: lab.candidateID == result.modelID, isEnabled: true) {
                    lab.candidateID = result.modelID
                    if lab.baselineID == result.modelID {
                        lab.baselineID = run.models.first { $0.modelID != result.modelID }?.modelID
                            ?? lab.baselineID
                    }
                    lab.tab = .compare
                }
            }
            if let failure = result.failure {
                Text(failure)
                    .font(Typography.monoSmall)
                    .foregroundStyle(Theme.danger)
            } else if result.guardRejects > 0 || result.meanWER != nil {
                Text(subline(result))
                    .font(Typography.monoSmall)
                    .foregroundStyle(Theme.textFaint)
            }
        }
        .padding(.vertical, 9)
    }

    private func subline(_ result: LabModelResult) -> String {
        var parts: [String] = []
        if result.guardRejects > 0 {
            parts.append("\(result.guardRejects) guard reject\(result.guardRejects == 1 ? "" : "s")")
        }
        if let wer = result.meanWER {
            parts.append(String(format: "mean wer %.1f%%", wer * 100))
        }
        parts.append("loaded in \(LabFormat.milliseconds(result.loadMs))")
        return parts.joined(separator: " · ")
    }

    private func cell(_ text: String, width: CGFloat, align: Alignment = .trailing) -> some View {
        Text(text).frame(width: width, alignment: align)
    }

    private func value(_ text: String, width: CGFloat) -> some View {
        Text(text)
            .font(Typography.monoSmall)
            .foregroundStyle(Theme.textSecondary)
            .frame(width: width, alignment: .trailing)
    }
}

/// One model's run in more detail: what it did to memory, and what it got wrong.
struct LabModelDetail: View {
    let lab: LabController
    let result: LabModelResult

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.md) {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(result.modelName): memory through the run")
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textPrimary)
                LabMemoryTrace(samples: result.memory)
                    .frame(height: 78)
                Text(memoryLine)
                    .font(Typography.monoSmall)
                    .foregroundStyle(Theme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.md)
            .card()

            VStack(alignment: .leading, spacing: 6) {
                Text("Failing cases")
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textPrimary)
                let failures = result.cases.filter { !$0.passed }
                if failures.isEmpty {
                    Text("None. Every case passed the mechanical rules.")
                        .font(Typography.monoSmall)
                        .foregroundStyle(Theme.textTertiary)
                }
                ForEach(failures.prefix(6)) { item in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.id)
                            .font(Typography.monoSmall)
                            .foregroundStyle(Theme.textSecondary)
                        Text(item.reasons.first ?? "failed")
                            .font(Typography.monoSmall)
                            .foregroundStyle(Theme.danger)
                            .lineLimit(1)
                    }
                }
                if failures.count > 6 {
                    Text("and \(failures.count - 6) more")
                        .font(Typography.monoSmall)
                        .foregroundStyle(Theme.textFaint)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.md)
            .card()
        }
    }

    private var memoryLine: String {
        "peak \(LabFormat.bytes(result.peakGPUBytes)) GPU · "
            + "\(LabFormat.bytes(result.loadGPUBytes)) resident after load · "
            + "app peaked at \(LabFormat.bytes(result.peakFootprintBytes))"
    }
}

/// GPU memory over one model's run, drawn by hand.
///
/// Hand-drawn rather than `Charts`, like every other shape in this app: the
/// framework does not render under `ImageRenderer`, so a chart from it would be
/// a blank rectangle in every design snapshot.
struct LabMemoryTrace: View {
    let samples: [LabMemorySample]

    var body: some View {
        GeometryReader { proxy in
            let peak = max(1, samples.map(\.peakBytes).max() ?? 1)
            let points = samples.enumerated().map { index, sample -> CGPoint in
                let x = samples.count <= 1
                    ? 0
                    : proxy.size.width * CGFloat(index) / CGFloat(samples.count - 1)
                let y = proxy.size.height * (1 - CGFloat(sample.activeBytes) / CGFloat(peak))
                return CGPoint(x: x, y: y)
            }
            ZStack {
                Rectangle().fill(Theme.surfaceSunken).frame(height: 1)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                if points.count > 1 {
                    Path { path in
                        path.addLines(points)
                    }
                    .stroke(Theme.accent2, lineWidth: 1.5)
                    Path { path in
                        path.addLines(points)
                        path.addLine(to: CGPoint(x: points.last!.x, y: proxy.size.height))
                        path.addLine(to: CGPoint(x: points.first!.x, y: proxy.size.height))
                        path.closeSubpath()
                    }
                    .fill(Theme.accent2Soft)
                } else {
                    Text("No samples.")
                        .font(Typography.monoSmall)
                        .foregroundStyle(Theme.textFaint)
                }
            }
        }
    }
}
