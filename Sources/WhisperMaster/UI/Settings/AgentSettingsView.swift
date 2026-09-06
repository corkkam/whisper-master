import SwiftUI

/// The Coding agents sub-page: the agent key and its behaviour toggles.
///
/// This lived as a section of the main Settings page, second from the top, which
/// put four niche controls (they only do anything on a Mac running kunai) above
/// the settings everyone touches. It is a sub-page now so the main page stays
/// short; the feature's own docs live in the root `CLAUDE.md` under "Coding
/// agents in the notch".
struct AgentSettingsView: View {
    @Bindable var state: AppState
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
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

    @ViewBuilder
    private var agentHotkeyMenu: some View {
        if isSnapshot {
            agentHotkeyLabel
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
            Text(state.agentDefaultDirectory.isEmpty ? "\u{2014}" : state.agentDefaultDirectory)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
        } else {
            TextField("~/code/my-project", text: $state.agentDefaultDirectory)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .frame(width: 260)
        }
    }

    /// Static stand-in for the picker under the headless renderer, showing the
    /// value that is actually set rather than the push-to-talk key.
    private var agentHotkeyLabel: some View {
        HStack(spacing: 9) {
            Text(state.agentHotkey?.compactName ?? "Off")
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
