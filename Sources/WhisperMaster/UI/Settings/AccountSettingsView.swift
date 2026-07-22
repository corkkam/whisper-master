import AppKit
import ClerkKit
import SwiftUI

/// The Account section: shows who's signed in (avatar, name, email, member
/// since) and lets them sign out — which re-locks the app behind the Clerk gate.
///
/// Live account state is read reactively from the injected `Clerk` (`@Observable`,
/// exactly like `AuthGateView`). The settings window injects
/// `.environment(Clerk.shared)`; the headless snapshot renderer does not, so the
/// snapshot path uses a static placeholder and never resolves that environment.
struct AccountSettingsView: View {
    @Bindable var state: AppState
    var signOut: () -> Void = {}

    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        if isSnapshot {
            // ImageRenderer can't reach the Clerk environment (it isn't injected
            // in snapshot mode) and can't load remote avatars — show a stable
            // stand-in so the panel still renders in the UI snapshot loop.
            AccountProfile(
                displayName: "Alex Rivera",
                email: "alex@whispermaster.app",
                memberSince: "Joined June 2026",
                accountID: "user_2aBcDeFgHiJkLmN",
                imageURL: nil,
                signOut: {}
            )
        } else {
            LiveAccountSettingsView(signOut: signOut)
        }
    }
}

/// The real, Clerk-backed account panel. Kept separate from `AccountSettingsView`
/// so `@Environment(Clerk.self)` is only ever resolved off the live (non-snapshot)
/// path — resolving a missing observable environment would trap.
private struct LiveAccountSettingsView: View {
    var signOut: () -> Void
    @Environment(Clerk.self) private var clerk

    var body: some View {
        if let user = clerk.user {
            AccountProfile(
                displayName: Self.displayName(for: user),
                email: Self.email(for: user),
                memberSince: Self.memberSince(for: user),
                accountID: user.id,
                imageURL: Self.imageURL(for: user),
                signOut: signOut
            )
        } else {
            // No live Clerk user. The sign-in gate always holds until a real
            // session loads (there is no bypass in any build), so this panel is
            // out of reach without an account — this is a defensive fallback only.
            NotSignedInAccount()
        }
    }

    private static func displayName(for user: User?) -> String {
        guard let user else { return "Signed in" }
        let name = [user.firstName, user.lastName]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if !name.isEmpty { return name }
        if let username = user.username, !username.isEmpty { return username }
        // Fall back to the local-part of the email so there's always a name.
        if let email = user.primaryEmailAddress?.emailAddress ?? user.emailAddresses.first?.emailAddress {
            return String(email.prefix(while: { $0 != "@" }))
        }
        return "Signed in"
    }

    private static func email(for user: User?) -> String {
        user?.primaryEmailAddress?.emailAddress
            ?? user?.emailAddresses.first?.emailAddress
            ?? "—"
    }

    private static func memberSince(for user: User?) -> String? {
        guard let user else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return "Joined \(formatter.string(from: user.createdAt))"
    }

    private static func imageURL(for user: User?) -> URL? {
        guard let user, user.hasImage, !user.imageUrl.isEmpty else { return nil }
        return URL(string: user.imageUrl)
    }
}

/// Defensive fallback shown on the live path when there is no Clerk user. The
/// sign-in gate always holds until a real session loads (there is no bypass in
/// any build), so in practice this panel is never reachable without an account.
private struct NotSignedInAccount: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack(spacing: 18) {
                ZStack {
                    Circle().fill(Theme.accentSoft)
                    Image(systemName: "lock.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
                .frame(width: 58, height: 58)
                .overlay(Circle().strokeBorder(Theme.stroke, lineWidth: 1))

                VStack(alignment: .leading, spacing: 5) {
                    Text("Not signed in")
                        .font(Typography.sans(23, .bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Sign in to use Whisper Master")
                        .font(Typography.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                    HStack(spacing: 6) {
                        StatusDot(color: Theme.warning)
                        Text("No account attached")
                            .font(Typography.caption)
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .padding(.top, 2)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

/// The presentation-only account card — takes plain values so both the live and
/// snapshot paths share one layout.
private struct AccountProfile: View {
    let displayName: String
    let email: String
    var memberSince: String?
    var accountID: String?
    var imageURL: URL?
    var signOut: () -> Void

    @State private var showSignOutConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            // Identity header: avatar + name + email.
            HStack(spacing: 18) {
                AccountAvatar(displayName: displayName, imageURL: imageURL)
                VStack(alignment: .leading, spacing: 5) {
                    Text(displayName)
                        .font(Typography.sans(23, .bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(email)
                        .font(Typography.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                    HStack(spacing: 6) {
                        StatusDot(color: Theme.success)
                        Text("Signed in")
                            .font(Typography.caption)
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .padding(.top, 2)
                }
                Spacer(minLength: 0)
            }

            // Account facts.
            SettingsCard {
                SettingsRow("Email", subtitle: "Where sign-in links are sent.") {
                    Text(email)
                        .font(Typography.mono)
                        .foregroundStyle(Theme.textSecondary)
                }
                if let memberSince {
                    RowDivider()
                    SettingsRow("Member", subtitle: "When this account was created.") {
                        Text(memberSince)
                            .font(Typography.mono)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                if let accountID {
                    RowDivider()
                    SettingsRow("Account ID", subtitle: "Your anonymous identifier.") {
                        Text(accountID)
                            .font(Typography.monoSmall)
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
            }

            // Sign out.
            SettingsCard {
                SettingsRow(
                    "Sign out",
                    subtitle: "Locks Whisper Master until you sign back in. Your transcripts stay on this Mac."
                ) {
                    Button(role: .destructive) {
                        showSignOutConfirm = true
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                                .font(.system(size: 12, weight: .semibold))
                            Text("Sign out").font(Typography.bodyMedium)
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                                .fill(Theme.danger)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .confirmationDialog(
            "Sign out of Whisper Master?",
            isPresented: $showSignOutConfirm,
            titleVisibility: .visible
        ) {
            Button("Sign out", role: .destructive) { signOut() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You’ll need to sign back in to dictate again. Nothing on this Mac is deleted.")
        }
    }
}

/// Circular avatar: the user's Clerk image when available, otherwise their
/// initials on a soft accent fill.
private struct AccountAvatar: View {
    let displayName: String
    var imageURL: URL?
    private let size: CGFloat = 58

    var body: some View {
        Group {
            if let imageURL {
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        initials
                    }
                }
            } else {
                initials
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Theme.stroke, lineWidth: 1))
    }

    private var initials: some View {
        ZStack {
            Circle().fill(Theme.accentSoft)
            Text(initialsText)
                .font(Typography.sans(22, .bold))
                .foregroundStyle(Theme.accent)
        }
    }

    private var initialsText: String {
        let parts = displayName
            .split(separator: " ")
            .prefix(2)
            .compactMap { $0.first.map(String.init) }
        let joined = parts.joined().uppercased()
        return joined.isEmpty ? "?" : joined
    }
}
