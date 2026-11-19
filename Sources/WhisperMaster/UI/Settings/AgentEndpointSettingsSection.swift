import SwiftUI

/// Settings → Assistant → **Your endpoint** (dev builds only,
/// `FeatureFlags.agentEndpointAvailable`): the model behind an HTTP endpoint the user
/// sets, which the chord uses before the on-device model.
///
/// Nothing is sent until the user opens the consent sheet for this exact address and
/// allows it. The address and the model are in `UserDefaults`; the key goes straight
/// to the Keychain and is never shown again.
///
/// It takes a binding, not `AppState`, so the snapshot renderer can draw a filled-in
/// endpoint without writing one into the defaults of the process it runs in.
struct AgentEndpointSettingsSection: View {
    @Binding var endpoint: AgentEndpoint
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var keyDraft = ""
    @State private var keySaved = AgentEndpoint.hasAPIKey
    @State private var showingConsent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Your endpoint")
            SettingsCard {
                SettingsRow(
                    "Use a model behind your endpoint",
                    tag: "Dev",
                    subtitle: "The chord's text goes to an address you set, and the on-device "
                        + "assistant answers when it can't. Audio never leaves this Mac."
                ) {
                    status
                }
                RowDivider()
                SettingsRow("API") { apiPicker }
                RowDivider()
                SettingsRow("Address", subtitle: addressSubtitle) {
                    field(endpoint.api.placeholderURL, text: $endpoint.url)
                }
                RowDivider()
                SettingsRow("Model", subtitle: "The model id your endpoint expects.") {
                    field(endpoint.api == .anthropic ? "claude-opus-5-5" : "qwen3:8b",
                          text: $endpoint.model)
                }
                RowDivider()
                SettingsRow(
                    "API key",
                    subtitle: "Kept in your Keychain for this host only. A new host removes it. "
                        + "Leave it empty for a local server that needs none."
                ) {
                    keyControl
                }
                RowDivider()
                consentRow
            }
        }
        // `AppState` deletes the key on a new host, and sign-out deletes it too.
        .onChange(of: endpoint) { _, _ in keySaved = AgentEndpoint.hasAPIKey }
        .sheet(isPresented: $showingConsent) {
            AgentEndpointConsentSheet(
                host: endpoint.host,
                onAllow: {
                    endpoint.consentedTo = endpoint.consentKey
                    endpoint.paused = false
                    showingConsent = false
                },
                onCancel: { showingConsent = false })
        }
    }

    // MARK: - Pieces

    private var statusText: (String, Color) {
        if !endpoint.isConfigured { return ("Not set", Theme.textFaint) }
        if !endpoint.hasConsent { return ("Not allowed yet", Theme.warning) }
        if endpoint.paused { return ("Paused", Theme.textFaint) }
        return ("On", Theme.success)
    }

    private var status: some View {
        HStack(spacing: 8) {
            StatusDot(color: statusText.1, size: 7)
            Text(statusText.0)
                .font(Typography.caption)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private var addressSubtitle: String {
        let trimmed = endpoint.url.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, endpoint.validURL == nil {
            return "Use https, or http to this Mac only (127.0.0.1 or localhost)."
        }
        return "The full request URL. A local address still counts as off this Mac: "
            + "a proxy there can forward everything."
    }

    @ViewBuilder
    private var apiPicker: some View {
        if isSnapshot {
            staticValue(endpoint.api.label)
        } else {
            Picker("", selection: $endpoint.api) {
                ForEach(AgentEndpoint.API.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden().pickerStyle(.segmented).fixedSize()
        }
    }

    @ViewBuilder
    private func field(_ placeholder: String, text: Binding<String>) -> some View {
        if isSnapshot {
            Text(text.wrappedValue.isEmpty ? placeholder : text.wrappedValue)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(text.wrappedValue.isEmpty ? Theme.textTertiary : Theme.textSecondary)
                .lineLimit(1)
                .frame(width: 300, alignment: .trailing)
        } else {
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .frame(width: 300)
        }
    }

    @ViewBuilder
    private var keyControl: some View {
        if keySaved {
            HStack(spacing: 10) {
                Text("Saved")
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
                Button("Remove") {
                    AgentEndpoint.setAPIKey(nil)
                    keySaved = AgentEndpoint.hasAPIKey
                }
                .textButton()
            }
        } else {
            HStack(spacing: 8) {
                SecretField(placeholder: "Paste a key", text: $keyDraft)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(width: 200)
                    .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                        .fill(Theme.surface))
                    .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                        .strokeBorder(Theme.strokeStrong, lineWidth: 1))
                Button("Save") {
                    AgentEndpoint.setAPIKey(keyDraft)
                    keyDraft = ""
                    keySaved = AgentEndpoint.hasAPIKey
                }
                .secondaryButton()
                // The key belongs to a host, so it waits for one: saved first, the
                // host's first keystrokes would read as a new host and delete it.
                .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty || endpoint.validURL == nil)
            }
        }
    }

    @ViewBuilder
    private var consentRow: some View {
        if endpoint.hasConsent {
            SettingsRow(
                "Send to \(endpoint.host)",
                subtitle: "You allowed text to go to this address. Pause it here or from the "
                    + "menu bar; a new address asks again."
            ) {
                HStack(spacing: 12) {
                    Button("Revoke") { endpoint.consentedTo = nil }
                        .textButton()
                    ThemeToggle(isOn: Binding(get: { !endpoint.paused },
                                              set: { endpoint.paused = !$0 }),
                                label: "Send to your endpoint")
                        .disabled(isSnapshot)
                }
            }
        } else {
            SettingsRow(
                "Allow this endpoint",
                subtitle: endpoint.isConfigured
                    ? "Nothing is sent until you review what goes to \(endpoint.host) and allow it."
                    : "Set an address and a model first."
            ) {
                Button("Review and allow\u{2026}") { showingConsent = true }
                    .primaryButton()
                    .disabled(!endpoint.isConfigured)
            }
        }
    }

    private func staticValue(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                .fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                .strokeBorder(Theme.strokeStrong, lineWidth: 1))
    }
}

/// The per-endpoint consent sheet: every kind of data that goes to the address, and
/// what never does. Agreeing records the address and API (`AgentEndpoint.consentKey`),
/// so a changed address shows this sheet again. The connected tool asks with the same
/// sheet and its own words (`ConnectedToolSettingsSection.consentSheet`).
struct AgentEndpointConsentSheet: View {
    let host: String
    var intro = "When you hold fn + control, the assistant's conversation goes to this "
        + "address instead of the model on this Mac. A local address counts too: "
        + "a proxy there can forward it. The provider's own retention rules apply."
    var sentItems = AgentEndpointConsentSheet.sent
    var neverSentItems = AgentEndpointConsentSheet.neverSent
    var footer = "You can pause it from the menu bar, and the on-device assistant answers "
        + "whenever this address can't."
    let onAllow: () -> Void
    let onCancel: () -> Void

    /// Each kind of data a remote brain receives, in the order a run sends it.
    static let conversation = [
        "What you say with the chord, as text.",
        "For two minutes after an answer: your last question and that answer.",
        "The name of the app in front and how much text you selected. The selected "
            + "text and the window title when the assistant reads them.",
        "What the assistant reads for you: calendar events, mail, messages, notes and reminders.",
        "What happens when it acts on this Mac: which app or link it opened, or that no such app is installed.",
        "Text the assistant writes for the app you are in, and whether you used it.",
        "The assistant's instructions and the list of tools it can use.",
    ]

    /// What the endpoint receives: the conversation, and the key.
    static let sent = conversation + ["Your API key, to this address only."]

    static let neverSent = [
        "Audio. Your voice is transcribed on this Mac, and the recording never leaves it.",
        "Anything while a password manager is in front or secure input is on. "
            + "Those captures stay on this Mac.",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Send the assistant's text to \(host)?")
                .font(Typography.heading(17))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            Divider().overlay(Theme.stroke)
            VStack(alignment: .leading, spacing: 16) {
                Text(intro)
                    .font(Typography.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                list("What is sent", sentItems, symbol: "arrow.up.right", tint: Theme.warning)
                list("Never sent", neverSentItems, symbol: "lock.fill", tint: Theme.success)
                Text(footer)
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            HStack {
                Button("Cancel", action: onCancel).textButton()
                Spacer()
                Button("Allow \(host)", action: onAllow).primaryButton()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Theme.surface.opacity(0.6))
        }
        .frame(width: 480)
        .background(WarmBackground())
    }

    private func list(_ title: String, _ items: [String], symbol: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(Typography.sans(12.5, .semibold))
                .foregroundStyle(Theme.textPrimary)
            ForEach(items, id: \.self) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: symbol)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 14)
                    Text(item)
                        .font(Typography.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
