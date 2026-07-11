import SwiftUI

/// Transcript section: everything about *how the finished text comes out* —
/// where it lands (auto-paste), how numbers/symbols/fillers are formatted, and
/// the optional on-device smart-cleanup model. These all used to live on the
/// Engine panel; they read more naturally grouped as "the output" here, leaving
/// the Engine panel to just the model + vocabulary.
struct TranscriptSettingsView: View {
    @Bindable var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            SectionLabel("Delivery")
            SettingsCard {
                SettingsRow("Auto-paste at cursor",
                            subtitle: "Insert the transcription wherever you're typing.") {
                    ThemeToggle(isOn: $state.autoPasteEnabled, label: "Auto-paste at cursor")
                }
            }

            SectionLabel("Formatting")
            formattingCard

            SectionLabel("Smart cleanup")
            SmartCleanupSettingsSection(state: state)
        }
    }

    private var formattingCard: some View {
        SettingsCard {
            SettingsRow("Format numbers & symbols",
                        subtitle: "Writes spoken numbers and symbols short. \u{201C}twenty five\u{201D} becomes \u{201C}25\u{201D}, and \u{201C}at gmail dot com\u{201D} becomes \u{201C}@gmail.com\u{201D}. Runs instantly on-device.") {
                ThemeToggle(isOn: $state.itnEnabled, label: "Format numbers & symbols")
            }
            RowDivider()
            SettingsRow("Remove filler words",
                        subtitle: "Strip \"um\", \"uh\", \"hmm\" and friends from the transcript.") {
                ThemeToggle(isOn: $state.removeFillerWordsEnabled, label: "Remove filler words")
            }
        }
    }
}
