import AppKit
import SwiftUI

/// About section: a left-aligned brand lockup with quick actions, then a clean
/// hairline list of facts — consistent with the rest of the Daylight pages.
struct AboutSettingsView: View {
    @Bindable var state: AppState
    var reopenOnboarding: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack(spacing: 18) {
                BrandLogo(size: 58, cornerRadius: 14)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Whisper Master")
                        .font(Typography.sans(23, .bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Version \(AppInfo.version) · On-device dictation")
                        .font(Typography.mono)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 12) {
                SecondaryButton(title: "Reveal models", icon: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([state.selectedEngine.localModelURL])
                }
                PrimaryButton(title: "Reopen onboarding", icon: "sparkles") {
                    reopenOnboarding()
                }
            }

            SettingsCard {
                SettingsRow("Engine", subtitle: "On-device transcription.") {
                    Text(state.selectedEngine.displayName)
                        .font(Typography.mono)
                        .foregroundStyle(Theme.textSecondary)
                }
                RowDivider()
                SettingsRow("Privacy", subtitle: "Your audio never leaves this Mac.") {
                    Text("On-device")
                        .font(Typography.mono)
                        .foregroundStyle(Theme.success)
                }
                RowDivider()
                SettingsRow("Platform", subtitle: "Built for Apple Silicon.") {
                    Text("macOS 14+ · arm64")
                        .font(Typography.mono)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }
}
