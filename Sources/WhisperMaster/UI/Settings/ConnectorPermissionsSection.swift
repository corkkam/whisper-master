import SwiftUI

/// Every "always allow" the user has granted, on the Connectors page.
///
/// This is the one piece of the old `ConnectorAgentSettings` that belongs beside the
/// connection list rather than in Settings: a grant is bound to `(tool, instance,
/// target)`, so the list is meaningless away from the accounts it names. The
/// assistant switch and the spoken-answer preferences moved to Settings
/// (`AssistantSettingsView`), and the automations section was removed with the
/// feature.
///
/// Hidden entirely when there are no grants — an empty card here is noise on a Mac
/// that has never approved a write.
struct ConnectorPermissionsSection: View {
    @Bindable var state: AppState
    @Environment(\.isSnapshot) private var isSnapshot

    private var store: ConnectorInstanceStore { state.connectorStore }

    var body: some View {
        if !store.grants.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionLabel("Standing permissions")
                    Spacer()
                    Text("Revocable any time")
                        .font(Typography.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
                SettingsCard {
                    ForEach(Array(store.grants.sorted { $0.grantedAt > $1.grantedAt }.enumerated()),
                            id: \.element.id) { index, grant in
                        if index > 0 { RowDivider() }
                        grantRow(grant)
                    }
                }
            }
        }
    }

    /// A grant row spells out what the permission actually covers. One that only
    /// named the tool would hide the part that matters.
    private func grantRow(_ grant: Grant) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.success)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(ApprovalCopy.verb(for: grant.tool)) \(grant.target)")
                    .font(Typography.sans(13, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(store.instance(id: grant.instanceID)?.displayLabel ?? "a removed connector")
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 8)
            Button("Revoke") { store.revokeGrant(id: grant.id) }
                .destructiveButton()
                .disabled(isSnapshot)
        }
        .padding(.vertical, 11)
    }
}
