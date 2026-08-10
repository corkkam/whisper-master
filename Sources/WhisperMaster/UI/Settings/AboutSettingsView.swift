import AppKit
import SwiftUI

/// About section: a left-aligned brand lockup with quick actions, then a clean
/// hairline list of facts — consistent with the rest of the Daylight pages.
struct AboutSettingsView: View {
    @Bindable var state: AppState
    var reopenOnboarding: () -> Void = {}
    var checkForUpdates: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack(spacing: 18) {
                BrandLogo(size: 58, cornerRadius: 14)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: Theme.Space.sm) {
                        Text("Whisper Master")
                            .font(Typography.sans(23, .bold))
                            .foregroundStyle(Theme.textPrimary)
                        // Only a non-shipping build wears a badge; stable says
                        // nothing (`UpdateChannel.buildLabel`). `fixedSize`
                        // keeps it from being squeezed when the title wraps in
                        // a narrow window.
                        if let label = AppInfo.buildChannel.buildLabel {
                            Chip(label)
                                .fixedSize()
                                .accessibilityLabel("\(label) build")
                        }
                    }
                    Text("Version \(AppInfo.version) · On-device dictation")
                        .font(Typography.mono)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 12) {
                PrimaryButton(title: "Check for updates", icon: "arrow.triangle.2.circlepath") {
                    checkForUpdates()
                }
                SecondaryButton(title: "Reveal models", icon: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([state.selectedEngine.localModelURL])
                }
                SecondaryButton(title: "Reopen onboarding", icon: "sparkles") {
                    reopenOnboarding()
                }
                Spacer(minLength: 0)
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
