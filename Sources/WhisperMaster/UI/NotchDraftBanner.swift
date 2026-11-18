import SwiftUI

/// Text the assistant wrote for the app the user was in, on the band, waiting on a
/// tap. The tap is the consent: nothing reaches the other app until **Replace** (or
/// **Insert**) is pressed, and then it is pasted, never followed by Return.
///
/// The draft is shown exactly as it will be typed: plain text, line breaks kept,
/// never markdown-rendered (a `#` or a `*` would vanish into styling and the user
/// would approve text they did not see). Past `Metrics.maxBodyLines` it scrolls
/// rather than clips, so no part of what a tap types is out of reach.
///
/// When typing is not safe (`AgentDraft.copyOnlyReason`) the only action is Copy and
/// the reason takes the subtitle, in the warning colour.
///
/// Interactive, so it is in `DictationPillContent.allowsHitTesting` and the
/// `setInteractive` call in the AppDelegate refresh loop.
struct NotchDraftBanner: View {
    enum Action {
        case apply
        case copy
        case dismiss
    }

    let draft: AgentDraft
    /// Width of the text column, from the surface the band is laid out in. The
    /// band's height is measured against the same number.
    let bodyWidth: CGFloat
    var onAction: (Action) -> Void = { _ in }

    @Environment(\.isSnapshot) private var isSnapshot
    /// Flips Copy to a confirmation. Local: it resets with the next draft.
    @State private var copied = false

    enum Metrics {
        static let headerHeight: CGFloat = 34
        static let gap: CGFloat = Theme.Space.sm
        static let verticalPadding: CGFloat = 10
        /// Lines shown before the text scrolls. Kept so `maxThickness` stays inside
        /// the panel's height, which is sized once (`NotchAgentPanel.maxThickness`).
        static let maxBodyLines = 8
        /// The column is measured this much narrower than it is set: `Text` breaks a
        /// little earlier than the greedy wrap. `NotchAgentReplyExpanded` uses 0.94.
        static let measureSlack: CGFloat = 0.94
        /// The shape's frame includes its concave top flares, so the black body is
        /// `topConcaveRadius` narrower on each side than the frame. A centred banner
        /// never shows this; a band filled edge to edge does.
        static let horizontalPadding: CGFloat = Theme.Space.lg + NotchSurfaceLayout().topConcaveRadius
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gap) {
            header
                .frame(height: Metrics.headerHeight)
            bodyText
        }
        .padding(.horizontal, Metrics.horizontalPadding)
        .padding(.vertical, Metrics.verticalPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: draft) { copied = false }
    }

    private var header: some View {
        HStack(spacing: Theme.Space.md) {
            HStack(spacing: Theme.Space.md) {
                Image(systemName: "text.cursor")
                    .font(Typography.notchTitle)
                    .foregroundStyle(Theme.Notch.text.opacity(0.9))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(Typography.notchTitle)
                        .foregroundStyle(Theme.Notch.text)
                    Text(subtitle)
                        .font(Typography.notchCaption)
                        .foregroundStyle(draft.copyOnlyReason == nil
                                         ? Theme.Notch.textSecondary : Theme.Notch.warning)
                }
                .lineLimit(1)
                .truncationMode(.tail)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityText)
            .layoutPriority(-1)

            Spacer(minLength: Theme.Space.sm)

            HStack(spacing: 6) {
                if draft.copyOnlyReason == nil {
                    button(draft.actionTitle, filled: true) { onAction(.apply) }
                }
                button(copied ? "Copied" : "Copy", filled: draft.copyOnlyReason != nil) {
                    onAction(.copy)
                    copied = true
                }
                .disabled(copied)
                Button { onAction(.dismiss) } label: {
                    Image(systemName: "xmark")
                        .font(Typography.notchCaption)
                        .foregroundStyle(Theme.Notch.textSecondary)
                        .padding(6)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss the draft")
                .pointerCursor()
            }
        }
    }

    @ViewBuilder
    private var bodyText: some View {
        let text = Text(draft.text)
            .font(Typography.notchBody)
            .foregroundStyle(Theme.Notch.text)
            .lineSpacing(NotchTextMetrics.lineSpacing)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(draft.text)
        let height = Self.bodyHeight(for: draft.text, width: bodyWidth)
        if Self.lineCount(draft.text, width: bodyWidth) > Metrics.maxBodyLines, !isSnapshot {
            ScrollView(.vertical, showsIndicators: true) { text }
                .frame(height: height)
        } else {
            // Clipped in the headless render too, so a snapshot shows what the band
            // shows rather than text drawn past its foot.
            text.frame(height: height, alignment: .top).clipped()
        }
    }

    private var title: String {
        draft.kind == .replaceSelection ? "Rewrite for \(draft.app.name)" : "Draft for \(draft.app.name)"
    }

    private var subtitle: String {
        draft.copyOnlyReason ?? "Nothing is typed until you tap \(draft.actionTitle)."
    }

    var accessibilityText: String {
        "\(title). \(subtitle)"
    }

    private func button(_ title: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(Typography.notchCaption)
            .foregroundStyle(filled ? Theme.Notch.surface : Theme.Notch.text)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(filled ? Theme.Notch.text : Theme.Notch.text.opacity(0.12)))
            .pointerCursor()
    }

    // MARK: - Height

    /// Lines the draft takes at `width`, with each line break kept. Measured with
    /// `NotchTextMetrics`, whose font is `Typography.notchBody`.
    ///
    /// Two corrections keep it from under-counting, the one error that shows (the
    /// band clips the tail and nothing scrolls): the column is measured narrower than
    /// it is set (`measureSlack`, the expanded reply's figure), and a token wider than
    /// the column (a URL, a path, base64) counts a line per column width, where the
    /// greedy wrap gives it one.
    static func lineCount(_ text: String, width: CGFloat) -> Int {
        let column = max(width * Metrics.measureSlack, 1)
        return text.components(separatedBy: .newlines).reduce(0) { total, paragraph in
            let widths = paragraph.split(separator: " ").map { NotchTextMetrics.width(String($0)) }
            let wrapped = NotchTranscriptModel.wrap(
                widths: widths, spacing: NotchTextMetrics.spaceWidth, maxWidth: column).count
            let overflow = widths.reduce(0) { sum, word in
                sum + max(0, Int((word / column).rounded(.up)) - 1)
            }
            return total + max(1, wrapped + overflow)
        }
    }

    static func bodyHeight(for text: String, width: CGFloat) -> CGFloat {
        NotchTextMetrics.blockHeight(lines: min(lineCount(text, width: width), Metrics.maxBodyLines))
    }

    /// The band's height for this draft. The band's height is decided before the
    /// banner lays out, so `DictationPillContent.bandThickness` reads this.
    static func thickness(for draft: AgentDraft, bodyWidth: CGFloat) -> CGFloat {
        Metrics.verticalPadding * 2 + Metrics.headerHeight + Metrics.gap
            + bodyHeight(for: draft.text, width: bodyWidth)
    }

    /// The tallest draft band. Must not pass the panel's band height.
    static let maxThickness: CGFloat = Metrics.verticalPadding * 2 + Metrics.headerHeight + Metrics.gap
        + NotchTextMetrics.blockHeight(lines: Metrics.maxBodyLines)

    /// The text column's width inside a surface of `surfaceWidth`.
    static func bodyWidth(surfaceWidth: CGFloat) -> CGFloat {
        surfaceWidth - Metrics.horizontalPadding * 2
    }
}
