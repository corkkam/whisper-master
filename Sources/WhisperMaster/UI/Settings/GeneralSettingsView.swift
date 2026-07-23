import SwiftUI

/// The single "Settings" tab — every tunable preference in one place, grouped.
/// Consolidates what used to be the separate Recording and Transcript tabs, plus
/// the stray toggles that were embedded in content pages: "Back up my stats"
/// (previously on the Insights dashboard) and "Share anonymous usage"
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

            SectionLabel("Backup")
            SettingsCard {
                SettingsRow("Back up my stats",
                            subtitle: "Sync your Insights (words, speed, streaks) to your account so they're safe and follow you across Macs. Never your transcripts.") {
                    ThemeToggle(isOn: $state.usageSyncEnabled, label: "Back up my stats")
                }
            }

            SectionLabel("Analytics")
            SettingsCard {
                SettingsRow("Share anonymous usage",
                            subtitle: "App version, macOS, and feature counts, never your transcripts. Helps improve the app.") {
                    ThemeToggle(isOn: $state.analyticsEnabled, label: "Share anonymous usage")
                }
            }

            // The pages folded out of the sidebar live here, as a tappable list.
            SectionLabel("More")
            SettingsCard {
                ForEach(Array(SettingsSection.secondary.enumerated()), id: \.element) { index, section in
                    if index > 0 { RowDivider() }
                    Button { openSubPage(section) } label: {
                        HStack(spacing: 13) {
                            Image(systemName: section.icon)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(Theme.accentText)
                                .frame(width: 24, alignment: .center)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(section.title)
                                    .font(Typography.headline)
                                    .foregroundStyle(Theme.textPrimary)
                                Text(section.subtitle)
                                    .font(Typography.subheadline)
                                    .foregroundStyle(Theme.textSecondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 12)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.textTertiary)
                        }
                        .padding(.vertical, 14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
