import AppKit
import SwiftUI

/// The Model Lab: the dev build's bench for open-source models.
///
/// **The page is a comparison, not a table of results.** The question it exists
/// to answer is "is this candidate better than what ships", and only two answers
/// side by side settle that — so `Compare` is the default half and the ranked
/// table is the other tab, not the front door. The history rail is the third
/// piece: a bench nobody can look back at cannot tell you whether last month's
/// change held.
///
/// Everything here is dev-only (`FeatureFlags.modelLabAvailable`), and the one
/// thing that reaches out of the page — pointing a shipped slot at another model
/// — is fenced again at the point of use (`LabModelOverride`).
struct LabSettingsView: View {
    @Bindable var state: AppState
    @Environment(\.isSnapshot) private var isSnapshot

    private var lab: LabController { state.lab }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            LabRunBar(lab: lab, shippedModelResident: state.cleanupModelReady)

            if let failure = lab.runner.failure {
                LabNotice(text: failure, tone: .danger)
            }
            if lab.repoRoot == nil {
                LabRepoNotice(lab: lab, isSnapshot: isSnapshot)
            }
            if let overridden = overrideNotice {
                LabNotice(text: overridden, tone: .warning)
            }

            HStack(alignment: .top, spacing: Theme.Space.lg) {
                LabModelRail(lab: lab)
                    .frame(width: 246)

                VStack(alignment: .leading, spacing: Theme.Space.md) {
                    LabTabBar(tab: Binding(get: { lab.tab }, set: { lab.tab = $0 }))
                    switch lab.tab {
                    case .compare: LabCompareView(lab: lab)
                    case .leaderboard: LabLeaderboardView(lab: lab)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                LabHistoryRail(lab: lab)
                    .frame(width: 178)
            }
        }
        .onAppear {
            lab.activate()
            lab.reconcileSelection()
        }
    }

    /// A dev build quietly dictating with a different model would make every
    /// other observation on it unreadable, so the page says which slots are not
    /// running what ships.
    private var overrideNotice: String? {
        let slots = LabRole.allCases.compactMap { role -> String? in
            guard let model = lab.overrideModel(for: role) else { return nil }
            return "\(role.rawValue): \(model.name)"
        }
        guard !slots.isEmpty else { return nil }
        return "This build is not running the shipped models. " + slots.joined(separator: ", ")
            + ". Takes effect the next time each model loads."
    }
}

// MARK: - Run bar

/// Suite, model count, and the one button that starts everything.
private struct LabRunBar: View {
    let lab: LabController
    /// Whether the app's own cleanup model is loaded right now. Worth saying:
    /// it shares the GPU with whatever the lab loads, which is why the peaks are
    /// measured as a delta rather than as MLX's raw high-water mark.
    let shippedModelResident: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(spacing: Theme.Space.sm) {
                ForEach(LabSuite.allCases) { suite in
                    LabChip(title: suite.title, isOn: lab.suite == suite) {
                        lab.suite = suite
                        // A model that cannot run the new suite must not stay
                        // ticked: a normalizer in the tool-calling suite would
                        // score zero for a reason that is not about its quality.
                        let eligible = Set(lab.eligibleModels.map(\.id))
                        lab.selectedModelIDs.formIntersection(eligible)
                    }
                }
                Spacer(minLength: Theme.Space.md)
                if lab.runner.isRunning {
                    SecondaryButton(title: "Stop") { lab.stop() }
                } else {
                    PrimaryButton(title: "Run suite", icon: "play.fill") { lab.start() }
                        .disabled(lab.selectedModels.isEmpty)
                }
            }

            if lab.runner.isRunning {
                LabProgressStrip(lab: lab)
            } else {
                Text(readyLine)
                    .font(Typography.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(Theme.Space.lg)
        .card()
    }

    private var readyLine: String {
        let models = lab.selectedModels
        guard !models.isEmpty else { return "Tick at least one model to run \(lab.suite.title.lowercased())." }
        var line = "\(lab.suite.detail) \(models.count) model\(models.count == 1 ? "" : "s"), "
            + "one resident at a time."
        if lab.pendingDownloadBytes > 0 {
            line += " Downloads about \(LabFormat.bytes(lab.pendingDownloadBytes)) first."
        }
        if shippedModelResident {
            line += " Smart cleanup is on, so its model is resident too, and peaks are"
                + " measured as a delta over that."
        }
        return line
    }
}

/// While a run is in flight: which model, which case, and the log.
private struct LabProgressStrip: View {
    let lab: LabController

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(spacing: Theme.Space.sm) {
                Text("\(lab.runner.currentModelName), case \(lab.runner.caseIndex + 1) of \(lab.runner.caseCount)")
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textPrimary)
                Text("model \(lab.runner.modelIndex + 1) of \(lab.runner.modelCount)")
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textTertiary)
                Spacer(minLength: 0)
                if let startedAt = lab.runner.startedAt {
                    Text(LabFormat.duration(Date().timeIntervalSince(startedAt)))
                        .font(Typography.monoSmall)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            LabBar(fraction: lab.runner.progressFraction, tone: Theme.accentFill)
                .frame(height: 6)

            // The log is the run's honesty: a case that failed says so here as it
            // happens, rather than only in the table afterwards.
            VStack(alignment: .leading, spacing: 2) {
                ForEach(lab.runner.log.suffix(5)) { line in
                    Text(line.text)
                        .font(Typography.monoSmall)
                        .foregroundStyle(colour(for: line.kind))
                        .lineLimit(1)
                }
            }
        }
    }

    private func colour(for kind: LabLogLine.Kind) -> Color {
        switch kind {
        case .info: return Theme.textTertiary
        case .good: return Theme.accent2
        case .bad: return Theme.danger
        }
    }
}

// MARK: - Model rail

/// Every model the suite can run, what it costs on this Mac, and which slot it
/// is wired into.
private struct LabModelRail: View {
    let lab: LabController

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            SectionLabel("Models")
            VStack(spacing: 0) {
                ForEach(Array(lab.eligibleModels.enumerated()), id: \.element.id) { index, model in
                    if index > 0 { RowDivider() }
                    LabModelRow(lab: lab, model: model)
                }
            }
            .padding(.horizontal, Theme.Space.md)
            .card()
        }
    }
}

private struct LabModelRow: View {
    let lab: LabController
    let model: LabModel

    private var install: LabInstallState { lab.state(for: model) }
    private var isSelected: Bool { lab.selectedModelIDs.contains(model.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button { lab.toggle(model) } label: {
                HStack(spacing: 8) {
                    Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isSelected ? Theme.accentText : Theme.textFaint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.name)
                            .font(Typography.caption)
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        Text(subtitle)
                            .font(Typography.monoSmall)
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if let badge = model.provenance.badge {
                        RowTag(badge)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()

            if isSelected {
                Text(model.note)
                    .font(Typography.monoSmall)
                    .foregroundStyle(Theme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
                // "Use for:" then the slots, rather than a button per slot
                // spelling out the whole sentence: at the rail's 236pt two
                // buttons reading "Use for assistant" wrap to three lines each.
                HStack(spacing: 6) {
                    Text("Slot:")
                        .font(Typography.monoSmall)
                        .foregroundStyle(Theme.textFaint)
                    ForEach(LabRole.allCases.filter { model.supports($0) }, id: \.self) { role in
                        LabMiniButton(
                            title: role.rawValue,
                            isOn: lab.overrideModel(for: role)?.id == model.id,
                            isEnabled: lab.canUse(model, for: role)
                        ) {
                            let isCurrent = lab.overrideModel(for: role)?.id == model.id
                            lab.use(isCurrent ? nil : model, for: role)
                        }
                    }
                    Spacer(minLength: 0)
                }
                if lab.canDelete(model) {
                    // Its own line: three buttons and a label do not fit the
                    // rail's width, and a wrapped button reads as a broken one.
                    LabMiniButton(title: "Delete from disk", isOn: false, isEnabled: true) {
                        lab.delete(model)
                    }
                }
            }
        }
        .padding(.vertical, 9)
    }

    private var subtitle: String {
        if install.isInstalled {
            return "\(model.parameters) · \(LabFormat.bytes(install.bytes))"
        }
        return "\(model.parameters) · gets \(LabFormat.bytes(model.approximateDownloadBytes))"
    }
}

// MARK: - History rail

/// Past runs, newest first. Kept because "did this get worse" is a question
/// about last week, and a rebuild wipes anything held in memory.
private struct LabHistoryRail: View {
    let lab: LabController

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            SectionLabel("History")
            VStack(spacing: 0) {
                if lab.runStore.runs.isEmpty {
                    Text("No runs yet.")
                        .font(Typography.monoSmall)
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(Array(lab.runStore.runs.prefix(12).enumerated()), id: \.element.id) { index, run in
                    if index > 0 { RowDivider() }
                    Button {
                        lab.selectedRunID = run.id
                        lab.reconcileSelection()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text("Run \(run.id)")
                                    .font(Typography.caption)
                                    .foregroundStyle(lab.activeRun?.id == run.id
                                        ? Theme.accentText : Theme.textPrimary)
                                if run.stopped { RowTag("stopped") }
                            }
                            Text(summary(run))
                                .font(Typography.monoSmall)
                                .foregroundStyle(Theme.textTertiary)
                                .lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }
            .padding(.horizontal, Theme.Space.md)
            .card()

            if lab.activeRun != nil {
                TextButton(title: "Export run", icon: "square.and.arrow.up") {
                    if let directory = lab.export() {
                        NSWorkspace.shared.activateFileViewerSelecting([directory])
                    }
                }
            }
        }
    }

    private func summary(_ run: LabRun) -> String {
        let best = run.ranked.first
        let score = best.map { "\($0.passed)/\($0.total)" } ?? "—"
        return "\(run.suite.title.lowercased()), \(run.models.count) model"
            + (run.models.count == 1 ? "" : "s") + "\nbest \(score)"
    }
}

// MARK: - Small parts

struct LabTabBar: View {
    @Binding var tab: LabTab

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            ForEach(LabTab.allCases) { candidate in
                LabChip(title: candidate.title, isOn: tab == candidate) { tab = candidate }
            }
        }
    }
}

/// A selectable pill. Not `Chip`, which is a static tag with no state — a
/// control that can be on has to look like one.
struct LabChip: View {
    let title: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Typography.caption)
                .foregroundStyle(isOn ? Theme.accentOn : Theme.textSecondary)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(
                    Capsule(style: .continuous)
                        .fill(isOn ? Theme.accentFill : Theme.surfaceSunken))
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }
}

/// The rail's inline actions: quieter than a `SecondaryButton`, which at this
/// width would be three lines of chrome per model.
struct LabMiniButton: View {
    let title: String
    let isOn: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Typography.monoSmall)
                .foregroundStyle(tint)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isOn ? Theme.accent2Soft : Theme.surfaceSunken))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .pointerCursor(isEnabled: isEnabled)
    }

    private var tint: Color {
        if !isEnabled { return Theme.textFaint }
        return isOn ? Theme.accent2 : Theme.textSecondary
    }
}

/// A flat progress bar. Hand-drawn rather than `ProgressView` so it renders in
/// the headless snapshot pass, like every other shape in this app.
struct LabBar: View {
    let fraction: Double
    var tone: Color = Theme.accent2Fill

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.surfaceSunken)
                Capsule().fill(tone)
                    .frame(width: max(0, min(1, fraction)) * proxy.size.width)
            }
        }
    }
}

struct LabNotice: View {
    enum Tone { case warning, danger }
    let text: String
    var tone: Tone = .warning

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: tone == .danger ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tone == .danger ? Theme.danger : Theme.warning)
            Text(text)
                .font(Typography.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.md)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(tone == .danger ? Theme.dangerSoft : Theme.warningSoft))
    }
}

/// Shown when the checkout that holds the case files cannot be found: the suites
/// are not bundled, deliberately (see `LabPaths`).
private struct LabRepoNotice: View {
    let lab: LabController
    let isSnapshot: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.warning)
            VStack(alignment: .leading, spacing: 6) {
                Text("The case files live in the repo, and this build cannot find its checkout. "
                    + "Point the lab at whisper-master to run the text and audio suites.")
                    .font(Typography.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !isSnapshot {
                    SecondaryButton(title: "Choose folder", icon: "folder") { choose() }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.md)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.warningSoft))
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use checkout"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Rejected rather than stored when the cases file is not in it: a wrong
        // folder should say so now, not at the start of a 15 minute run.
        if !lab.setRepoRoot(url) { NSSound.beep() }
    }
}
