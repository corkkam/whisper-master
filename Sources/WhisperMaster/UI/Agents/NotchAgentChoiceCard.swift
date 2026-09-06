import SwiftUI

/// Claude asking you to pick between options, in the notch.
///
/// This cannot reuse the approval card and that is structural, not stylistic. The
/// approval card's three answers are fixed, short and horizontal; these options are
/// **model authored and unbounded**, so they have to stack, and a multi-select needs
/// a confirm step because tapping one option is not the whole answer.
///
/// **Options are never truncated.** An option is the text of the thing a person is
/// choosing between, so shortening it is the same failure as abbreviating a consent
/// payload. `AgentChoice.isPresentable` is what refuses the card when they will not
/// fit; the caller shows the deferral instead of rendering a lie.
struct NotchAgentChoiceCard: View {
    let choice: AgentChoice
    let question: AgentChoice.Question
    let onAnswer: (_ selected: [String]) -> Void

    /// Held by the card because a multi-select is only an answer once confirmed.
    @State private var selected: Set<String> = []

    /// The card's own metrics.
    ///
    /// Named and **pinned to explicit frames below**, because the band's thickness is
    /// decided by `NotchAgentPanel.thickness` before the card lays out. If the two
    /// disagreed the band would clip its own content, which is exactly what the first
    /// render of this card did: the context row underneath was cut in half.
    enum Metrics {
        static let header: CGFloat = 30
        static let optionRow: CGFloat = 28
        static let footer: CGFloat = 22
        static let spacing: CGFloat = Theme.Space.sm
        static let verticalPadding: CGFloat = Theme.Space.md

        /// Height for a card with `optionCount` options.
        static func height(optionCount: Int) -> CGFloat {
            let rows = CGFloat(optionCount)
            // header + options + footer, with a gap between each pair.
            let gaps = rows + 1
            return verticalPadding * 2 + header + rows * optionRow + footer + gaps * spacing
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            header
                .frame(height: Metrics.header)
            ForEach(question.visibleOptions, id: \.self) { option in
                optionRow(option)
                    .frame(height: Metrics.optionRow)
            }
            footer
                .frame(height: Metrics.footer)
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.vertical, Metrics.verticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(question.text)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(question.text)
                .font(Typography.notchTitle)
                .foregroundStyle(Theme.Notch.text)
                .lineLimit(2)
            Text(subtitle)
                .font(Typography.notchCaption)
                .foregroundStyle(Theme.Notch.textSecondary)
                .lineLimit(1)
        }
    }

    private var subtitle: String {
        var parts = [choice.context].filter { !$0.isEmpty }
        if question.multiSelect { parts.append("pick any") }
        if question.hiddenOptionCount > 0 {
            // Never a silent truncation: say how many are not on the band.
            parts.append("\(question.hiddenOptionCount) more in kunai")
        }
        return parts.joined(separator: " · ")
    }

    private func optionRow(_ option: String) -> some View {
        Button {
            tap(option)
        } label: {
            HStack(spacing: Theme.Space.sm) {
                // The same ember rail the dictation target uses, so "this is the one
                // selected" reads the same way everywhere on the band.
                RoundedRectangle(cornerRadius: 2)
                    .fill(selected.contains(option) ? Theme.Notch.accent : Color.clear)
                    .frame(width: 3, height: 16)
                Text(option)
                    .font(Typography.notchBody)
                    .foregroundStyle(Theme.Notch.text)
                    .lineLimit(1)
                Spacer(minLength: Theme.Space.sm)
            }
            .padding(.horizontal, Theme.Space.sm)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Theme.Notch.text.opacity(selected.contains(option) ? 0.10 : 0.045)))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .accessibilityLabel(option)
        .accessibilityAddTraits(selected.contains(option) ? [.isSelected] : [])
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: Theme.Space.sm) {
            Button("Skip") { onAnswer([]) }
                .buttonStyle(.plain)
                .font(Typography.notchCaption)
                .foregroundStyle(Theme.Notch.textTertiary)
                .pointerCursor()
                .accessibilityLabel("Skip this question")

            Spacer(minLength: Theme.Space.sm)

            if question.multiSelect {
                Button("Send") { onAnswer(orderedSelection) }
                    .buttonStyle(.plain)
                    .font(Typography.notchCaption)
                    .foregroundStyle(Theme.Notch.text)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Theme.Notch.text.opacity(selected.isEmpty ? 0.08 : 0.22)))
                    .disabled(selected.isEmpty)
                    .pointerCursor()
            }
        }
    }

    /// Selection in the order the options were offered, not the order they were
    /// tapped: the answer goes back to the model as text, and the model wrote that
    /// order.
    private var orderedSelection: [String] {
        question.visibleOptions.filter { selected.contains($0) }
    }

    private func tap(_ option: String) {
        guard question.multiSelect else {
            // Single select is the answer, so it commits immediately. Making someone
            // tap an option and then a confirm is one tap too many on a band that is
            // holding a turn open.
            onAnswer([option])
            return
        }
        if selected.contains(option) { selected.remove(option) } else { selected.insert(option) }
    }
}
