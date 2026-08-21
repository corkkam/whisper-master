import SwiftUI

/// Connect Gmail by **signing in**, instead of pasting a token you minted yourself.
///
/// The sibling of `GoogleSignInStep`, and deliberately a separate view rather than a
/// mode on it: that one's middle act is picking calendars, which has no counterpart here
/// (a mailbox is one thing), and the two ask for different scopes.
///
/// Shown only when `GoogleOAuthConfig.isGmailOAuthAvailable` — the client id **and** the
/// Gmail flag, because `gmail.readonly` is a Google *restricted* scope and an unverified
/// client can only grant it to listed test users. While that's off, the Gmail card is the
/// manual-token form alone; nothing here is shown broken.
struct GmailSignInStep: View {
    let store: ConnectorInstanceStore
    let onDone: () -> Void
    let onBack: () -> Void
    /// Switch to the manual-token form. Offered because the restricted scope can be
    /// refused for reasons this screen can't fix — an unverified client, an account not
    /// listed as a test user, a Workspace policy — and a card whose only button is one
    /// Google won't honour leaves the user with nothing.
    var onUseToken: (() -> Void)?

    @State private var phase: Phase = .idle
    @State private var credential = ConnectorCredential()
    @State private var identity = ""
    @State private var label = ""
    @State private var failure: String?

    private enum Phase: Equatable {
        case idle
        case authorizing
        case naming
    }

    private let flow = OAuthPKCEFlow()

    /// Google accounts this Mac already holds a grant for. Offering them is what turns a
    /// second connection into one consent screen rather than a full sign-in.
    private var knownAccounts: [String] {
        GoogleAccounts.connected(in: store.instances)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch phase {
                    case .idle, .authorizing:
                        intro
                        if !knownAccounts.isEmpty { accountChooser }
                    case .naming:
                        signedInCard
                        nameField
                    }
                    if let failure {
                        Text(failure)
                            .font(Typography.caption)
                            .foregroundStyle(Theme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(20)
            }
            footer
        }
    }

    // MARK: - Steps

    private var intro: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Sign in to Google")
                    .font(Typography.sans(13.5, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Reads your recent and unread mail so you can ask about it out loud. The sign-in happens in your browser and the token is kept in your Mac's Keychain \u{2014} it never goes anywhere else, and nothing here can send mail.")
                    .font(Typography.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Read-only is the whole grant, and it's worth saying on the screen before
            // the browser opens rather than leaving it to Google's own scope wording.
            Text("We ask for read access only.")
                .font(Typography.caption)
                .foregroundStyle(Theme.textTertiary)
            if phase == .authorizing {
                progress("Waiting for your browser\u{2026}")
            }
            if let onUseToken, phase == .idle {
                Button("Paste a token instead", action: onUseToken)
                    .buttonStyle(.plain)
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .pointerCursor()
            }
        }
    }

    /// The accounts already connected here, offered as one tap each.
    ///
    /// Picking one runs incremental authorization against it: Google knows who is
    /// signing in and which scopes they've already granted, so the consent screen names
    /// mail alone. The connection is still its own — its own grant, its own Keychain
    /// item — so removing the calendar it sat beside can't take it down with it.
    private var accountChooser: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Already signed in")
            SettingsCard {
                ForEach(Array(knownAccounts.enumerated()), id: \.element) { index, account in
                    if index > 0 { RowDivider() }
                    Button {
                        authorize(account: .reuse(email: account))
                    } label: {
                        HStack(spacing: 11) {
                            Image(systemName: "person.crop.circle")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(Theme.textTertiary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Continue as \(account)")
                                    .font(Typography.sans(13, .medium))
                                    .foregroundStyle(Theme.textPrimary)
                                Text("You'll only be asked to allow mail access.")
                                    .font(Typography.caption)
                                    .foregroundStyle(Theme.textTertiary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.textTertiary)
                        }
                        .padding(.vertical, 9)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .disabled(phase != .idle)
                }
            }
        }
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: 9) {
            ProgressView().controlSize(.small)
            Text(text).font(Typography.subheadline).foregroundStyle(Theme.textSecondary)
        }
    }

    private var signedInCard: some View {
        SettingsCard {
            HStack(spacing: 9) {
                StatusDot(color: Theme.success, size: 7)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Signed in").font(Typography.sans(13, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(identity).font(Typography.caption).foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
        }
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Name it")
            TextField("Work", text: $label)
                .textFieldStyle(.plain)
                .font(Typography.sans(13))
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).strokeBorder(Theme.strokeStrong, lineWidth: 1))
            Text("This is what you'll say out loud to pick this mailbox.")
                .font(Typography.caption).foregroundStyle(Theme.textTertiary)
        }
    }

    private var footer: some View {
        HStack {
            Button("Back", action: onBack)
                .buttonStyle(.plain)
                .font(Typography.sans(13))
                .foregroundStyle(Theme.textSecondary)
                .pointerCursor()
            Spacer()
            if phase == .naming {
                PrimaryButton(title: "Add connector", icon: "checkmark") { save() }
                    .disabled(label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } else {
                // With accounts listed above, this button is the "somebody else" path,
                // so it says so rather than repeating the offer already on screen.
                PrimaryButton(title: primaryTitle) {
                    authorize(account: .chooseAccount)
                }
                .disabled(phase != .idle)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Theme.surface.opacity(0.6))
    }

    private var primaryTitle: String {
        if phase != .idle { return "Signing in\u{2026}" }
        return knownAccounts.isEmpty ? "Sign in with Google" : "Use another account"
    }

    // MARK: - Actions

    private func authorize(account: OAuthPKCEFlow.AccountChoice) {
        phase = .authorizing
        failure = nil
        Task { @MainActor in
            do {
                let tokens = try await flow.authorize(
                    scopes: GoogleOAuthConfig.Scope.gmailConnect, account: account)
                credential = tokens.merged(into: ConnectorCredential())

                guard let provider = ProviderRegistry.gmailAPI else {
                    failure = "Gmail sign-in isn't enabled in this build."
                    phase = .idle
                    return
                }
                // The same `validate` the paste path runs: it asks Gmail whose mailbox
                // this is, so the grant is proven against the actual API before an
                // instance exists, rather than at the first read days later.
                let result = await provider.validate(credential, config: .googleOAuth)
                guard result.isValid else {
                    failure = result.failure ?? "Google rejected the sign-in."
                    phase = .idle
                    return
                }
                identity = result.identity

                // Refuse a duplicate before it becomes two rows reading the same mailbox
                // that a rename can't tell apart. Scoped to Gmail: the same address
                // already connected as a calendar is a different connection.
                guard !GoogleAccounts.isAlreadyConnected(identity, kind: .gmail,
                                                         in: store.instances) else {
                    failure = "\(identity) is already connected. Pick a different Google account, or edit the existing one."
                    phase = .idle
                    return
                }

                if label.isEmpty { label = GoogleSignInStep.suggestedLabel(from: identity) }
                phase = .naming
            } catch OAuthFlowError.userCancelled {
                phase = .idle       // not an error; the user backed out
            } catch OAuthFlowError.notConfigured {
                failure = "No Google client id is configured in this build."
                phase = .idle
            } catch OAuthFlowError.tokenExchangeFailed(let detail) {
                // Google's own error text is the useful part: `redirect_uri_mismatch`
                // means the URL scheme isn't registered, `invalid_scope` means the Gmail
                // scope isn't enabled on the Cloud project. Both are setup problems.
                failure = "Google wouldn't complete the sign-in: \(detail)"
                phase = .idle
            } catch {
                failure = "Sign-in failed: \(error)"
                phase = .idle
            }
        }
    }

    private func save() {
        let instance = ConnectorInstance(
            kind: .gmail,
            label: label,
            identity: identity,
            config: .googleOAuth)
        let stored = store.add(instance)
        // Saved under the *stored* id, after the store has settled the label — a
        // uniqueness suffix must not orphan the credential.
        _ = ConnectorCredentials.save(credential, for: stored.id)
        onDone()
    }
}
