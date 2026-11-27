import SwiftUI

/// What a page made of an account's own data shows while nobody is signed in:
/// Notes & Reminders, Connectors and Insights (`SettingsSection.requiresAccount`).
///
/// Owner decision D2, 2026-11-27: a person can dictate before sign-in, and sign-in
/// still gates sync, the assistant and the beta track. These pages are where the
/// per-account stores live, so signed out they say why and offer the way in,
/// instead of an editor whose notes would be written to a file nothing loads.
/// Shaped like `ComingSoonPanel`: it fills the same slot, under the page's own header.
struct SignInRequiredPanel: View {
    let section: SettingsSection
    var signIn: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(Theme.textTertiary)

            Text("Sign in to use this")
                .font(Typography.heading(20, relativeTo: .title3))
                .foregroundStyle(Theme.textPrimary)

            Text(Self.blurb(for: section))
                .font(Typography.body)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("Sign in", action: signIn)
                .primaryButton()
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(28)
        .glassCard()
    }

    /// What the account is for on this page, and the reassurance that matters:
    /// dictation does not need one.
    static func blurb(for section: SettingsSection) -> String {
        switch section {
        case .notes:
            return "Notes and reminders belong to your account, and sync across the Macs you sign in on. Dictation works without an account."
        case .connectors:
            return "Connectors link your calendar and other services to the assistant, and the assistant is part of your account. Dictation works without an account."
        case .insights:
            return "Insights are worked out per account from your dictations. Dictation works without an account."
        default:
            return "This page belongs to your account. Dictation works without an account."
        }
    }
}
