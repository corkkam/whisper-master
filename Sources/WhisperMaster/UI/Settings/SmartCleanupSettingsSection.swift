import SwiftUI

/// Settings home for the optional on-device "smart cleanup" model: the opt-in
/// toggle plus its download / readiness status.
///
/// This is the **only** surface that shows the model's download progress — by
/// design it never appears in the notch or the tray (the notch gets a single
/// "ready" banner on completion, nothing more). Kept as its own small view so
/// `EngineSettingsView` stays focused.
struct SmartCleanupSettingsSection: View {
    @Bindable var state: AppState

    var body: some View {
        SettingsCard {
            SettingsRow("Smart cleanup",
                        subtitle: "Uses a local model to clean up how you talk. \u{201C}three no wait four\u{201D} becomes \u{201C}four\u{201D}. About 1.8 GB, downloads in the background. Dictation works right away, and nothing leaves your Mac.") {
                ThemeToggle(isOn: $state.llmCleanupEnabled)
            }

            if state.llmCleanupEnabled {
                RowDivider()
                SettingsRow("Polish my English",
                            subtitle: "Rewrites your dictation into clear, grammatical English instead of only removing fillers. Your facts, names, and numbers stay exact. Experimental.") {
                    ThemeToggle(isOn: $state.llmGrammarPolishEnabled)
                }
                RowDivider()
                statusRow
            }
        }
    }

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
        } else if state.cleanupModelReady {
            SettingsRow("Status") {
                HStack(spacing: 8) {
                    StatusDot(color: Theme.success, size: 9)
                    Text("Ready")
                        .font(Typography.caption)
                        .foregroundStyle(Theme.success)
                }
            }
        } else if state.cleanupModelFailed {
            SettingsRow("Status") {
                HStack(spacing: 8) {
                    StatusDot(color: Theme.accent, size: 9)
                    Text("Couldn\u{2019}t load the model")
                        .font(Typography.caption)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Button("Retry") { state.cleanupRetryRequested = true }
                        .buttonStyle(.plain)
                        .font(Typography.caption.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
        } else {
            SettingsRow("Status") {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Preparing\u{2026}")
                        .font(Typography.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }
}
