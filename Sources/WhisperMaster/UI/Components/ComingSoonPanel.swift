import SwiftUI

/// The panel shown in place of a section this build hasn't released yet.
///
/// Only reachable defensively — the sidebar row for an unreleased section is
/// disabled (see `SettingsView.navRow`) — but a stale
/// `AppState.requestedSettingsSection` must render *something* honest rather
/// than an unfinished surface. It says what's coming and nothing more; no CTA,
/// because there's nothing for the user to do about it.
struct ComingSoonPanel: View {
    let section: SettingsSection

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: section.icon)
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(Theme.textTertiary)

            Text("Coming soon")
                .font(Typography.heading(20, relativeTo: .title3))
                .foregroundStyle(Theme.textPrimary)

            Text(Self.blurb(for: section))
                .font(Typography.body)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(28)
        .glassCard()
    }

    /// Present tense about what it will do, past tense about nothing. Avoids
    /// promising a date we haven't committed to.
    private static func blurb(for section: SettingsSection) -> String {
        switch section {
        case .connectors:
            return "Linking your calendar and other services so Whisper can brief you on your day and act on what you say. It's in testing now and will arrive in a future update."
        case .notes:
            return "Capturing notes and reminders by voice, kept on your Mac and synced across the ones you own. It's in testing now and will arrive in a future update."
        default:
            return "This one's still in testing and will arrive in a future update."
        }
    }
}
