import SwiftUI

/// Connect Outlook (mail and calendar) or Teams by **signing in to Microsoft**.
///
/// One view for both kinds rather than a Gmail-style sibling per kind: the two differ
/// only in scopes, tenant and copy, and both end in the same "name it" step. Simpler
/// than `GmailSignInStep` on purpose: there is no "already signed in" list, because
/// Microsoft has no incremental consent to reuse — its own account picker remembers
/// who is signed in, and each connection still keeps its own grant.
///
/// Shown only when `MicrosoftOAuthConfig.isConfigured`.
struct MicrosoftSignInStep: View {
    let kind: ConnectorKind
    let store: ConnectorInstanceStore
    let onDone: () -> Void
    let onBack: () -> Void

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

    /// How the card explains what one kind's sign-in is for. The scopes and tenant
    /// themselves live in `MicrosoftOAuthConfig.signIn(for:)`.
    private var summary: String {
        kind == .teams
            ? "Reads your recent chats, and can post to a chat after you approve it. Needs a work or school account."
            : "Reads your recent and unread mail and today's calendar, and can add an event after you approve it. Work, school and personal accounts all work."
    }

    private var spokenHint: String {
        kind == .teams
            ? "This is what you'll say out loud to pick these chats."
            : "This is what you'll say out loud to pick this account."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch phase {
                    case .idle, .authorizing: intro
                    case .naming: signedInCard; nameField
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

    private var intro: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Sign in to Microsoft")
                    .font(Typography.sans(13.5, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(summary)
                    .font(Typography.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("The sign-in happens in your browser. The token stays in your Mac's Keychain.")
                .font(Typography.caption)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            if phase == .authorizing {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for your browser\u{2026}")
                        .font(Typography.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
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
            Text(spokenHint)
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
                PrimaryButton(title: phase == .idle ? "Sign in with Microsoft" : "Signing in\u{2026}") {
                    authorize()
                }
                .disabled(phase != .idle)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Theme.surface.opacity(0.6))
    }

    private func authorize() {
        guard let plan = MicrosoftOAuthConfig.signIn(for: kind) else { return }
        phase = .authorizing
        failure = nil
        Task { @MainActor in
            do {
                credential = try await flow.authorizeMicrosoft(scopes: plan.scopes, tenant: plan.tenant)
                let probe = ConnectorInstance(kind: kind, label: "", identity: "", config: .microsoftOAuth)
                guard let provider = ProviderRegistry.provider(for: probe) else {
                    failure = "Microsoft sign-in isn't enabled in this build."
                    phase = .idle
                    return
                }
                // The provider's own `validate`: proves the grant against the API it
                // will read (Teams also proves chats answer) before an instance exists.
                let result = await provider.validate(credential, config: .microsoftOAuth)
                guard result.isValid else {
                    failure = result.failure ?? "Microsoft rejected the sign-in."
                    phase = .idle
                    return
                }
                identity = result.identity
                guard !Self.isAlreadyConnected(identity, kind: kind, in: store.instances) else {
                    failure = "\(identity) is already connected. Pick a different account, or edit the existing one."
                    phase = .idle
                    return
                }
                if label.isEmpty { label = GoogleSignInStep.suggestedLabel(from: identity) }
                phase = .naming
            } catch OAuthFlowError.userCancelled {
                phase = .idle
            } catch OAuthFlowError.notConfigured {
                failure = "No Microsoft client id is configured in this build."
                phase = .idle
            } catch OAuthFlowError.tokenExchangeFailed(let detail) {
                // Microsoft's own code is the useful part: AADSTS50011 is a redirect
                // URI missing from the registration, AADSTS65001 a refused consent.
                failure = "Microsoft wouldn't complete the sign-in: \(detail)"
                phase = .idle
            } catch {
                failure = "Sign-in failed: \(error)"
                phase = .idle
            }
        }
    }

    /// The same address connected twice for the same kind is two rows nobody can tell
    /// apart. Scoped to the kind: one account as Outlook *and* Teams is two connections.
    static func isAlreadyConnected(_ address: String,
                                   kind: ConnectorKind,
                                   in instances: [ConnectorInstance]) -> Bool {
        instances.contains {
            $0.kind == kind
                && $0.config.isManagedMicrosoftGrant
                && $0.identity.compare(address, options: .caseInsensitive) == .orderedSame
        }
    }

    private func save() {
        let stored = store.add(ConnectorInstance(
            kind: kind, label: label, identity: identity, config: .microsoftOAuth))
        // Saved under the *stored* id, after the store has settled the label — a
        // uniqueness suffix must not orphan the credential.
        _ = ConnectorCredentials.save(credential, for: stored.id)
        onDone()
    }
}
