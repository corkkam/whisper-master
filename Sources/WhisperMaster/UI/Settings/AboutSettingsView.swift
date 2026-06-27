import AppKit
import SwiftUI

/// About section: brand header, version, and quick actions + platform facts.
struct AboutSettingsView: View {
    @Bindable var state: AppState
    var reopenOnboarding: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(spacing: 16) {
                BrandLogo(size: 64, cornerRadius: 16)
                VStack(spacing: 6) {
                    Text("Whisper Master")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Version \(AppInfo.version) · On-device dictation")
                        .font(Typography.mono)
                        .foregroundStyle(Theme.textSecondary)
                }
                HStack(spacing: 12) {
                    SecondaryButton(title: "Reveal models", icon: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([state.selectedEngine.localModelURL])
                    }
                    PrimaryButton(title: "Reopen onboarding", icon: "sparkles") {
                        reopenOnboarding()
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 34)
            .background(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 1)
            )

            SettingsCard {
                SettingsRow("Engine", subtitle: "On-device transcription.") {
                    Text("Whisper Master \(state.selectedEngine.displayName)")
                        .font(Typography.mono)
                        .foregroundStyle(Theme.textSecondary)
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
