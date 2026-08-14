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
        Group {
            SettingsRow("Smart cleanup",
                        subtitle: "A local model tidies how you talk. \"three no wait four\" becomes \"four\". About 2.3 GB; nothing leaves your Mac.") {
                ThemeToggle(isOn: $state.llmCleanupEnabled)
            }

            if state.llmCleanupEnabled {
                RowDivider()
                // The tag, not a word at the end of the subtitle: "Experimental."
                // as the last sentence of four lines was read by nobody, and this
                // is the one toggle here that can drop a word.
                SettingsRow("Polish my English",
                            tag: "Experimental",
                            subtitle: "Rewrites your dictation into clear English. Facts, names, and numbers stay exact.") {
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
