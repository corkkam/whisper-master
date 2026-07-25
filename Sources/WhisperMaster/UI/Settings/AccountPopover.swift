import AppKit
import ClerkKit
import SwiftUI

/// The account popup shown from the sidebar profile row — avatar, name, email,
/// the account id in small type under the email, and sign out. This replaced the
/// standalone Account settings page: the identity already lives at the bottom of
/// the sidebar, so the details hang off it instead of a separate section.
///
/// Live account state is read reactively from the injected `Clerk` (`@Observable`,
/// exactly like `AuthGateView`). The settings window injects
/// `.environment(Clerk.shared)`; the headless snapshot renderer does not, so the
/// snapshot path uses a static placeholder and never resolves that environment.
struct AccountPopover: View {
    var signOut: () -> Void = {}

    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        if isSnapshot {
            // ImageRenderer can't reach the Clerk environment (it isn't injected
            // in snapshot mode) and can't load remote avatars — show a stable
            // stand-in so the popup still renders in the UI snapshot loop.
            AccountPopoverCard(
                displayName: "Alex Rivera",
                email: "alex@whispermaster.app",
                accountID: "user_2aBcDeFgHiJkLmN",
                memberSince: "Joined June 2026",
                imageURL: nil,
                signOut: {}
            )
        } else {
            LiveAccountPopover(signOut: signOut)
        }
    }
}

/// The real, Clerk-backed popup. Kept separate from `AccountPopover` so
/// `@Environment(Clerk.self)` is only ever resolved off the live (non-snapshot)
/// path — resolving a missing observable environment would trap.
private struct LiveAccountPopover: View {
    var signOut: () -> Void
    @Environment(Clerk.self) private var clerk

    var body: some View {
        if let user = clerk.user {
            AccountPopoverCard(
                displayName: AccountIdentity.displayName(for: user),
                email: AccountIdentity.email(for: user),
                accountID: user.id,
                memberSince: AccountIdentity.memberSince(for: user),
                imageURL: AccountIdentity.imageURL(for: user),
                signOut: signOut
            )
        } else {
            // No live Clerk user. The sign-in gate always holds until a real
            // session loads (there is no bypass in any build), so this popup is
            // out of reach without an account — defensive fallback only.
            NotSignedInPopover()
        }
    }
}

/// Shared derivation of the human-facing bits of a Clerk `User`, used by both the
/// popup and the sidebar row so the two never disagree on a name or avatar.
enum AccountIdentity {
    static func displayName(for user: User?) -> String {
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

    static func email(for user: User?) -> String {
        user?.primaryEmailAddress?.emailAddress
            ?? user?.emailAddresses.first?.emailAddress
            ?? "—"
    }

    static func memberSince(for user: User?) -> String? {
        guard let user else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return "Joined \(formatter.string(from: user.createdAt))"
    }

    static func imageURL(for user: User?) -> URL? {
        guard let user, user.hasImage, !user.imageUrl.isEmpty else { return nil }
        return URL(string: user.imageUrl)
    }
}

/// Defensive fallback shown on the live path when there is no Clerk user.
private struct NotSignedInPopover: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Not signed in")
                .font(Typography.sans(14, .bold))
                .foregroundStyle(Theme.textPrimary)
            Text("Sign in to use Whisper Master.")
                .font(Typography.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(16)
        .frame(width: 260, alignment: .leading)
    }
}

/// The presentation-only popup card — takes plain values so both the live and
/// snapshot paths share one layout.
struct AccountPopoverCard: View {
    let displayName: String
    let email: String
    var accountID: String?
    var memberSince: String?
    var imageURL: URL?
    var signOut: () -> Void

    /// Sign out asks once, inline. A `confirmationDialog` would fight the popover
    /// (the window-level sheet dismisses it), so the confirm lives in the card.
    @State private var confirmingSignOut = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                AccountAvatar(displayName: displayName, imageURL: imageURL, size: 42)
                VStack(alignment: .leading, spacing: 3) {
                    Text(displayName)
                        .font(Typography.sans(14.5, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(email)
                        .font(Typography.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    if let accountID {
                        Text(accountID)
                            .font(Typography.monoSmall)
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 6) {
                StatusDot(color: Theme.success)
                Text(memberSince ?? "Signed in")
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textTertiary)
            }

            Divider().overlay(Theme.stroke)

            if confirmingSignOut {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Sign out of Whisper Master?")
                        .font(Typography.sans(12.5, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("You’ll need to sign back in to dictate. Nothing on this Mac is deleted.")
                        .font(Typography.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button("Cancel") { confirmingSignOut = false }
                            .buttonStyle(.plain)
                            .font(Typography.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                                    .fill(Theme.accent2Fill)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                                            .strokeBorder(Theme.stroke, lineWidth: 1)
                                    )
                            )
                        Button("Sign out", action: signOut)
                            .buttonStyle(.plain)
                            .font(Typography.caption)
                            .foregroundStyle(Theme.accent2On)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                                    .fill(Theme.danger)
                            )
                    }
                }
            } else {
                Button { confirmingSignOut = true } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Sign out").font(Typography.sans(12.5, .medium))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(Theme.danger)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                            .fill(Theme.danger.opacity(0.09))
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(width: 272, alignment: .leading)
    }
}

/// Circular avatar: the user's Clerk image when available, otherwise their
/// initials on a soft accent fill.
struct AccountAvatar: View {
    let displayName: String
    var imageURL: URL?
    var size: CGFloat = 42

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
                .font(Typography.sans(size * 0.38, .bold))
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
