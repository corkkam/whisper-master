import SwiftUI

/// Recording section: push-to-talk key + the behavior toggles.
struct RecordingSettingsView: View {
    let viewModel: DictationViewModel
    @Bindable var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsCard {
                SettingsRow("Push-to-talk key",
                            subtitle: "Press and hold to dictate from anywhere on your Mac.") {
                    hotkeyMenu
                }
                RowDivider()
                SettingsRow("Hold-to-talk",
                            subtitle: "Hold the key while you speak. Off makes it a toggle.") {
                    ThemeToggle(isOn: $state.holdToTalkEnabled)
                }
                RowDivider()
                SettingsRow("Auto-paste at cursor",
                            subtitle: "Insert the transcription wherever you're typing.") {
                    ThemeToggle(isOn: $state.autoPasteEnabled)
                }
                RowDivider()
                SettingsRow("Play start / stop sound",
                            subtitle: "Subtle click when recording begins or ends.") {
                    ThemeToggle(isOn: $state.soundEnabled)
                }
            }

            SectionLabel("Appearance")

            SettingsCard {
                SettingsRow("Hide pill when idle",
                            subtitle: "The floating dictation pill stays hidden between recordings.") {
                    ThemeToggle(isOn: $state.hidePillWhenIdle)
                }
            }
        }
    }

    private var hotkeyMenu: some View {
        Menu {
            ForEach(HotkeyManager.HotkeyOption.allCases) { option in
                Button {
                    viewModel.updateHotkey(option)
                } label: {
                    if option == state.hotkey {
                        Label(option.displayName, systemImage: "checkmark")
                    } else {
                        Text(option.displayName)
                    }
                }
            }
        } label: {
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
                    .fill(Theme.surfaceElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                    .strokeBorder(Theme.strokeStrong, lineWidth: 1)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}
