import SwiftUI

/// Text section: everything about *how the finished text comes out* — where it
/// lands (auto-paste), how numbers/symbols/fillers are formatted, and the
/// optional on-device smart-cleanup model. One card under one label: these used
/// to be three labelled sections (Delivery / Formatting / Smart cleanup), which
/// spent three headers on five toggles that answer the same question.
struct TranscriptSettingsView: View {
    @Bindable var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            SectionLabel("Text")
            SettingsCard {
                SettingsRow("Auto-paste at cursor",
                            subtitle: "Insert the transcription wherever you're typing.") {
                    ThemeToggle(isOn: $state.autoPasteEnabled, label: "Auto-paste at cursor")
                }
                RowDivider()
                SettingsRow("Format numbers & symbols",
                            subtitle: "\"twenty five\" becomes \"25\", \"at gmail dot com\" becomes \"@gmail.com\".") {
                    ThemeToggle(isOn: $state.itnEnabled, label: "Format numbers & symbols")
                }
                RowDivider()
                SettingsRow("Remove filler words",
                            subtitle: "Strip \"um\", \"uh\", \"hmm\" and friends.") {
                    ThemeToggle(isOn: $state.removeFillerWordsEnabled, label: "Remove filler words")
                }
                RowDivider()
                SmartCleanupSettingsSection(state: state)
            }
        }
    }
}
