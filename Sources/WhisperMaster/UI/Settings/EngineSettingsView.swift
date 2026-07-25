import AppKit
import SwiftUI

/// Voice-engine section: the on-device model's status card, and the
/// custom-vocabulary ("Words to get right") editor + correction learning.
struct EngineSettingsView: View {
    let viewModel: DictationViewModel
    @Bindable var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            SectionLabel("Model")
            engineCard

            SectionLabel("Words to get right")
            vocabularyCard
        }
    }

    // MARK: - Engine status card

    /// The transcription engine has a single case, so this is an info/status
    /// card, not a selectable radio (there's nothing to pick between): the model
    /// name, what it's good at, its download size, and live readiness.
    private var engineCard: some View {
        let engine = state.selectedEngine
        return HStack(spacing: Theme.Space.lg) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Theme.accentSoft)
                    .frame(width: 42, height: 42)
                Image(systemName: "waveform")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(engine.displayName)
                    .font(Typography.headline).tracking(Typography.headlineTracking)
                    .foregroundStyle(Theme.textPrimary)
                Text("Best-accuracy on-device")
                    .font(Typography.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: Theme.Space.md)
            VStack(alignment: .trailing, spacing: 5) {
                Text(engine.estimatedDownloadSize)
                    .font(Typography.sans(16, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                engineStatusInline(engine)
            }
        }
        .padding(Theme.Space.lg)
        .frame(maxWidth: .infinity)
        .card()
    }

    // MARK: - Engine status (inline, right side of the engine card)

    /// Live readiness shown inside the status card: a spinner + progress while
    /// preparing, else a dot + "Ready" / "Not installed".
    @ViewBuilder
    private func engineStatusInline(_ engine: TranscriberEngine) -> some View {
        if state.preparingEngine == engine {
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

    private var vocabularyCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("Names, acronyms, or jargon the app keeps mishearing. It fixes these in the finished text, so \u{201C}RAG\u{201D} stops coming out as \u{201C}rack\u{201D}.")
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
                    ThemeToggle(isOn: $state.learnCorrectionsEnabled, label: "Learn from corrections")
                }
            }
            .padding(.vertical, 18)
        }
    }

    // MARK: - Derived

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
