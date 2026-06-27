import AppKit
import SwiftUI

/// Voice-engine section: engine selection, install status + model location, and
/// the custom-vocabulary ("Words to get right") editor.
struct EngineSettingsView: View {
    let viewModel: DictationViewModel
    @Bindable var state: AppState

    /// Raw editor text for the custom-words field. Kept separate from the parsed
    /// `[String]` glossary so typing newlines/blank lines isn't fought by a
    /// normalizing binding — flows draft → state only, never back.
    @State private var vocabularyDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            ForEach(TranscriberEngine.allCases) { engine in
                engineCard(engine)
            }

            SectionLabel("Engine status")
            statusCard

            SectionLabel("Words to get right")
            vocabularyCard
        }
        .onAppear {
            vocabularyDraft = state.customVocabulary.joined(separator: "\n")
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
                VStack(alignment: .trailing, spacing: 3) {
                    Text(engine.estimatedDownloadSize)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(engine.isInstalled ? "Installed" : "Not installed")
                        .font(Typography.caption)
                        .foregroundStyle(engine.isInstalled ? Theme.success : Theme.textTertiary)
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

    // MARK: - Status card

    private var statusCard: some View {
        SettingsCard {
            SettingsRow("Status") {
                engineStatusBadge
            }
            RowDivider()
            SettingsRow("Model location") {
                HStack(spacing: 12) {
                    Text("~/Library/…/FluidAudio/Models")
                        .font(Typography.mono)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    SecondaryButton(title: "Reveal", icon: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([state.selectedEngine.localModelURL])
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var engineStatusBadge: some View {
        if state.preparingEngine == state.selectedEngine {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(modelStatusText)
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        } else {
            let ready = state.selectedEngine.isInstalled
            HStack(spacing: 8) {
                StatusDot(color: ready ? Theme.success : Theme.textTertiary, size: 9)
                Text(ready ? "Ready" : "Setup needed")
                    .font(Typography.caption)
                    .foregroundStyle(ready ? Theme.success : Theme.textSecondary)
            }
        }
    }

    // MARK: - Vocabulary card

    private var vocabularyCard: some View {
        SettingsCard(contentPadding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Names, acronyms, or jargon the app keeps mishearing — one per line. It listens harder for these, so e.g. \u{201C}RAG\u{201D} stops coming out as \u{201C}rack\u{201D}.")
                    .font(Typography.body)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                ZStack(alignment: .topLeading) {
                    if vocabularyDraft.isEmpty {
                        Text("RAG\nParakeet\nLyzr")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $vocabularyDraft)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(Theme.textPrimary)
                        .scrollContentBackground(.hidden)
                        .frame(height: 96)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 5)
                        .onChange(of: vocabularyDraft) { _, text in
                            updateVocabulary(from: text)
                        }
                }
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.canvas)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 1)
                )

                Text("One word or phrase per line. Saved automatically.")
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    /// Parse the raw editor text into the stored glossary (one term per line,
    /// blanks ignored). One-way: draft → state.
    private func updateVocabulary(from text: String) {
        state.customVocabulary = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
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
