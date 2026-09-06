import SwiftUI

/// "Add connector" — pick a kind, configure it, name it.
///
/// The catalog lives here rather than on the Connectors page so the page only ever
/// shows connections that exist. A kind this build doesn't offer
/// (`ProviderRegistry.isConnectable` — no provider behind it, or not in the shipped
/// four) is shown as **Coming soon** and can't be tapped — the alternative is what
/// this redesign replaced, where eight tiles offered a Connect affordance that led to
/// a connection which could never read anything.
struct AddConnectorSheet: View {
    let store: ConnectorInstanceStore
    let onAdded: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var chosen: ConnectorKind? {
        didSet { googlePath = nil; pastesToken = false }
    }
    /// Which Google Calendar route the user picked, once they've chosen. nil = still on
    /// the fork.
    @State private var googlePath: GooglePath?
    /// Gmail only, and the *escape hatch* rather than a fork: sign-in is the whole card
    /// unless the user asks for the paste form, which is what an account Google won't
    /// grant the restricted scope to still has.
    @State private var pastesToken = false

    private enum GooglePath { case signIn, eventKit }

    /// Whether this kind opens on its one-click sign-in rather than a credential form.
    /// Gmail and Google Calendar both have one; the calendar's sits behind a fork
    /// because reading through macOS is a genuinely different connection, while a
    /// mailbox has only the one route.
    private func offersManagedSignIn(_ kind: ConnectorKind) -> Bool {
        kind == .gmail && GoogleOAuthConfig.isGmailOAuthAvailable && !pastesToken
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.stroke)
            if let chosen {
                // Google Calendar has two real paths (sign in to the API, or read the
                // calendars macOS already syncs), so it gets a fork first. Everything
                // else goes straight to its one path.
                if chosen == .googleCalendar, GoogleOAuthConfig.isConfigured, googlePath == nil {
                    googleFork
                } else if chosen == .googleCalendar, googlePath == .signIn {
                    GoogleSignInStep(store: store) {
                        onAdded()
                        dismiss()
                    } onBack: {
                        googlePath = nil
                    }
                } else if offersManagedSignIn(chosen) {
                    GmailSignInStep(store: store) {
                        onAdded()
                        dismiss()
                    } onBack: {
                        self.chosen = nil
                    } onUseToken: {
                        pastesToken = true
                    }
                } else if ConnectorCatalog.descriptor(for: chosen).isSystemBacked {
                    ConfigureConnectorStep(kind: chosen, store: store) {
                        onAdded()
                        dismiss()
                    } onBack: {
                        self.chosen = nil
                    }
                } else {
                    CredentialConnectStep(kind: chosen, store: store) {
                        onAdded()
                        dismiss()
                    } onBack: {
                        goBack()
                    }
                }
            } else {
                catalogList
            }
        }
        .frame(width: 520, height: 560)
        .background(WarmBackground())
    }

    private var header: some View {
        HStack(spacing: 10) {
            if chosen != nil {
                Button {
                    goBack()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
            Text(chosen == nil ? "Add a connector" : chosen!.displayName)
                .font(Typography.heading(17))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            IconButton("xmark", label: "Close") { dismiss() }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    /// One step back, whichever detour we're on: the paste form returns to the sign-in
    /// it was reached from, a Google fork route returns to the fork, everything else to
    /// the catalog. Header chevron and the steps' own Back share it so the two can't
    /// disagree about where "back" is.
    private func goBack() {
        if pastesToken { pastesToken = false }
        else if googlePath != nil { googlePath = nil }
        else { chosen = nil }
    }

    private var catalogList: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Search connectors", text: $search)
                .textFieldStyle(.plain)
                .font(Typography.sans(13))
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).strokeBorder(Theme.strokeStrong, lineWidth: 1))
                .padding(.horizontal, 20)
                .padding(.vertical, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    let results = ConnectorCatalog.search(search)
                    let available = results.filter { ProviderRegistry.isConnectable($0.kind) }
                    let soon = results.filter { !ProviderRegistry.isConnectable($0.kind) }

                    if !available.isEmpty {
                        SectionLabel("Available now")
                        ForEach(available) { row($0, isAvailable: true) }
                    }
                    if !soon.isEmpty {
                        SectionLabel("Coming soon").padding(.top, available.isEmpty ? 0 : 12)
                        ForEach(soon) { row($0, isAvailable: false) }
                    }
                    if results.isEmpty {
                        Text("Nothing matches \u{201C}\(search)\u{201D}.")
                            .font(Typography.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.vertical, 8)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
    }

    private func row(_ descriptor: ConnectorDescriptor, isAvailable: Bool) -> some View {
        Button {
            guard isAvailable else { return }
            chosen = descriptor.kind
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isAvailable ? Theme.Accent.n300.opacity(0.7) : Theme.Neutral.n300.opacity(0.5))
                    Image(systemName: descriptor.kind.icon)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(isAvailable ? Theme.Accent.n800 : Theme.Neutral.n800)
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 2) {
                    Text(descriptor.kind.displayName)
                        .font(Typography.sans(13.5, .semibold))
                        .foregroundStyle(isAvailable ? Theme.textPrimary : Theme.textSecondary)
                    Text(isAvailable ? descriptor.kind.blurb : comingSoonReason(descriptor))
                        .font(Typography.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 6)
                if isAvailable {
                    // A connected count, so adding a *second* "Google Calendar" reads
                    // as intentional rather than looking like a duplicate.
                    let count = store.instances(of: descriptor.kind).count
                    if count > 0 { Chip("\(count) added") }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                } else {
                    Chip("Soon")
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassTile(radius: 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .disabled(!isAvailable)
    }

    /// Say *why* it isn't available, rather than a bare "soon". Kept for kinds that
    /// lose their provider later (a deliberate withhold); every catalogued kind is
    /// connectable today, so this is a safety net rather than a living list.
    private func comingSoonReason(_ descriptor: ConnectorDescriptor) -> String {
        "Not available in this build."
    }
}

/// Step 2: configure and name the connection.
///
/// For the system-backed calendar kinds this is where the original bug is actually
/// fixed — you pick *which* calendars this connector reads, so two instances of the
/// same kind are genuinely different connections.
private struct ConfigureConnectorStep: View {
    let kind: ConnectorKind
    let store: ConnectorInstanceStore
    let onDone: () -> Void
    let onBack: () -> Void

    @State private var selected: Set<String> = []
    @State private var label: String = ""
    @State private var available: [CalendarChoice] = []
    @State private var accessGranted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    instructions
                    if !accessGranted {
                        accessCard
                    } else {
                        calendarPicker
                        nameField
                    }
                }
                .padding(20)
            }
            footer
        }
        .onAppear(perform: refresh)
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(ConnectorCatalog.descriptor(for: kind).instructions.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .top, spacing: 8) {
                    Text("\u{2022}").foregroundStyle(Theme.textTertiary)
                    Text(line)
                        .font(Typography.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var accessCard: some View {
        SettingsCard {
            SettingsRow("Allow calendar access",
                        subtitle: "Needed before we can list the calendars on this Mac.") {
                SecondaryButton(title: "Allow", icon: "calendar") {
                    Task { @MainActor in
                        let granted = await CalendarConnector.shared.requestAccess()
                        store.calendarAccessGranted = granted
                        refresh()
                    }
                }
            }
        }
    }

    private var calendarPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Which calendars?")
            if available.isEmpty {
                Text("No calendars from this kind of account are set up in macOS Calendar yet.")
                    .font(Typography.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            } else {
                SettingsCard {
                    ForEach(Array(available.enumerated()), id: \.element.id) { index, choice in
                        if index > 0 { RowDivider() }
                        calendarRow(choice)
                    }
                }
            }
        }
    }

    private func calendarRow(_ choice: CalendarChoice) -> some View {
        Button {
            if selected.contains(choice.identifier) {
                selected.remove(choice.identifier)
            } else {
                selected.insert(choice.identifier)
            }
        } label: {
            HStack(spacing: 11) {
                Image(systemName: selected.contains(choice.identifier) ? "checkmark.square.fill" : "square")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(selected.contains(choice.identifier) ? Theme.accent : Theme.textTertiary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(choice.title)
                        .font(Typography.sans(13, .medium))
                        .foregroundStyle(Theme.textPrimary)
                    if !choice.sourceTitle.isEmpty {
                        Text(choice.sourceTitle)
                            .font(Typography.caption)
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
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
            Text("This is what you'll say out loud \u{2014} \u{201C}what's on my \(label.isEmpty ? "work" : label.lowercased()) calendar\u{201D}. Keep it short.")
                .font(Typography.caption)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
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
            PrimaryButton(title: "Add connector", icon: "checkmark") { save() }
                .disabled(!canSave)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Theme.surface.opacity(0.6))
    }

    /// A connection with no calendars selected would read nothing, so it isn't
    /// offered. Naming is required too — the label is the spoken handle, and an
    /// unnamed instance can never be addressed.
    private var canSave: Bool {
        accessGranted && !selected.isEmpty && !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func refresh() {
        accessGranted = CalendarConnector.shared.isAuthorized
        store.calendarAccessGranted = accessGranted
        guard accessGranted else { return }
        available = CalendarConnector.shared.availableCalendars(for: kind)
        if selected.isEmpty { selected = Set(available.map(\.identifier)) }
        if label.isEmpty { label = suggestedLabel() }
    }

    /// Prefill from the account the calendars belong to — "Acme" from
    /// "sam@acme.com" — because that's usually what the user would have typed.
    private func suggestedLabel() -> String {
        let sources = Set(available.map(\.sourceTitle)).filter { !$0.isEmpty }
        guard sources.count == 1, let source = sources.first else { return kind.displayName }
        if let at = source.firstIndex(of: "@") {
            let domain = source[source.index(after: at)...]
            let name = domain.split(separator: ".").first.map(String.init) ?? source
            return name.capitalized
        }
        return source
    }

    private func save() {
        let identifiers = Array(selected)
        let instance = ConnectorInstance(
            kind: kind,
            label: label,
            identity: CalendarConnector.shared.sourceTitle(forCalendars: identifiers),
            config: .calendars(
                identifiers: identifiers,
                sourceTitle: available.first?.sourceTitle ?? ""))
        store.add(instance)
        onDone()
    }
}

/// Rename a connection. Its own sheet because the label is load-bearing — it's the
/// spoken handle — and the store may adjust it for uniqueness within the kind.
struct RenameConnectorSheet: View {
    let instance: ConnectorInstance
    let store: ConnectorInstanceStore

    @Environment(\.dismiss) private var dismiss
    @State private var draft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename \u{201C}\(instance.displayLabel)\u{201D}")
                .font(Typography.heading(16))
                .foregroundStyle(Theme.textPrimary)
            TextField(instance.kind.displayName, text: $draft)
                .textFieldStyle(.plain)
                .font(Typography.sans(13))
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).strokeBorder(Theme.strokeStrong, lineWidth: 1))
            Text("Names are unique per connector type, so a duplicate gets a number.")
                .font(Typography.caption)
                .foregroundStyle(Theme.textTertiary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .font(Typography.sans(13))
                    .foregroundStyle(Theme.textSecondary)
                    .pointerCursor()
                PrimaryButton(title: "Save") {
                    store.rename(instance.id, to: draft)
                    dismiss()
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .background(WarmBackground())
        .onAppear { draft = instance.displayLabel }
    }
}

/// Re-pick which calendars an existing connection reads. Also the repair path for
/// `.calendarMissing`, since `EKCalendar.calendarIdentifier` isn't stable across an
/// account being removed and re-added.
struct CalendarSelectionSheet: View {
    let instance: ConnectorInstance
    let store: ConnectorInstanceStore
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []
    @State private var available: [CalendarChoice] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Calendars for \u{201C}\(instance.displayLabel)\u{201D}")
                .font(Typography.heading(16))
                .foregroundStyle(Theme.textPrimary)

            if available.isEmpty {
                Text("No calendars available. Check that the account is still set up in macOS Calendar.")
                    .font(Typography.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            } else {
                ScrollView {
                    SettingsCard {
                        ForEach(Array(available.enumerated()), id: \.element.id) { index, choice in
                            if index > 0 { RowDivider() }
                            Button {
                                if selected.contains(choice.identifier) {
                                    selected.remove(choice.identifier)
                                } else {
                                    selected.insert(choice.identifier)
                                }
                            } label: {
                                HStack(spacing: 11) {
                                    Image(systemName: selected.contains(choice.identifier) ? "checkmark.square.fill" : "square")
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundStyle(selected.contains(choice.identifier) ? Theme.accent : Theme.textTertiary)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(choice.title)
                                            .font(Typography.sans(13, .medium))
                                            .foregroundStyle(Theme.textPrimary)
                                        if !choice.sourceTitle.isEmpty {
                                            Text(choice.sourceTitle)
                                                .font(Typography.caption)
                                                .foregroundStyle(Theme.textTertiary)
                                        }
                                    }
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
                .frame(maxHeight: 320)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .font(Typography.sans(13))
                    .foregroundStyle(Theme.textSecondary)
                    .pointerCursor()
                PrimaryButton(title: "Save") { save() }
                    .disabled(selected.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
        .background(WarmBackground())
        .onAppear(perform: refresh)
    }

    private func refresh() {
        available = CalendarConnector.shared.availableCalendars(for: instance.kind)
        let bound = instance.config.calendarIdentifiers ?? []
        // An empty binding means "every calendar" (the legacy migration's shape), so
        // reflect that as everything checked rather than nothing.
        selected = bound.isEmpty ? Set(available.map(\.identifier)) : Set(bound)
    }

    private func save() {
        let identifiers = Array(selected)
        store.setConfig(instance.id, .calendars(
            identifiers: identifiers,
            sourceTitle: available.first?.sourceTitle ?? ""))
        // Re-picking is the repair for a missing calendar, so clear the error.
        store.setError(instance.id, nil)
        onSaved()
        dismiss()
    }
}

/// Step 2 for a credential-bearing connector: fill the descriptor's fields, validate
/// against the real provider, then name it.
///
/// The form is generated from `ConnectorDescriptor.fields`, so adding a connector needs
/// a catalog entry and a provider — not new UI. Validation is a **real API call** whose
/// returned identity prefills the label, which is why a saved connection is always one
/// that actually worked at least once.
private struct CredentialConnectStep: View {
    let kind: ConnectorKind
    let store: ConnectorInstanceStore
    let onDone: () -> Void
    let onBack: () -> Void

    @State private var values: [String: String] = [:]
    @State private var label = ""
    @State private var identity = ""
    @State private var validated = false
    @State private var isValidating = false
    @State private var failure: String?
    /// Configuration the validating call discovered (Asana's workspace, Slack's team).
    /// Saved with the instance — a credential connector used to be stored with
    /// `.empty` unconditionally, which is what left every Asana read sending an empty
    /// `workspace` parameter.
    @State private var discoveredConfig: ConnectorConfig = .empty

    private var descriptor: ConnectorDescriptor { ConnectorCatalog.descriptor(for: kind) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    instructions
                    if validated { connectedCard; nameField } else { form }
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

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(descriptor.instructions.enumerated()), id: \.offset) { index, line in
                HStack(alignment: .top, spacing: 8) {
                    Text("\(index + 1).")
                        .font(Typography.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 16, alignment: .trailing)
                    Text(line)
                        .font(Typography.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(descriptor.fields) { field in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 5) {
                        Text(field.label)
                            .font(Typography.sans(12.5, .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        if !field.isRequired {
                            Text("optional").font(Typography.caption).foregroundStyle(Theme.textTertiary)
                        }
                    }
                    // A secret is masked so it isn't shoulder-readable or captured in a
                    // screen recording while being pasted. `SecretField` rather than
                    // SwiftUI's `SecureField` because the latter opts into AutoFill, whose
                    // out-of-process completion list crashes the app the next time a
                    // popover opens in this window — see `SecretField` for the full chain.
                    Group {
                        if field.isSecret {
                            SecretField(placeholder: field.placeholder, text: binding(field.key))
                        } else {
                            TextField(field.placeholder, text: binding(field.key))
                                .textFieldStyle(.plain)
                                .font(Typography.sans(13))
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).fill(Theme.surface))
                    .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).strokeBorder(Theme.strokeStrong, lineWidth: 1))
                    if !field.help.isEmpty {
                        Text(field.help)
                            .font(Typography.caption)
                            .foregroundStyle(Theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var connectedCard: some View {
        SettingsCard {
            HStack(spacing: 9) {
                StatusDot(color: Theme.success, size: 7)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connected")
                        .font(Typography.sans(13, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(identity)
                        .font(Typography.caption)
                        .foregroundStyle(Theme.textSecondary)
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
            Text("This is what you'll say out loud to pick this account. Keep it short.")
                .font(Typography.caption)
                .foregroundStyle(Theme.textTertiary)
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
            if validated {
                PrimaryButton(title: "Add connector", icon: "checkmark") { save() }
                    .disabled(label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } else {
                PrimaryButton(title: isValidating ? "Checking\u{2026}" : "Check credentials") { validate() }
                    .disabled(isValidating || !requiredFieldsFilled)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Theme.surface.opacity(0.6))
    }

    private var requiredFieldsFilled: Bool {
        descriptor.fields.filter(\.isRequired).allSatisfy {
            !(values[$0.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { values[key] ?? "" }, set: { values[key] = $0 })
    }

    /// Validate before saving anything. A connection is only ever created from
    /// credentials that a real provider call accepted, so the list can't fill up with
    /// entries that were never going to work.
    private func validate() {
        guard let provider = ProviderRegistry.provider(for: kind) else {
            failure = "That connector isn't available yet."
            return
        }
        isValidating = true
        failure = nil
        Task { @MainActor in
            let trimmed = values.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            let result = await provider.validate(ConnectorCredential(trimmed), config: .empty)
            isValidating = false
            if result.isValid {
                identity = result.identity
                discoveredConfig = result.config ?? .empty
                validated = true
                if label.isEmpty { label = result.identity }
            } else {
                failure = result.failure ?? "Those credentials were rejected."
            }
        }
    }

    private func save() {
        let instance = ConnectorInstance(
            kind: kind, label: label, identity: identity, config: discoveredConfig)
        let stored = store.add(instance)
        // The secret is written under the *stored* instance's id, after the store has
        // settled the label — so a uniqueness suffix can't orphan the credential.
        let trimmed = values.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        _ = ConnectorCredentials.save(ConnectorCredential(trimmed), for: stored.id)
        onDone()
    }
}

extension AddConnectorSheet {
    /// The Google Calendar fork. Both routes are legitimate and produce genuinely
    /// different connections, so the choice is put to the user with the trade-off stated
    /// rather than picked for them.
    @ViewBuilder
    fileprivate var googleFork: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Two ways to read your Google calendar. You can use both, on different accounts.")
                .font(Typography.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            forkOption(
                title: "Sign in with Google",
                detail: "Reads straight from Google. Sees calendars macOS isn't subscribed to, and it's the only option that can add events.",
                icon: "person.badge.key",
                isRecommended: true) { googlePath = .signIn }

            forkOption(
                title: "Use macOS Calendar",
                detail: "Reads the Google calendars already synced on this Mac. No sign-in, nothing leaves the machine.",
                icon: "calendar",
                isRecommended: false) { googlePath = .eventKit }

            Spacer(minLength: 0)
        }
        .padding(20)
    }

    fileprivate func forkOption(title: String,
                                detail: String,
                                icon: String,
                                isRecommended: Bool,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isRecommended ? Theme.Accent.n300.opacity(0.7) : Theme.Neutral.n300.opacity(0.6))
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(isRecommended ? Theme.Accent.n800 : Theme.Neutral.n800)
                }
                .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(Typography.sans(13.5, .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        if isRecommended { Chip("More capable") }
                    }
                    Text(detail)
                        .font(Typography.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassTile(radius: 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }
}
