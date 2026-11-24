import SwiftUI

/// The facts the user asked the assistant to remember, each with a delete button.
///
/// The list is also the only place a fact is read back: the assistant's prompt holds
/// at most `AgentMemoryStore.maxPromptLength` characters of them (newest first), so a
/// fact missing from a prompt still shows here. Nothing here adds a fact. A fact is
/// saved only when the user says "remember that ..." through the chord.
struct AgentMemorySettingsSection: View {
    let memory: AgentMemoryStore
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Memory")
            SettingsCard {
                if memory.facts.isEmpty {
                    Text("Nothing yet. Hold fn + control and say \u{201C}remember that my manager is Priya\u{201D}.")
                        .font(Typography.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 12)
                } else {
                    ForEach(Array(memory.facts.reversed().enumerated()), id: \.element.id) { index, fact in
                        if index > 0 { RowDivider() }
                        factRow(fact)
                    }
                }
            }
            Text("The assistant reads these with every command. It saves one only when you ask, and never "
                + "after it has read text from outside. They stay on this Mac, and go with each command "
                + "to your endpoint or connected tool when one is on.")
                .font(Typography.caption)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func factRow(_ fact: AgentMemoryFact) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(fact.text)
                    .font(Typography.sans(13, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(fact.createdAt.formatted(date: .abbreviated, time: .omitted))
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 8)
            IconButton("trash", label: "Forget this", role: .destructive) {
                memory.remove(id: fact.id)
            }
            .disabled(isSnapshot)
        }
        .padding(.vertical, 11)
    }
}
