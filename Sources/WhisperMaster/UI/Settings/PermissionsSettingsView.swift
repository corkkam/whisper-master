import SwiftUI

/// Permissions section: microphone + accessibility status, with grant buttons.
/// Status is driven by the parent (`SettingsView`), which polls and also
/// refreshes when the app becomes active so a System Settings toggle flips the
/// UI immediately when the user returns.
struct PermissionsSettingsView: View {
    let permissions: PermissionsManager
    let micGranted: Bool
    let micDenied: Bool
    let accessibilityGranted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard {
                permissionRow(
                    title: "Microphone",
                    subtitle: "Required to capture your voice.",
                    granted: micGranted,
                    denied: micDenied
                ) {
                    if micDenied || micGranted {
                        permissions.openMicrophoneSettings()
                    } else {
                        Task { _ = await permissions.requestMicrophone() }
                    }
                }
                RowDivider()
                permissionRow(
                    title: "Accessibility",
                    subtitle: "Lets Whisper paste text at your cursor.",
                    granted: accessibilityGranted,
                    denied: false
                ) {
                    // Add the app to the Accessibility list (system prompt) and
                    // open the pane so the toggle is one click away. Parent
                    // refresh on become-active / poll flips "Granted" live.
                    permissions.promptAccessibility()
                    permissions.openAccessibilitySettings()
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 11, weight: .semibold))
                Text("All processing happens on-device. Nothing is uploaded.")
                    .font(Typography.caption)
            }
            .foregroundStyle(Theme.textTertiary)
            .padding(.leading, 2)
        }
    }

    private func permissionRow(
        title: String,
        subtitle: String,
        granted: Bool,
        denied: Bool,
        action: @escaping () -> Void
    ) -> some View {
        SettingsRow(title, subtitle: subtitle) {
            if granted {
                HStack(spacing: 7) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Granted")
                        .font(Typography.caption)
                }
                .foregroundStyle(Theme.success)
                .accessibilityLabel("\(title) granted")
            } else {
                PrimaryButton(title: denied ? "Open Settings" : "Grant access", action: action)
            }
        }
    }
}
