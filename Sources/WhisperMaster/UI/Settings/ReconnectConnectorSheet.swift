import SwiftUI

/// Re-enter the credential for a connection that already exists.
///
/// **The repair `.credentialInvalid` and `.tokenExpired` always needed and never
/// had.** Both errors offered a "Reconnect" button that opened the *add* sheet — a
/// fresh catalog browse ending in a brand-new instance — so the only way to fix a
/// rotated token was to delete the connection and build it again. That loses the
/// three things the id owns: the spoken label, the per-kind default pointer, and
/// every standing write grant the user approved through the consent card. Rotating a
/// Slack token should not silently revoke your permission to post to `#ops`.
///
/// So this keeps the instance and replaces only the secret. Like the add sheet it
/// validates against the **real** provider before saving, which is what keeps the
/// rule "a stored credential is one that worked at least once" true through a
/// reconnect as well as a connect.
struct ReconnectConnectorSheet: View {
    let instance: ConnectorInstance
    let store: ConnectorInstanceStore
    let onReconnected: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: String] = [:]
    @State private var isValidating = false
    @State private var failure: String?

    private var descriptor: ConnectorDescriptor { instance.descriptor }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.stroke)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    context
                    form
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
        .frame(width: 480, height: 520)
        .background(WarmBackground())
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Reconnect \u{201C}\(instance.displayLabel)\u{201D}")
                .font(Typography.heading(17))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            IconButton("xmark", label: "Close") { dismiss() }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    /// Say what is being kept, because the alternative the user already knows about
    /// is deleting the connection — and they need to know they don't have to.
    private var context: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsCard {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        StatusDot(color: instance.lastError == nil ? Theme.success : Theme.danger, size: 7)
                        Text(instance.lastError?.message ?? "Replacing the saved credential.")
                            .font(Typography.sans(13, .medium))
                            .foregroundStyle(Theme.textPrimary)
                    }
                    Text("\(descriptor.kind.displayName) · \(instance.identity)")
                        .font(Typography.caption)
                        .foregroundStyle(Theme.textSecondary)
                    Text("The name, the default, and any permissions you've granted stay as they are.")
                        .font(Typography.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
            }

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
                    Group {
                        if field.isSecret {
                            SecureField(field.placeholder, text: binding(field.key))
                        } else {
                            TextField(field.placeholder, text: binding(field.key))
                        }
                    }
                    .textFieldStyle(.plain)
                    .font(Typography.sans(13))
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

    private var footer: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .buttonStyle(.plain)
                .font(Typography.sans(13))
                .foregroundStyle(Theme.textSecondary)
                .pointerCursor()
            Spacer()
            PrimaryButton(title: isValidating ? "Checking\u{2026}" : "Reconnect", icon: "arrow.clockwise") {
                reconnect()
            }
            .disabled(isValidating || !requiredFieldsFilled)
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

    /// Validate first, and only write the Keychain once the provider has accepted the
    /// new credential — so a mistyped token can't overwrite a working one and leave
    /// the user worse off than the failure they came here to fix.
    private func reconnect() {
        guard let provider = ProviderRegistry.provider(for: instance.kind) else {
            failure = "That connector isn't available yet."
            return
        }
        isValidating = true
        failure = nil
        Task { @MainActor in
            let trimmed = values.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            let credential = ConnectorCredential(trimmed)
            let result = await provider.validate(credential, config: instance.config)
            isValidating = false
            guard result.isValid else {
                failure = result.failure ?? "Those credentials were rejected."
                return
            }
            guard ConnectorCredentials.save(credential, for: instance.id) else {
                failure = "Couldn't save to the Keychain."
                return
            }
            store.recordReconnection(instance.id,
                                     identity: result.identity,
                                     config: result.config)
            onReconnected()
            dismiss()
        }
    }
}
