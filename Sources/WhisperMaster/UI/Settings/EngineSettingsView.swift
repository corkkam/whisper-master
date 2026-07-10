import AppKit
import SwiftUI

/// Voice-engine section: engine selection, install status + model location, and
/// the custom-vocabulary ("Words to get right") editor.
struct EngineSettingsView: View {
    let viewModel: DictationViewModel
    @Bindable var state: AppState
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            ForEach(TranscriberEngine.allCases) { engine in
                engineCard(engine)
            }

            SectionLabel("Formatting")
            formattingCard

            SectionLabel("Smart cleanup")
            SmartCleanupSettingsSection(state: state)

            SectionLabel("Words to get right")
            vocabularyCard
        }
    }

    // MARK: - Engine card

    private func engineCard(_ engine: TranscriberEngine) -> some View {
        let isSelected = state.selectedEngine == engine
        return Button {
            viewModel.selectEngine(engine)
        } label: {
            HStack(spacing: 16) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(isSelected ? Theme.accent : Theme.textTertiary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(engine.displayName)
                        .font(Typography.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Text(engine.subtitle)
                        .font(Typography.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 5) {
                    Text(engine.estimatedDownloadSize)
                        .font(Typography.sans(16, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    engineStatusInline(engine)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .fill(Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .strokeBorder(isSelected ? Theme.accent.opacity(0.5) : Theme.stroke, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!engineSelectionEnabled)
        .opacity(engineSelectionEnabled ? 1 : 0.55)
    }

    // MARK: - Engine status (inline, right side of the engine card)

    /// Live readiness shown inside the engine card, so status has no orphaned
    /// section of its own: a spinner + progress while preparing, else a dot +
    /// "Ready" / "Not installed".
    @ViewBuilder
    private func engineStatusInline(_ engine: TranscriberEngine) -> some View {
        if state.selectedEngine == engine, state.preparingEngine == engine {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(modelStatusText)
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        } else {
            HStack(spacing: 6) {
                StatusDot(color: engine.isInstalled ? Theme.success : Theme.textTertiary, size: 8)
                Text(engine.isInstalled ? "Ready" : "Not installed")
                    .font(Typography.caption)
                    .foregroundStyle(engine.isInstalled ? Theme.success : Theme.textTertiary)
            }
        }
    }

    // MARK: - Vocabulary card

    private var formattingCard: some View {
        SettingsCard {
            SettingsRow("Format numbers & symbols",
                        subtitle: "Writes spoken numbers and symbols short. \u{201C}twenty five\u{201D} becomes \u{201C}25\u{201D}, and \u{201C}at gmail dot com\u{201D} becomes \u{201C}@gmail.com\u{201D}. Runs instantly on-device.") {
                ThemeToggle(isOn: $state.itnEnabled)
            }
        }
    }

    private var vocabularyCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("Names, acronyms, or jargon the app keeps mishearing. It listens harder for these, so \u{201C}RAG\u{201D} stops coming out as \u{201C}rack\u{201D}.")
                    .font(Typography.body)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                VocabularyEditor(terms: $state.customVocabulary)

                Text("Type a word and press Return. To fix a specific mishearing, add a colon, like RAG: rack.")
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                RowDivider()

                SettingsRow("Learn from corrections",
                            subtitle: "Fix a misheard word right after it's pasted and it's added here automatically.") {
                    ThemeToggle(isOn: $state.learnCorrectionsEnabled)
                }
            }
            .padding(.vertical, 18)
        }
    }

    // MARK: - Derived

    private var engineSelectionEnabled: Bool {
        switch state.phase {
        case .idle, .failed: return true
        case .preparingModels, .recording, .stopping: return false
        }
    }

    private var modelStatusText: String {
        if let download = state.download, state.preparingEngine == state.selectedEngine {
            return "\(download.detail) \(Int(download.fractionCompleted * 100))%"
        }
        if state.preparingEngine == state.selectedEngine {
            return state.selectedEngine.isInstalled ? "Loading…" : "Downloading…"
        }
        if state.preparedEngine == state.selectedEngine { return "Ready" }
        return state.selectedEngine.isInstalled ? "Ready on this Mac" : "Setup needed"
    }
}
