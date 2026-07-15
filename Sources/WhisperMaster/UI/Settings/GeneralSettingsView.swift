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
        }
    }
}
