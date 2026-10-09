import SwiftUI

/// Account sub-page: shows the signed-in identity (or a sign-in form) and a
/// sign-out control. A self-contained local account — see `AccountStore`.
struct AccountSettingsView: View {
    @Bindable var account: AccountStore

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if account.isSignedIn {
                identityCard
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Sign in to personalize your greeting and keep your name on this Mac.")
                        .font(Typography.body)
                        .foregroundStyle(Theme.textSecondary)
                    AccountSignInForm(account: account)
                        .padding(20)
                        .glassCard()
                }
            }
        }
    }

    private var identityCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(Theme.accent)
                    Text(account.initials).font(Typography.sans(20, .bold)).foregroundStyle(.white)
                }
                .frame(width: 58, height: 58)
                VStack(alignment: .leading, spacing: 3) {
                    Text(account.displayName).font(Typography.title).foregroundStyle(Theme.textPrimary)
                    if let email = account.account?.email, !email.isEmpty {
                        Text(email).font(Typography.subheadline).foregroundStyle(Theme.textSecondary)
                    }
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark.seal.fill").font(.system(size: 11)).foregroundStyle(Theme.success)
                        Text(account.planLabel).font(Typography.caption).foregroundStyle(Theme.textSecondary)
                    }
                }
                Spacer()
            }
            RowDivider()
            HStack {
                Text("Everything stays on this Mac — no account data leaves the device.")
                    .font(Typography.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 12)
                SecondaryButton(title: "Sign out") { account.signOut() }
            }
        }
        .padding(22)
        .glassCard()
    }
}

/// The reusable name/email sign-in form. Shared by the Account sub-page and the
/// launch auth gate.
struct AccountSignInForm: View {
    @Bindable var account: AccountStore
    var onSignedIn: () -> Void = {}
    @Environment(\.isSnapshot) private var isSnapshot

    @State private var name = ""
    @State private var email = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            field(title: "Name", text: $name, placeholder: "Your name")
            field(title: "Email", text: $email, placeholder: "you@example.com")
            HStack {
                Button("Continue without an account") {
                    account.continueAsGuest()
                    onSignedIn()
                }
                .buttonStyle(.plain)
                .font(Typography.subheadline)
                .foregroundStyle(Theme.textSecondary)
                Spacer()
                PrimaryButton(title: "Sign in", icon: "arrow.right") {
                    account.signIn(name: name, email: email)
                    onSignedIn()
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func field(title: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(Typography.label)
                .tracking(1.4)
                .foregroundStyle(Theme.textTertiary)
            Group {
                if isSnapshot {
                    Text(text.wrappedValue.isEmpty ? placeholder : text.wrappedValue)
                        .foregroundStyle(text.wrappedValue.isEmpty ? Theme.textTertiary : Theme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TextField(placeholder, text: text)
                        .textFieldStyle(.plain)
                        .foregroundStyle(Theme.textPrimary)
                }
            }
            .font(Typography.body)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.5)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.55), lineWidth: 1))
        }
    }
}
