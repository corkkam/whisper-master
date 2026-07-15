import SwiftUI

/// Recording section: push-to-talk key + the behavior toggles.
struct RecordingSettingsView: View {
    let viewModel: DictationViewModel
    @Bindable var state: AppState
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            SectionLabel("Recording")
            SettingsCard {
                SettingsRow("Push-to-talk key",
                            subtitle: "Press and hold to dictate from anywhere on your Mac.") {
                    hotkeyMenu
                }
                RowDivider()
                SettingsRow("Hold-to-talk",
                            subtitle: "Hold the key while you speak. Off makes it a toggle.") {
                    ThemeToggle(isOn: $state.holdToTalkEnabled, label: "Hold-to-talk")
                }
                RowDivider()
                SettingsRow("Play start / stop sound",
                            subtitle: "Subtle click when recording begins or ends.") {
                    ThemeToggle(isOn: $state.soundEnabled, label: "Play start / stop sound")
                }
            }

            SectionLabel("Reminders")

            SettingsCard {
                SettingsRow("Gentle reminders",
                            subtitle: "A quiet nudge in the notch if you haven't dictated in a while.") {
                    ThemeToggle(isOn: $state.remindersEnabled, label: "Gentle reminders")
                }
            }
        }
    }

    @ViewBuilder
    private var hotkeyMenu: some View {
        if isSnapshot {
            hotkeyLabel
        } else {
            Picker("", selection: Binding(
                get: { state.hotkey },
                set: { viewModel.updateHotkey($0) }
            )) {
                ForEach(HotkeyManager.HotkeyOption.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .tint(Theme.accent)
            .fixedSize()
        }
    }

    private var hotkeyLabel: some View {
        HStack(spacing: 9) {
            Text(state.hotkey.compactName)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                .strokeBorder(Theme.strokeStrong, lineWidth: 1)
        )
    }
}
