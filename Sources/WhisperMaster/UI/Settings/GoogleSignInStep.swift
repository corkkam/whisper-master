import SwiftUI

/// Connect Google Calendar by **signing in**, reading the API directly.
///
/// The alternative to the EventKit route, and a genuinely different connection: this sees
/// calendars macOS isn't subscribed to, and it's the only path that can create events. Both
/// live under the same `googleCalendar` kind — the instance's config decides which provider
/// serves it — so a user can have "Work" on the API and "Personal" through macOS Calendar
/// at once.
///
/// Shown only when `GoogleOAuthConfig.isConfigured`. Without a client id the button would
/// dead-end at the browser, so the whole option is withheld rather than shown broken.
struct GoogleSignInStep: View {
    let store: ConnectorInstanceStore
    let onDone: () -> Void
    let onBack: () -> Void

    @State private var phase: Phase = .idle
    @State private var credential = ConnectorCredential()
    @State private var identity = ""
    @State private var calendars: [(id: String, title: String)] = []
    @State private var selected: Set<String> = []
    @State private var label = ""
    @State private var failure: String?
    /// Why the calendar list came back empty, when it was a refusal rather than an
    /// account with nothing on it. Separate from `failure` because it doesn't block
    /// the connection — `primary` still works.
    @State private var listFailure: String?

    /// The flow is linear but each step can fail, so it's an explicit phase rather than a
    /// pile of booleans.
    private enum Phase: Equatable {
        case idle
        case authorizing
        case loadingCalendars
        case choosing
    }

    private let flow = OAuthPKCEFlow()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch phase {
                    case .idle, .authorizing:
                        intro
                    case .loadingCalendars:
                        progress("Loading your calendars\u{2026}")
                    case .choosing:
                        signedInCard
                        calendarPicker
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
                Text("Reads your calendar straight from Google, so it sees calendars macOS isn't subscribed to. The sign-in happens in your browser and the token is kept in your Mac's Keychain \u{2014} it never goes anywhere else.")
                    .font(Typography.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Adding a *second* Google account is the common case here, and it only works
            // because the flow forces the account chooser. Say so, so the user knows to
            // expect it.
            Text("You'll be asked which Google account to use \u{2014} pick a different one to add a second calendar.")
                .font(Typography.caption)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            if phase == .authorizing {
                progress("Waiting for your browser\u{2026}")
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

    private var calendarPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Which calendars?")
            if calendars.isEmpty {
                // An empty picker used to be a dead end — nothing to tick, so the
                // Add button could never enable. Say why, and state the fallback the
                // save actually uses, so this stays a finishable step.
                VStack(alignment: .leading, spacing: 4) {
                    Text(listFailure ?? "We couldn\u{2019}t list this account\u{2019}s calendars.")
                        .font(Typography.subheadline).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("We\u{2019}ll read its main calendar instead.")
                        .font(Typography.caption).foregroundStyle(Theme.textTertiary)
                }
            } else {
                SettingsCard {
                    ForEach(Array(calendars.enumerated()), id: \.element.id) { index, calendar in
                        if index > 0 { RowDivider() }
                        Button {
                            if selected.contains(calendar.id) {
                                selected.remove(calendar.id)
                            } else {
                                selected.insert(calendar.id)
                            }
                        } label: {
                            HStack(spacing: 11) {
                                Image(systemName: selected.contains(calendar.id)
                                      ? "checkmark.square.fill" : "square")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(selected.contains(calendar.id)
                                                     ? Theme.accent : Theme.textTertiary)
                                Text(calendar.title)
                                    .font(Typography.sans(13, .medium))
                                    .foregroundStyle(Theme.textPrimary)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 9)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .pointerCursor()
                    }
                }
            }
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
            Text("This is what you'll say out loud to pick this account.")
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
            if phase == .choosing {
                PrimaryButton(title: "Add connector", icon: "checkmark") { save() }
                    .disabled(!canSave)
            } else {
                PrimaryButton(title: phase == .idle ? "Sign in with Google" : "Signing in\u{2026}") {
                    authorize()
                }
                .disabled(phase != .idle)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Theme.surface.opacity(0.6))
    }

    /// A picker with rows must have one ticked. A picker with *no* rows isn't a
    /// choice the user can make, so it doesn't block — `save()` falls back to
    /// `primary`, which every Google account has.
    private var canSave: Bool {
        (!selected.isEmpty || calendars.isEmpty)
            && !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Google's refusals here are nearly always the grant, so name that first.
    static func listFailureMessage(for error: Error) -> String {
        switch error {
        case ConnectorHTTP.Failure.unauthorized:
            return "Google wouldn\u{2019}t let us list this account\u{2019}s calendars \u{2014} the sign-in didn\u{2019}t include calendar access."
        case ConnectorHTTP.Failure.rateLimited:
            return "Google is rate-limiting this account right now."
        case ConnectorHTTP.Failure.badStatus(let code, _):
            return "Google answered \(code) when we asked for this account\u{2019}s calendars."
        default:
            return "We couldn\u{2019}t reach Google to list this account\u{2019}s calendars."
        }
    }

    // MARK: - Actions

    private func authorize() {
        phase = .authorizing
        failure = nil
        Task { @MainActor in
            do {
                // `calendar.readonly` *and* `calendar.events`: the first is what
                // `calendarList` needs, the second is read+write on events, asked for
                // now because the write tools need it and a second consent screen
                // later is worse UX than one now. Nothing can write without a
                // standing grant regardless.
                let tokens = try await flow.authorize(
                    scopes: GoogleOAuthConfig.Scope.calendarConnect)
                credential = tokens.merged(into: ConnectorCredential())

                guard let provider = ProviderRegistry.googleCalendarAPI else {
                    failure = "Google sign-in isn't configured in this build."
                    phase = .idle
                    return
                }
                let result = await provider.validate(credential, config: .empty)
                guard result.isValid else {
                    failure = result.failure ?? "Google rejected the sign-in."
                    phase = .idle
                    return
                }
                identity = result.identity

                // Refuse a duplicate before it becomes two identical rows the user can't
                // tell apart. Renaming one wouldn't help — they'd read the same calendars.
                if store.instances(of: .googleCalendar).contains(where: {
                    $0.identity.compare(identity, options: .caseInsensitive) == .orderedSame
                        && $0.config.googleCalendarIDs != nil
                }) {
                    failure = "\(identity) is already connected. Pick a different Google account, or edit the existing one."
                    phase = .idle
                    return
                }

                phase = .loadingCalendars
                do {
                    calendars = try await provider.calendarList(credential: credential)
                    listFailure = nil
                } catch {
                    // Not fatal: the grant is good and `primary` is always readable,
                    // so the connection is still worth making. Say what happened and
                    // let the user finish rather than stranding them on a disabled
                    // button with no explanation.
                    calendars = []
                    listFailure = Self.listFailureMessage(for: error)
                }
                selected = Set(calendars.map(\.id))
                if label.isEmpty { label = Self.suggestedLabel(from: identity) }
                phase = .choosing
            } catch OAuthFlowError.userCancelled {
                phase = .idle       // not an error; the user backed out
            } catch OAuthFlowError.notConfigured {
                failure = "No Google client id is configured in this build."
                phase = .idle
            } catch OAuthFlowError.tokenExchangeFailed(let detail) {
                // Google's own error text is the useful part: `redirect_uri_mismatch`
                // means the URL scheme isn't registered, `invalid_client` means the client
                // is the wrong type. Both are setup problems, not user problems.
                failure = "Google wouldn't complete the sign-in: \(detail)"
                phase = .idle
            } catch {
                failure = "Sign-in failed: \(error)"
                phase = .idle
            }
        }
    }

    /// "Acme" from "sam@acme.com" — usually what the user would have typed.
    static func suggestedLabel(from identity: String) -> String {
        guard let at = identity.firstIndex(of: "@") else { return identity }
        let domain = identity[identity.index(after: at)...]
        guard let name = domain.split(separator: ".").first else { return identity }
        // A personal mailbox domain says nothing useful, so name it for what it is.
        let generic: Set<String> = ["gmail", "googlemail", "icloud", "me", "outlook", "hotmail", "yahoo"]
        return generic.contains(name.lowercased()) ? "Personal" : name.capitalized
    }

    private func save() {
        // `primary` is the documented alias for the account's own calendar and is
        // what `todaysEventsAsync` already defaults to, so an unlistable account
        // still produces a connector that reads something.
        let ids = selected.isEmpty ? ["primary"] : Array(selected)
        let instance = ConnectorInstance(
            kind: .googleCalendar,
            label: label,
            identity: identity,
            config: .googleAPI(calendarIDs: ids))
        let stored = store.add(instance)
        // Saved under the *stored* id, after the store has settled the label — a
        // uniqueness suffix must not orphan the credential.
        _ = ConnectorCredentials.save(credential, for: stored.id)
        onDone()
    }
}
