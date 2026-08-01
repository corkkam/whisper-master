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
                            subtitle: "Press and hold to dictate from anywhere on your Mac. "
                                + "Double-tap to keep dictating hands-free; double-tap again to stop.") {
                    hotkeyMenu
                }
                if showsFnConflictHint { fnConflictHint }
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

            SectionLabel("Notch")

            SettingsCard {
                SettingsRow("Quick actions on hover",
                            subtitle: "Rest the pointer on the notch to see what's due and the notes you touched last. Never while you're dictating.") {
                    ThemeToggle(isOn: $state.quickActionsEnabled, label: "Quick actions on hover")
                }
                RowDivider()
                SettingsRow("Gentle reminders",
                            subtitle: "A quiet nudge in the notch if you haven't dictated in a while.") {
                    ThemeToggle(isOn: $state.remindersEnabled, label: "Gentle reminders")
                }
            }
        }
    }

    // MARK: - fn key conflict

    /// The fn key is the default, but macOS may already act on it (emoji picker,
    /// input-source switch, its own dictation on a double-press). We can't consume
    /// the key without a HID tap that would break fn+F-key and fn+arrow, so the
    /// honest fix is to point at the one system setting that clears it.
    private var showsFnConflictHint: Bool {
        // `fnConflictToken` is read for its dependency, not its value: the answer
        // comes from `CFPreferences`, which SwiftUI cannot observe, so touching the
        // token is what re-evaluates this after our own write.
        _ = fnConflictToken
        return state.hotkey == .fn && FnKeyBehavior.conflictsWithPushToTalk
    }

    /// Bumped after we write the system pref so `showsFnConflictHint` — which reads
    /// `CFPreferences`, not observable state — is re-evaluated and the hint clears.
    @State private var fnConflictToken = 0
    /// Set when the write went through but the setting didn't read back as changed,
    /// so we say "log out" instead of pretending it worked.
    @State private var fnFixNeedsLogout = false

    private var fnConflictHint: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.warning)
            VStack(alignment: .leading, spacing: 8) {
                Text("macOS still uses the Globe key — \(FnKeyBehavior.conflictDescription), "
                    + "including on the double-tap that latches hands-free. "
                    + "Turn that off and the key is yours alone.")
                    .font(Typography.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if fnFixNeedsLogout {
                    Text("Set, but macOS is still holding the old value — "
                        + "it'll take effect after you log out and back in.")
                        .font(Typography.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !isSnapshot {
                    HStack(spacing: 12) {
                        Button("Turn it off") {
                            fnFixNeedsLogout = !FnKeyBehavior.stopSystemFromUsingFnKey()
                            fnConflictToken += 1
                        }
                        .secondaryButton()
                        Button("Open Keyboard settings") { FnKeyBehavior.openKeyboardSettings() }
                            .textButton()
                    }
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                .fill(Theme.warningSoft)
        )
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
