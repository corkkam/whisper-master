import AppKit
import SwiftUI

/// The full reply, on the band — what clicking the one-line finish banner opens,
/// and what the "Show full replies" setting makes the default.
///
/// Prose renders as prose (inline markdown honoured), fenced code as code on a
/// quiet inset, and the files the turn edited close the band. Content taller than
/// the cap clips behind a bottom fade with kunai named as where the rest lives —
/// the same treatment the polished beat gives text that outgrows its window, and
/// the cap is what keeps a long reply from laying a wall of black over half the
/// screen.
///
/// **The band's height is decided before this lays out** (the standing rule —
/// `NotchAgentChoiceCard.Metrics` explains the clipped-context-row bug that minted
/// it), so `thickness(for:width:)` measures the same fonts at the same width the
/// body renders, and the clip design absorbs the last point of drift.
struct NotchAgentReplyExpanded: View {
    let document: AgentReplyDocument
    let repo: String
    var duration: TimeInterval?
    var editedPaths: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.blockSpacing) {
            content
            footer
                .frame(height: Metrics.footer)
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.vertical, Metrics.verticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Reply from \(repo)")
    }

    @ViewBuilder
    private var content: some View {
        let measured = Self.contentHeight(for: document, width: Metrics.assumedTextWidth)
        VStack(alignment: .leading, spacing: Metrics.blockSpacing) {
            ForEach(Array(document.blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .prose(let text):
                    Text(Self.inlineMarkdown(text))
                        .font(Typography.notchBody)
                        .foregroundStyle(Theme.Notch.text)
                        .fixedSize(horizontal: false, vertical: true)
                case .code(let text):
                    Text(text)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.Notch.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(Metrics.codeInset)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Theme.Notch.text.opacity(0.05)))
                }
            }
        }
        .frame(maxHeight: Metrics.contentCap, alignment: .top)
        .clipped()
        .overlay(alignment: .bottom) {
            if measured > Metrics.contentCap {
                // The rest exists; say where, rather than ending mid-sentence with
                // no explanation.
                LinearGradient(
                    colors: [Theme.Notch.surface.opacity(0), Theme.Notch.surface],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 28)
                .allowsHitTesting(false)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: Theme.Space.sm) {
            if !editedPaths.isEmpty {
                Image(systemName: "pencil")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.Notch.textTertiary)
                Text(editedPaths.joined(separator: "  ·  "))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Theme.Notch.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: Theme.Space.sm)
            Text(trailing)
                .font(Typography.notchCaption)
                .foregroundStyle(Theme.Notch.textTertiary)
                .lineLimit(1)
        }
    }

    private var trailing: String {
        var parts = [repo]
        if let duration, duration >= 1 {
            parts.append(NotchAgentReplyBanner.compact(duration))
        }
        parts.append("full reply in kunai")
        return parts.joined(separator: " · ")
    }

    /// Inline markdown only: `code` and **bold** render, block syntax was already
    /// handled by the parser. A string that fails to parse renders as its plain self.
    private static func inlineMarkdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    // MARK: Metrics

    enum Metrics {
        static let verticalPadding: CGFloat = Theme.Space.md
        static let blockSpacing: CGFloat = Theme.Space.sm
        static let footer: CGFloat = 16
        static let codeInset: CGFloat = 8
        static let codeLineHeight: CGFloat = 15
        /// The most content the band will hold before clipping behind the fade. The
        /// notch is a summary surface; past this the reply is a document, and
        /// documents live in kunai.
        static let contentCap: CGFloat = 220
        /// The text width the height estimate assumes: the wide surface's usual text
        /// column. Measuring at a slightly conservative width errs tall, and the
        /// clip absorbs tall.
        static let assumedTextWidth: CGFloat = 500
    }

    /// The band thickness for a reply, measured with the same fonts the body uses.
    static func thickness(for document: AgentReplyDocument, width: CGFloat) -> CGFloat {
        Metrics.verticalPadding * 2
            + min(contentHeight(for: document, width: width), Metrics.contentCap)
            + Metrics.blockSpacing + Metrics.footer
    }

    /// The tallest the expanded band can be, for `NotchSurfaceLayout.panelSize`.
    static var maxThickness: CGFloat {
        Metrics.verticalPadding * 2 + Metrics.contentCap + Metrics.blockSpacing + Metrics.footer
    }

    /// Measured content height. Prose is measured with the notch body's `NSFont` at
    /// the given width; code is a line count times a fixed mono line height, since
    /// it does not wrap.
    static func contentHeight(for document: AgentReplyDocument, width: CGFloat) -> CGFloat {
        var total: CGFloat = 0
        for block in document.blocks {
            switch block {
            case .prose(let text):
                let bounds = NSAttributedString(
                    string: text, attributes: [.font: proseFont]
                ).boundingRect(
                    with: CGSize(width: width, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading])
                total += ceil(bounds.height) + 2  // slack for the SwiftUI/AppKit seam
            case .code(let text):
                let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
                total += CGFloat(lines) * Metrics.codeLineHeight + Metrics.codeInset * 2
            }
        }
        total += CGFloat(max(0, document.blocks.count - 1)) * Metrics.blockSpacing
        return total
    }

    /// Matched to `Typography.notchBody` (Figtree Medium 13). The system face
    /// stands in when the brand font is not registered — a headless test run — and
    /// the clip design absorbs the small difference.
    private static let proseFont: NSFont =
        NSFont(name: "Figtree-Medium", size: 13) ?? .systemFont(ofSize: 13, weight: .medium)
}
