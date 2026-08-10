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
                if showsFnConflictHint {
                    fnConflictHint
                } else if showsFnClaimedNote {
                    fnClaimedNote
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

            SectionLabel("Coding agents")

            SettingsCard {
                SettingsRow(
                    "Talk to a coding agent",
                    subtitle: agentKeySubtitle
                ) {
                    agentHotkeyMenu
                }
                if state.agentHotkey != nil, state.agentHotkey == state.hotkey {
                    agentKeyCollisionHint
                }
                RowDivider()
                SettingsRow(
                    "Show full replies",
                    subtitle: "When a turn finishes, drop the whole reply out of the notch "
                        + "instead of one line. Click a reply to expand it either way."
                ) {
                    ThemeToggle(
                        isOn: $state.agentExpandedRepliesEnabled, label: "Show full replies")
                }
                RowDivider()
                SettingsRow(
                    "Tell me about other sessions",
                    subtitle: "When an agent you aren't watching needs a permission or "
                        + "finishes, the notch says so once. Tap it to go there."
                ) {
                    ThemeToggle(
                        isOn: $state.agentNudgesEnabled, label: "Tell me about other sessions")
                }
                RowDivider()
                SettingsRow(
                    "Project folder",
                    subtitle: "Where a new session opens when nothing is running. "
                        + "Leave empty to reuse the folder of a session you already have."
                ) {
                    agentDirectoryField
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

    /// Shown once the app has taken the Globe key and the setting actually reads back
    /// as ours. **Changing a system-wide preference silently would be the wrong kind
    /// of helpful** — the note is how the user finds out it happened, and the button
    /// beside it is how they undo it.
    private var showsFnClaimedNote: Bool {
        _ = fnConflictToken
        return state.hotkey == .fn && FnKeyBehavior.claimedPreviousBehavior != nil
    }

    private var fnClaimedNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.success)
            VStack(alignment: .leading, spacing: 8) {
                Text("The Globe key is yours alone — Whisper Master turned off "
                    + "\(FnKeyBehavior.claimDescription) so it can't fire on the "
                    + "double-tap that latches hands-free.")
                    .font(Typography.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !isSnapshot {
                    Button("Give it back to macOS") {
                        FnKeyBehavior.restoreSystemFnBehavior()
                        fnConflictToken += 1
                        Analytics.shared.send(.fnKeyClaim(restored: true))
                    }
                    .textButton()
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                .fill(Theme.successSoft)
        )
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

    /// Two monitors on one physical key would fight, so the agent key stands down and
    /// dictation keeps it. Said out loud, because a picker showing a key that quietly
    /// does nothing is worse than one that admits it.
    private var agentKeyCollisionHint: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.warning)
            Text("That's already your push-to-talk key, so the agent key is off. "
                + "Pick a different one.")
                .font(Typography.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Says what the key does, and what is on the other end of it, because "talk to
    /// a coding agent" means nothing on a Mac with no agent running.
    private var agentKeySubtitle: String {
        let base = "Hold it and speak. Your words go to a Claude Code session on this Mac "
            + "instead of being typed."
        return state.agents.isAvailable
            ? base
            : base + " Nothing is running right now, so this stays quiet until there is."
    }

    @ViewBuilder
    private var agentHotkeyMenu: some View {
        if isSnapshot {
            hotkeyLabel
        } else {
            Picker("", selection: Binding(
                get: { state.agentHotkey },
                set: { state.agentHotkey = $0 }
            )) {
                // Off is a real choice, and the default: reserving a modifier on
                // every Mac for a server almost nobody runs would be an imposition.
                Text("Off").tag(HotkeyManager.HotkeyOption?.none)
                ForEach(HotkeyManager.HotkeyOption.allCases) { option in
                    Text(option.displayName).tag(HotkeyManager.HotkeyOption?.some(option))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .tint(Theme.accent)
            .fixedSize()
        }
    }

    @ViewBuilder
    private var agentDirectoryField: some View {
        if isSnapshot {
            Text(state.agentDefaultDirectory.isEmpty ? "—" : state.agentDefaultDirectory)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
        } else {
            TextField("~/code/my-project", text: $state.agentDefaultDirectory)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .frame(width: 260)
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
