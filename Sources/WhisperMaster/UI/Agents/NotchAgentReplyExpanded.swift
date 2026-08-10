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
    /// What the user asked, shown quietly above the answer. An answer with no
    /// visible question reads as content from nowhere.
    var prompt: String?
    let repo: String
    var duration: TimeInterval?
    var editedPaths: [String] = []
    /// The turn's tool calls, listed between the question and the answer — the
    /// Figma order, and the thing this band was rightly said to be hiding.
    var tools: [AgentTurnLog.ToolLine] = []
    /// The width the text renders at — the same number the height was measured
    /// with. Two different widths here is the skinny-tower bug.
    var textWidth: CGFloat = 500
    /// This session's page in kunai's web app. With it, "Open in kunai" is a real
    /// button; without it the words would be a link that goes nowhere, which is
    /// exactly what was reported.
    var kunaiURL: URL?
    /// The display this is drawn on. A reply is a document, so the card sizes
    /// itself against the screen rather than a constant.
    var geometry: NotchGeometry = .none

    @Environment(\.openURL) private var openURL
    /// `ImageRenderer` collapses a flexible `ScrollView` to nothing, so the
    /// headless renderer gets the plain stack. Same gate the other AppKit-backed
    /// surfaces use.
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.blockSpacing) {
            if let prompt {
                // Ember is *your voice* everywhere in this app — the listening wave,
                // the dictation rail — so your words wear it here too.
                HStack(alignment: .center, spacing: Theme.Space.sm) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Theme.Notch.accent)
                        .frame(width: 3)
                        .frame(maxHeight: Metrics.promptLine - 6)
                    Image(systemName: "mic.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.Notch.accent)
                    Text(prompt)
                        .font(Typography.notchCaption)
                        .foregroundStyle(Theme.Notch.text)
                        .lineLimit(2)
                }
                .frame(maxHeight: Metrics.promptLine, alignment: .leading)
            }
            if !visibleTools.isEmpty {
                ForEach(visibleTools) { tool in
                    toolRow(tool)
                        .frame(height: Metrics.toolRow)
                }
                if hiddenToolCount > 0 {
                    Text("+\(hiddenToolCount) more in kunai")
                        .font(Typography.notchCaption)
                        .foregroundStyle(Theme.Notch.textTertiary)
                        .frame(height: Metrics.toolRow)
                }
            }
            if prompt != nil || !visibleTools.isEmpty {
                Divider().overlay(Theme.Notch.hairline)
            }
            content
            Divider().overlay(Theme.Notch.hairline)
            footer
                .frame(height: Metrics.footer)
        }
        .padding(.horizontal, Metrics.horizontalPadding)
        .padding(.vertical, Metrics.verticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Reply from \(repo)")
    }

    @ViewBuilder
    private var content: some View {
        let measured = Self.contentHeight(for: document, width: textWidth - Metrics.railInset)
        let cap = Self.contentCap(for: geometry)
        // The machine's half wears signal, the way every working state does.
        HStack(alignment: .top, spacing: Theme.Space.sm) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Theme.Notch.success.opacity(0.75))
                .frame(width: 3)
                .frame(maxHeight: .infinity)
            if measured > cap, !isSnapshot {
                // **Nothing in a reply is unreachable.** Clipping the tail behind a
                // fade was the defect behind every "it looks the same" report: the
                // answer simply stopped mid-sentence and there was no way to read
                // the rest without leaving for the browser.
                ScrollView(.vertical, showsIndicators: true) {
                    answerBlocks()
                }
                .frame(height: cap)
            } else {
                answerBlocks()
                    .frame(maxHeight: cap, alignment: .top)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func answerBlocks() -> some View {
        VStack(alignment: .leading, spacing: Metrics.blockSpacing) {
            ForEach(Array(document.blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .prose(let text):
                    Text(Self.inlineMarkdown(text))
                        .font(Typography.notchBody)
                        .lineSpacing(Metrics.proseLineSpacing)
                        .foregroundStyle(Theme.Notch.text)
                        .fixedSize(horizontal: false, vertical: true)
                case .code(let text):
                    // One Text per line, never wrapped: wide command output (a
                    // worktree list, a table dump) shatters into soup when wrapped
                    // at the card's measure — and a wrapped line also breaks the
                    // height math, which counts source lines. Truncation is
                    // middle, where paths keep both their root and their leaf.
                    VStack(alignment: .leading, spacing: Metrics.codeLineSpacing) {
                        ForEach(
                            Array(text.split(
                                separator: "\n", omittingEmptySubsequences: false)
                                .enumerated()),
                            id: \.offset
                        ) { _, line in
                            Text(String(line))
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(Theme.Notch.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .padding(Metrics.codeInset)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Theme.Notch.text.opacity(0.05)))
                case .heading(let text):
                    Text(Self.inlineMarkdown(text))
                        .font(Typography.notchLabel)
                        .foregroundStyle(Theme.Notch.text)
                        .padding(.top, Metrics.headingTopGap)
                case .table(let header, let rows):
                    tableView(header: header, rows: rows)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// How much room the answer gets: most of the display, floored so a small
    /// screen still shows a paragraph. A reply is a document, and a constant cap
    /// meant a 16-inch display clipped at exactly the same arbitrary line a laptop
    /// did.
    static func contentCap(for geometry: NotchGeometry) -> CGFloat {
        guard geometry.screenHeight > 0 else { return Metrics.fallbackContentCap }
        return max(
            Metrics.fallbackContentCap,
            (geometry.screenHeight - geometry.notchHeight) * Metrics.screenFraction)
    }

    /// A pipe table as a real grid: header in caption ink over a hairline, cells
    /// in small mono, columns aligned. This is what was rendering as literal
    /// `| tool | path |` pipes.
    private func tableView(header: [String], rows: [[String]]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: Theme.Space.lg, verticalSpacing: 4) {
            if !header.isEmpty {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                        Text(Self.inlineMarkdown(cell))
                            .font(Typography.notchCaption)
                            .foregroundStyle(Theme.Notch.textTertiary)
                    }
                }
                Divider().overlay(Theme.Notch.hairline)
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        Text(Self.inlineMarkdown(cell))
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(Theme.Notch.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        }
        .padding(Metrics.codeInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Theme.Notch.text.opacity(0.05)))
    }

    private var visibleTools: [AgentTurnLog.ToolLine] {
        Array(tools.prefix(Metrics.maxToolRows))
    }
    private var hiddenToolCount: Int { max(0, tools.count - Metrics.maxToolRows) }

    /// One tool call, in kunai web's own idiom: a shell command reads as a
    /// terminal prompt — the ❯ says "command", so the word "Bash" is dropped —
    /// and every other tool leads with its name. The verdict sits at the
    /// trailing edge, quietly.
    private func toolRow(_ tool: AgentTurnLog.ToolLine) -> some View {
        HStack(spacing: Theme.Space.sm) {
            if tool.name == "Bash" {
                Text("❯")
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.Notch.textTertiary)
                Text(
                    AgentTurnLog.trimmedCommand(
                        tool.detail.hasPrefix("Run  ")
                            ? String(tool.detail.dropFirst(5)) : tool.detail))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Theme.Notch.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text(tool.name.uppercased())
                    .font(Typography.notchCaption)
                    .foregroundStyle(Theme.Notch.textTertiary)
                    .frame(minWidth: 40, alignment: .leading)
                Text(nonShellDetail(tool))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Theme.Notch.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: Theme.Space.sm)
            if let verdict = tool.verdict {
                Text(verdict)
                    .font(Typography.notchCaption)
                    .foregroundStyle(
                        verdict == "failed" ? Theme.Notch.danger : Theme.Notch.textTertiary)
            }
        }
    }

    /// The detail column without the tool's own verb repeated: the headline reads
    /// "Edit  UI/NotchGlow.swift" and the label column already says EDIT.
    private func nonShellDetail(_ tool: AgentTurnLog.ToolLine) -> String {
        guard !tool.detail.isEmpty else { return tool.name }
        let prefix = "\(tool.name)  "
        return tool.detail.hasPrefix(prefix)
            ? String(tool.detail.dropFirst(prefix.count)) : tool.detail
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
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.Notch.success)
            Text(trailing)
                .font(Typography.notchCaption)
                .foregroundStyle(Theme.Notch.textTertiary)
                .lineLimit(1)
            if let kunaiURL {
                // A real button in the band's own capsule idiom, not caption text
                // cosplaying as a link.
                Button("Open in kunai") { openURL(kunaiURL) }
                    .buttonStyle(.plain)
                    .font(Typography.notchCaption)
                    .foregroundStyle(Theme.Notch.text)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Theme.Notch.text.opacity(0.12)))
                    .pointerCursor()
                    .accessibilityLabel("Open this session in kunai")
            }
        }
    }

    private var trailing: String {
        guard let duration, duration >= 1 else { return repo }
        return "\(repo) · \(NotchAgentReplyBanner.compact(duration))"
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
        static let horizontalPadding: CGFloat = Theme.Space.xl
        /// Extra leading between prose lines: the measure is ~85 characters, and
        /// at that width the notch body's default leading reads as a wall.
        static let proseLineSpacing: CGFloat = 3
        static let verticalPadding: CGFloat = Theme.Space.lg
        static let blockSpacing: CGFloat = Theme.Space.sm
        static let footer: CGFloat = 22
        static let codeInset: CGFloat = 8
        static let codeLineHeight: CGFloat = 15
        static let codeLineSpacing: CGFloat = 2
        /// One table row (mono cell + grid spacing), and the header's extra chrome.
        static let tableRowHeight: CGFloat = 18
        static let tableHeaderHeight: CGFloat = 22
        /// Air above a heading, so sections read as sections.
        static let headingTopGap: CGFloat = 10
        static let headingHeight: CGFloat = 28
        /// Floor for the answer area, used when the screen is unknown (the headless
        /// renderer) and as the minimum on any display.
        static let fallbackContentCap: CGFloat = 320
        /// Share of the display the answer may occupy before it scrolls. Two thirds
        /// leaves the desktop legible underneath while giving a real reply room to
        /// be read in one go.
        static let screenFraction: CGFloat = 0.66
        /// The prompt line above the answer: two caption lines at most.
        static let promptLine: CGFloat = 30
        /// One tool call's row.
        static let toolRow: CGFloat = 18
        /// The most tool rows shown before "+N more in kunai".
        static let maxToolRows = 5
        /// The answer's signal rail plus its gap, charged against the text column.
        static let railInset: CGFloat = 11
    }

    /// The band thickness for a reply, measured with the same fonts the body uses.
    static func thickness(
        for document: AgentReplyDocument, prompt: String?, toolCount: Int,
        width: CGFloat, geometry: NotchGeometry
    ) -> CGFloat {
        let promptPart: CGFloat =
            prompt == nil ? 0 : Metrics.promptLine + Metrics.blockSpacing
        let shownTools = min(toolCount, Metrics.maxToolRows)
            + (toolCount > Metrics.maxToolRows ? 1 : 0)
        let toolPart = CGFloat(shownTools) * (Metrics.toolRow + Metrics.blockSpacing)
        let dividerPart: CGFloat =
            (prompt != nil || toolCount > 0) ? 1 + Metrics.blockSpacing : 0
        return Metrics.verticalPadding * 2 + promptPart + toolPart + dividerPart
            + min(
                contentHeight(for: document, width: width - Metrics.railInset),
                contentCap(for: geometry))
            + Metrics.blockSpacing + 1 + Metrics.blockSpacing + Metrics.footer
    }

    /// The tallest the expanded band can be, for `NotchSurfaceLayout.panelSize`.
    static func maxThickness(for geometry: NotchGeometry) -> CGFloat {
        thickness(
            for: AgentReplyDocument(blocks: []), prompt: "p",
            toolCount: Metrics.maxToolRows + 1, width: 500, geometry: geometry)
            + contentCap(for: geometry)
    }

    /// Measured content height. Prose is measured with the notch body's `NSFont` at
    /// the given width; code is a line count times a fixed mono line height, since
    /// it does not wrap.
    static func contentHeight(for document: AgentReplyDocument, width: CGFloat) -> CGFloat {
        var total: CGFloat = 0
        for block in document.blocks {
            switch block {
            case .prose(let text):
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineSpacing = Metrics.proseLineSpacing
                let bounds = NSAttributedString(
                    string: text,
                    attributes: [.font: proseFont, .paragraphStyle: paragraph]
                ).boundingRect(
                    with: CGSize(width: width, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading])
                total += ceil(bounds.height) + 2  // slack for the SwiftUI/AppKit seam
            case .code(let text):
                let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
                total += CGFloat(lines) * Metrics.codeLineHeight + Metrics.codeInset * 2
            case .heading:
                total += Metrics.headingHeight + Metrics.headingTopGap
            case .table(let header, let rows):
                total += (header.isEmpty ? 0 : Metrics.tableHeaderHeight)
                    + CGFloat(rows.count) * Metrics.tableRowHeight
                    + Metrics.codeInset * 2
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
