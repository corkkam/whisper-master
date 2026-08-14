import SwiftUI

/// The single "Settings" tab — every tunable preference in one place, grouped.
/// Consolidates what used to be the separate Recording and Transcript tabs, plus
/// the stray toggles that were embedded in content pages: "Back up my stats"
/// (previously on the Insights dashboard) and "Share usage data"
/// (previously on the About page). Each group carries its own `SectionLabel` so
/// the long page still reads as discrete settings groups.
struct GeneralSettingsView: View {
    let viewModel: DictationViewModel
    @Bindable var state: AppState
    /// Navigate to one of the folded sub-pages (Insights, Voice engine, …).
    var openSubPage: (SettingsSection) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            // Recording key + behavior toggles, then Reminders.
            RecordingSettingsView(viewModel: viewModel, state: state)

            // Delivery, Formatting, Smart cleanup.
            TranscriptSettingsView(state: state)

            // Assistant + Spoken answers, straight after Smart cleanup — they run on
            // the same on-device model, and they were previously stranded at the
            // bottom of the Connectors page, which is about accounts rather than
            // preferences.
            AssistantSettingsView(viewModel: viewModel, state: state)

            SectionLabel("Startup")
            SettingsCard {
                SettingsRow("Open at login",
                            subtitle: "Start Whisper Master automatically when you log in or restart your Mac. You can turn this off anytime — also in System Settings → General → Login Items.") {
                    ThemeToggle(
                        isOn: Binding(
                            get: { LaunchAtLogin.shared.isEnabled },
                            set: { LaunchAtLogin.shared.setEnabled($0) }
                        ),
                        label: "Open at login"
                    )
                }
                // Registered, but macOS is holding it until the user approves it —
                // the one state that isn't "on" and isn't an error either. Without
                // this the toggle sat off while the app was registered, and nothing
                // explained why it still didn't start after a restart.
                if LaunchAtLogin.shared.needsApproval {
                    HStack(spacing: 8) {
                        Text("Waiting for your approval in System Settings → General → Login Items.")
                            .font(Typography.caption)
                            .foregroundStyle(Theme.textSecondary)
                        Spacer(minLength: 8)
                        SecondaryButton(title: "Open Login Items") {
                            LaunchAtLogin.shared.openLoginItemsSettings()
                        }
                    }
                    .padding(.top, 6)
                }
                if let error = LaunchAtLogin.shared.lastError {
                    Text(error)
                        .font(Typography.caption)
                        .foregroundStyle(Theme.danger)
                        .padding(.top, 4)
                }
            }
            .onAppear { LaunchAtLogin.shared.refresh() }

            SectionLabel("Backup")
            SettingsCard {
                SettingsRow("Back up my stats",
                            subtitle: "Sync your Insights (words, speed, streaks) to your account so they're safe and follow you across Macs. Never your transcripts.") {
                    ThemeToggle(isOn: $state.usageSyncEnabled, label: "Back up my stats")
                }
            }

            SectionLabel("Analytics")
            SettingsCard {
                SettingsRow("Share usage data",
                            subtitle: "Which features you use, your app version, and macOS — linked to your account, never your transcripts or recordings.") {
                    ThemeToggle(isOn: $state.analyticsEnabled, label: "Share usage data")
                }
            }

            // The pages folded out of the sidebar live here, as a tappable list.
            SectionLabel("More")
            SettingsCard {
                ForEach(Array(SettingsSection.secondary.enumerated()), id: \.element) { index, section in
                    if index > 0 { RowDivider() }
                    // An unreleased page keeps its row and reads as a roadmap
                    // entry — dimmed, tagged, and inert. Dropping it instead would
                    // make the feature look cancelled rather than pending, and the
                    // sidebar's own rows already answer this way.
                    let isAvailable = section.isAvailable
                    Button { if isAvailable { openSubPage(section) } } label: {
                        HStack(spacing: 13) {
                            Image(systemName: section.icon)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(isAvailable ? Theme.accentText : Theme.textTertiary)
                                .frame(width: 24, alignment: .center)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 8) {
                                    Text(section.title)
                                        .font(Typography.headline).tracking(Typography.headlineTracking)
                                        .foregroundStyle(isAvailable ? Theme.textPrimary : Theme.textTertiary)
                                    if !isAvailable { RowTag("Soon") }
                                }
                                Text(section.subtitle)
                                    .font(Typography.subheadline)
                                    .foregroundStyle(Theme.textSecondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 12)
                            if isAvailable {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Theme.textTertiary)
                            }
                        }
                        .padding(.vertical, 14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isAvailable ? section.title : "\(section.title), coming soon")
                    .pointerCursor()
                    .disabled(!isAvailable)
                }
            }
        }
    }
}
