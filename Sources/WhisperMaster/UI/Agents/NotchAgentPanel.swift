import SwiftUI

/// The agent surface as one band: the question, and everything else as context.
///
/// The shape this settled on is "the question **is** the panel". Not a row telling
/// you a question exists which you then click to see, but the question itself,
/// answerable where it appears, with the other sessions reduced to a dot and a word
/// underneath. That ordering is the design: one of these things is asking for
/// something and the rest are not.
///
/// The band only ever appears because something needs a person. Nothing here is
/// summoned, which is why the whole feature adds no keyboard shortcut.
struct NotchAgentPanel: View {
    let ask: AgentAsk
    let sessions: [AgentSession]
    let askingRepo: String
    let mode: KunaiWire.PermissionMode
    let now: Date

    let onResolve: (_ allow: Bool, _ always: Bool) -> Void
    let onAnswer: (_ question: AgentChoice.Question, _ selected: [String]) -> Void
    let onSelectMode: (KunaiWire.PermissionMode) -> Void

    private var others: [AgentSession] { Self.otherSessions(in: sessions, askingRepo: askingRepo) }

    /// The sessions that are not the one asking. Repeating the asker underneath its
    /// own question would be saying the same thing twice on a surface with no room
    /// to say anything twice.
    ///
    /// Static because the band's *thickness* has to be decided from the same answer
    /// the body renders, and computing it twice in two places is how those two drift
    /// apart.
    static func otherSessions(in sessions: [AgentSession], askingRepo: String)
        -> [AgentSession]
    {
        sessions.filter { !($0.repo == askingRepo && $0.isWaiting) }
    }

    var body: some View {
        VStack(spacing: 0) {
            question
            if !others.isEmpty {
                Divider()
                    .overlay(Theme.Notch.hairline)
                    .padding(.horizontal, Theme.Space.lg)
                NotchAgentSessionsRow(
                    sessions: others, now: now, mode: mode, onSelectMode: onSelectMode
                )
                .frame(height: NotchAgentPanel.contextRowHeight)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var question: some View {
        switch ask {
        case .approval(let approval):
            NotchAgentAskBanner(approval: approval, repo: askingRepo, onResolve: onResolve)
                .frame(maxHeight: .infinity)

        case .choice(let choice):
            if let primary = choice.primary, choice.isPresentable() {
                NotchAgentChoiceCard(choice: choice, question: primary) { selected in
                    onAnswer(primary, selected)
                }
            } else if let primary = choice.primary {
                // The options cannot be shown honestly, so the card defers rather
                // than truncating the text of something someone is choosing between.
                NotchBannerRow(
                    icon: "questionmark.bubble",
                    title: primary.text,
                    accessibilityText: "\(primary.text). Answer this one in kunai.",
                    textGivesWayToTrailing: true,
                    subtitle: { Text("Too long for the notch · answer in kunai") },
                    trailing: {
                        Button("Skip") { onAnswer(primary, []) }
                            .buttonStyle(.plain)
                            .font(Typography.notchCaption)
                            .foregroundStyle(Theme.Notch.textTertiary)
                            .pointerCursor()
                    })
            }
        }
    }

    /// Height of the ambient context row.
    static let contextRowHeight: CGFloat = 34

    /// The tallest this band can ever be: the fullest choice card (four options,
    /// multi-select, so it carries a Send) plus the context row.
    ///
    /// `NotchSurfaceLayout.maxBandThickness` reads this. The panel is sized once at
    /// window creation, so a band taller than its panel is clipped by its own
    /// window — the same trap `maxStateLabelWing` exists for on the width axis.
    static let maxThickness: CGFloat =
        NotchAgentChoiceCard.Metrics.height(optionCount: AgentChoice.maxVisibleOptions)
        + contextRowHeight

    /// How tall the whole band needs to be for a given ask.
    ///
    /// Content-driven, because a choice with four options is a different object from
    /// a one-line approval and giving both the same slab was the thing that made the
    /// first version read as a window.
    static func thickness(for ask: AgentAsk, otherSessions: Int, banner: CGFloat) -> CGFloat {
        let base: CGFloat
        switch ask {
        case .approval:
            base = banner
        case .choice(let choice):
            guard let primary = choice.primary, choice.isPresentable() else {
                // The deferral is a plain banner row.
                base = banner
                break
            }
            base = NotchAgentChoiceCard.Metrics.height(
                optionCount: primary.visibleOptions.count)
        }
        return base + (otherSessions > 0 ? contextRowHeight : 0)
    }
}
