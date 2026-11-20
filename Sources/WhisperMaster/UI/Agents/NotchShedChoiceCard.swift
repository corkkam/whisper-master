import SwiftUI

/// A Shed question in the notch. Unlike `NotchAgentChoiceCard`, nothing is deferred:
/// the whole question wraps and every option is listed (Shed allows up to 12), inside
/// a fixed-height scroll area so the band's size stays known before layout.
struct NotchShedChoiceCard: View {
    let choice: AgentChoice
    let question: AgentChoice.Question
    let onAnswer: (_ selected: [String]) -> Void
    var onOpen: (() -> Void)?

    enum Metrics {
        static let scrollHeight: CGFloat = 190
        static let footer: CGFloat = 22
        static let height: CGFloat =
            Theme.Space.md * 2 + scrollHeight + footer + Theme.Space.sm
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Text(question.text)
                        .font(Typography.notchTitle)
                        .foregroundStyle(Theme.Notch.text)
                        .fixedSize(horizontal: false, vertical: true)
                    if !choice.context.isEmpty {
                        Text(choice.context)
                            .font(Typography.notchCaption)
                            .foregroundStyle(Theme.Notch.textSecondary)
                    }
                    ForEach(Array(question.options.enumerated()), id: \.offset) { _, option in
                        Button { onAnswer([option]) } label: {
                            Text(option)
                                .font(Typography.notchBody)
                                .foregroundStyle(Theme.Notch.text)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, Theme.Space.sm)
                                .padding(.vertical, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Theme.Notch.text.opacity(0.06)))
                        }
                        .buttonStyle(.plain)
                        .pointerCursor()
                        .accessibilityLabel(option)
                    }
                }
            }
            .frame(height: Metrics.scrollHeight)
            HStack(spacing: Theme.Space.sm) {
                Button("Skip") { onAnswer([]) }
                    .buttonStyle(.plain)
                    .font(Typography.notchCaption)
                    .foregroundStyle(Theme.Notch.textTertiary)
                    .pointerCursor()
                    .accessibilityLabel("Skip this question")
                Spacer(minLength: Theme.Space.sm)
                if let onOpen {
                    Button("Open in Shed", action: onOpen)
                        .buttonStyle(.plain)
                        .font(Typography.notchCaption)
                        .foregroundStyle(Theme.Notch.text)
                        .pointerCursor()
                }
            }
            .frame(height: Metrics.footer)
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.vertical, Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(question.text)
    }
}
