import SwiftUI

/// Settings rows for the optional on-device "smart cleanup" model: the opt-in
/// toggle plus its download / readiness status. Emits rows, not a card — it
/// lives inside `TranscriptSettingsView`'s single "Text" card.
///
/// This is the **only** surface that shows the model's download progress — by
/// design it never appears in the notch or the tray (the notch gets a single
/// "ready" banner on completion, nothing more).
struct SmartCleanupSettingsSection: View {
    @Bindable var state: AppState

    var body: some View {
        // dev's container (the card wrapper moved out to the caller); this
        // branch's copy, because the model underneath changed.
        Group {
            // **The name is a licence term, not a flourish.** S1-mini is Apache 2.0
            // plus one condition: wherever it is used it keeps the name "S1-mini by
            // Superwhisper", with that capitalization. Don't shorten it here.
            SettingsRow("Smart cleanup",
                        subtitle: "A local model tidies how you talk, using S1-mini by Superwhisper. \u{201C}three no wait four\u{201D} becomes \u{201C}four\u{201D}. About 300 MB; nothing leaves your Mac.") {
                ThemeToggle(isOn: $state.llmCleanupEnabled)
            }

            if state.llmCleanupEnabled {
                RowDivider()
                // No longer promises a rewrite: S1-mini normalises, it does not
                // restructure sentences the way a general instruct model tried to.
                // Claiming a rewrite it will not perform is worse than the smaller
                // promise, so the name changed with the model.
                SettingsRow("Formal styling",
                            subtitle: "Cleans up towards formal writing rather than everyday speech. Your words, facts, names, and numbers stay exact.") {
                    ThemeToggle(isOn: $state.llmGrammarPolishEnabled)
                }
                RowDivider()
                statusRow
            }
        }
    }

    /// The cleanup model's readiness. Rendered as a quiet status line, not a
    /// settings row — it's ancillary info, so no bold "Status" title competing
    /// with the toggles above it.
    @ViewBuilder
    private var statusRow: some View {
        if let download = state.cleanupModelDownload {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(download.detail)
                        .font(Typography.caption)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Text("\(Int(download.fractionCompleted * 100))%")
                        .font(Typography.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                ProgressView(value: download.fractionCompleted)
                    .tint(Theme.accent)
            }
            .padding(.vertical, 13)
        } else {
            HStack(spacing: 8) {
                if state.cleanupModelReady {
                    StatusDot(color: Theme.success, size: 7)
                    Text("Model ready")
                        .foregroundStyle(Theme.textSecondary)
                } else if state.cleanupModelFailed {
                    StatusDot(color: Theme.accent, size: 7)
                    Text("Couldn\u{2019}t load the model")
                        .foregroundStyle(Theme.textSecondary)
                    Spacer(minLength: 8)
                    Button("Retry") { state.cleanupRetryRequested = true }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.accent)
                        .pointerCursor()
                } else {
                    ProgressView().controlSize(.small)
                    Text("Preparing the model\u{2026}")
                        .foregroundStyle(Theme.textSecondary)
                }
                if !state.cleanupModelFailed { Spacer(minLength: 0) }
            }
            .font(Typography.caption)
            .padding(.vertical, 12)
        }
    }
}
