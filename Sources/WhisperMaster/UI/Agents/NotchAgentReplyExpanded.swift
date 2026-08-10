import AppKit
import SwiftUI

/// The finished turn, opened out into a **console**: a header naming the session,
/// a left rail carrying the run, and the answer on its own raised panel beside it.
///
/// This is the widest and tallest thing the notch ever becomes, and the shape is
/// the point. The first version stacked everything into one narrow column — the
/// question, then the tool calls, then the answer, then a footer — which is a
/// document, not a surface: it grew downward without ever using the width, so a
/// real reply became a tall grey wall with its tail clipped. Splitting the run
/// away from the answer puts the two questions a finished turn raises ("what did
/// it do", "what did it say") side by side, and lets the answer keep a readable
/// measure while the band gets genuinely wide.
///
/// **The band's height is decided before this lays out** (the standing rule —
/// `NotchAgentChoiceCard.Metrics` explains the clipped-context-row bug that minted
/// it), so `thickness(...)` measures the same fonts at the same widths the body
/// renders at, and both columns scroll rather than clip once they pass the cap.
struct NotchAgentReplyExpanded: View {
    let document: AgentReplyDocument
    /// What the user asked, shown at the top of the rail. An answer with no
    /// visible question reads as content from nowhere.
    var prompt: String?
    let repo: String
    var duration: TimeInterval?
    var editedPaths: [String] = []
    /// The turn's tool calls, as a timeline down the rail.
    var tools: [AgentTurnLog.ToolLine] = []
    /// The full width of the black surface. Both columns are derived from it, and
    /// the height is measured against the same derivation — measuring at one width
    /// while rendering at another is what produced the skinny over-wrapped tower.
    var surfaceWidth: CGFloat = 900
    /// This session's page in kunai's web app.
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
        VStack(alignment: .leading, spacing: 0) {
            header
                .frame(height: Metrics.headerHeight)
            Divider().overlay(Theme.Notch.hairline)
                .padding(.top, Metrics.headerGap / 2)
                .padding(.bottom, Metrics.headerGap / 2)
            HStack(alignment: .top, spacing: Metrics.columnGap) {
                rail
                    .frame(width: Metrics.railWidth, alignment: .leading)
                answerPanel
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: bodyHeight, alignment: .top)
            collapseHint
                .frame(height: Metrics.collapseHint)
        }
        .padding(.horizontal, Metrics.horizontalPadding)
        .padding(.vertical, Metrics.verticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Reply from \(repo)")
    }

    // MARK: Header

    /// Session, verdict and the way out — the three things that belong to the turn
    /// as a whole rather than to either column.
    private var header: some View {
        HStack(spacing: Theme.Space.sm) {
            Circle()
                .fill(Theme.Notch.success)
                .frame(width: 7, height: 7)
            Text(repo.isEmpty ? "agent" : repo)
                .font(Typography.notchLabel)
                .foregroundStyle(Theme.Notch.text)
                .lineLimit(1)
            statusChip
            Spacer(minLength: Theme.Space.sm)
            if let kunaiURL {
                // A real button in the band's own capsule idiom, not caption text
                // cosplaying as a link.
                Button {
                    openURL(kunaiURL)
                } label: {
                    HStack(spacing: 4) {
                        Text("Open in kunai")
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 8, weight: .bold))
                    }
                }
                .buttonStyle(.plain)
                .font(Typography.notchCaption)
                .foregroundStyle(Theme.Notch.text)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(Theme.Notch.controlFill))
                .pointerCursor()
                .accessibilityLabel("Open this session in kunai")
            }
        }
    }

    /// "Finished · 3m 12s" as one quiet capsule. The verdict and how long it took
    /// are read together, so they are one object rather than two stray captions.
    private var statusChip: some View {
        HStack(spacing: 5) {
            Image(systemName: "checkmark")
                .font(.system(size: 8, weight: .bold))
            Text(durationLabel)
        }
        .font(Typography.notchCaption)
        .foregroundStyle(Theme.Notch.success)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Theme.Notch.success.opacity(0.14)))
    }

    private var durationLabel: String {
        guard let duration, duration >= 1 else { return "Finished" }
        return NotchAgentReplyBanner.compact(duration)
    }

    // MARK: The rail — what the turn did

    /// The run, in the order it happened: what was asked, what was called, what
    /// changed on disk. All of it is metadata about the answer, so it lives beside
    /// the answer rather than above it.
    @ViewBuilder
    private var rail: some View {
        let stack = VStack(alignment: .leading, spacing: Metrics.sectionGap) {
            if let prompt, !prompt.isEmpty {
                section("You asked") {
                    HStack(alignment: .top, spacing: Theme.Space.sm) {
                        // Ember is *your voice* everywhere in this app — the
                        // listening wave, the dictation rail — so your words wear
                        // it here too.
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Theme.Notch.accent)
                            .frame(width: 3)
                        Text(prompt)
                            .font(Typography.notchBody)
                            .lineSpacing(Metrics.proseLineSpacing)
                            .foregroundStyle(Theme.Notch.text)
                            .lineLimit(Metrics.promptMaxLines)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !visibleTools.isEmpty {
                section("What it did") {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(visibleTools) { tool in
                            toolRow(tool).frame(height: Metrics.toolRow)
                        }
                        if hiddenToolCount > 0 {
                            Text("+\(hiddenToolCount) more")
                                .font(Typography.notchCaption)
                                .foregroundStyle(Theme.Notch.textTertiary)
                                .padding(.leading, Metrics.toolGlyphColumn)
                                .frame(height: Metrics.toolRow, alignment: .leading)
                        }
                    }
                    .background(alignment: .leading) {
                        // The timeline's spine, behind the status glyphs: it is
                        // what makes a column of calls read as one run.
                        Rectangle()
                            .fill(Theme.Notch.hairline)
                            .frame(width: 1)
                            .padding(.vertical, Metrics.toolRow / 2)
                            .padding(.leading, Metrics.toolGlyphColumn / 2 - 0.5)
                    }
                }
            }
            if !visiblePaths.isEmpty {
                section("Changed") {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(visiblePaths, id: \.self) { path in
                            Text(path)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(Theme.Notch.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                                .frame(height: Metrics.pathRow, alignment: .leading)
                        }
                        if hiddenPathCount > 0 {
                            Text("+\(hiddenPathCount) more")
                                .font(Typography.notchCaption)
                                .foregroundStyle(Theme.Notch.textTertiary)
                                .frame(height: Metrics.pathRow, alignment: .leading)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        if railHeight > bodyHeight, !isSnapshot {
            ScrollView(.vertical, showsIndicators: false) { stack }
        } else {
            stack
        }
    }

    /// A rail section: a tracked, uppercase label over its content. The label is
    /// the console's one piece of typographic character, and it is what turns three
    /// stacked lists into three named things.
    @ViewBuilder
    private func section<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Metrics.labelGap) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .bold))
                .tracking(1.1)
                .foregroundStyle(Theme.Notch.textTertiary)
                .frame(height: Metrics.sectionLabel, alignment: .leading)
            content()
        }
    }

    /// One tool call: a status glyph, then the call in kunai web's own idiom — a
    /// shell command reads as a terminal prompt (the ❯ says "command", so the word
    /// "Bash" is dropped) and every other tool leads with its name.
    private func toolRow(_ tool: AgentTurnLog.ToolLine) -> some View {
        HStack(spacing: 0) {
            Image(systemName: verdictGlyph(tool.verdict))
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(verdictTint(tool.verdict))
                .frame(width: Metrics.toolGlyphColumn, alignment: .leading)
            if tool.name == "Bash" {
                Text("❯ ")
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.Notch.textTertiary)
                Text(
                    AgentTurnLog.trimmedCommand(
                        tool.detail.hasPrefix("Run  ")
                            ? String(tool.detail.dropFirst(5)) : tool.detail)
                )
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Theme.Notch.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            } else {
                Text(tool.name.lowercased())
                    .font(Typography.notchCaption)
                    .foregroundStyle(Theme.Notch.textTertiary)
                Text("  " + nonShellDetail(tool))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Theme.Notch.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
    }

    private func verdictGlyph(_ verdict: String?) -> String {
        switch verdict {
        case "failed", "denied": return "xmark"
        case .some: return "checkmark"
        case nil: return "circle"
        }
    }

    private func verdictTint(_ verdict: String?) -> Color {
        switch verdict {
        case "failed", "denied": return Theme.Notch.danger
        case .some: return Theme.Notch.success
        case nil: return Theme.Notch.textTertiary
        }
    }

    /// The detail column without the tool's own verb repeated: the headline reads
    /// "Edit  UI/NotchGlow.swift" and the label already says edit.
    private func nonShellDetail(_ tool: AgentTurnLog.ToolLine) -> String {
        guard !tool.detail.isEmpty else { return tool.name }
        let prefix = "\(tool.name)  "
        return tool.detail.hasPrefix(prefix)
            ? String(tool.detail.dropFirst(prefix.count)) : tool.detail
    }

    // MARK: The answer

    /// The reply itself, on its own slightly raised panel. Two surfaces rather than
    /// one is what stops the answer from reading as more rail: the run is written
    /// on the bezel, the answer is written on something laid over it.
    private var answerPanel: some View {
        let measured = Self.contentHeight(for: document, width: answerTextWidth)
        let cap = bodyHeight - Metrics.answerInset * 2
        return Group {
            if measured > cap, !isSnapshot {
                // **Nothing in a reply is unreachable.** Clipping the tail behind a
                // fade was the original defect: the answer simply stopped
                // mid-sentence with no way to read the rest without leaving for the
                // browser.
                ScrollView(.vertical, showsIndicators: true) { answerBlocks() }
            } else {
                answerBlocks()
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .padding(Metrics.answerInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: Metrics.answerRadius)
                .fill(Color.white.opacity(0.035)))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.answerRadius)
                .strokeBorder(Theme.Notch.hairline, lineWidth: 1))
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
                    codeBlock(text)
                case .heading(let text):
                    // A marker rather than a bigger font: at this size weight alone
                    // did not separate sections, and the answer panel has no room
                    // for display type.
                    HStack(spacing: Theme.Space.sm) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Theme.Notch.success)
                            .frame(width: 3, height: 12)
                        Text(Self.inlineMarkdown(text))
                            .font(Typography.notchLabel)
                            .foregroundStyle(Theme.Notch.text)
                    }
                    .padding(.top, Metrics.headingTopGap)
                case .table(let header, let rows):
                    tableView(header: header, rows: rows)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Command output, one `Text` per line and never wrapped: wide output (a
    /// worktree list, a table dump) shatters into soup when wrapped at the panel's
    /// measure — and a wrapped line also breaks the height math, which counts
    /// source lines. Truncation is middle, where paths keep both root and leaf.
    private func codeBlock(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: Metrics.codeLineSpacing) {
            ForEach(
                Array(
                    text.split(separator: "\n", omittingEmptySubsequences: false)
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
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.black.opacity(0.35)))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Theme.Notch.hairline, lineWidth: 1))
    }

    /// A pipe table as a real grid: header in caption ink over a hairline, cells in
    /// small mono, columns aligned. This is what was rendering as literal
    /// `| tool | path |` pipes.
    private func tableView(header: [String], rows: [[String]]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: Theme.Space.lg, verticalSpacing: 4) {
            if !header.isEmpty {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                        Text(Self.inlineMarkdown(cell.uppercased()))
                            .font(.system(size: 9, weight: .bold))
                            .tracking(0.9)
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
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.black.opacity(0.35)))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Theme.Notch.hairline, lineWidth: 1))
    }

    /// The way back. The whole card is tappable, but a surface this size has to say
    /// so — a band that fills half the screen with no visible exit reads as stuck.
    private var collapseHint: some View {
        HStack {
            Spacer()
            Image(systemName: "chevron.compact.up")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Notch.textTertiary.opacity(0.7))
            Spacer()
        }
        .accessibilityLabel("Collapse this reply")
    }

    // MARK: Derived widths and heights

    private var visibleTools: [AgentTurnLog.ToolLine] {
        Array(tools.prefix(Metrics.maxToolRows))
    }
    private var hiddenToolCount: Int { max(0, tools.count - Metrics.maxToolRows) }
    private var visiblePaths: [String] { Array(editedPaths.prefix(Metrics.maxPathRows)) }
    private var hiddenPathCount: Int { max(0, editedPaths.count - Metrics.maxPathRows) }

    private var answerTextWidth: CGFloat {
        Self.answerTextWidth(surfaceWidth: surfaceWidth)
    }

    private var railHeight: CGFloat {
        Self.railHeight(prompt: prompt, toolCount: tools.count, changedCount: editedPaths.count)
    }

    private var bodyHeight: CGFloat {
        Self.bodyHeight(
            document: document, prompt: prompt, toolCount: tools.count,
            changedCount: editedPaths.count, surfaceWidth: surfaceWidth, geometry: geometry)
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
        static let horizontalPadding: CGFloat = 26
        static let verticalPadding: CGFloat = 18
        /// The header strip and the air between it and the columns.
        static let headerHeight: CGFloat = 26
        static let headerGap: CGFloat = 18
        /// The run rail. Wide enough for a real path in mono at 10.5pt without the
        /// middle truncation eating the informative part.
        static let railWidth: CGFloat = 306
        static let columnGap: CGFloat = 26
        /// The answer panel's own inset and shape.
        static let answerInset: CGFloat = 18
        static let answerRadius: CGFloat = 14
        /// Extra leading between prose lines: at this measure the notch body's
        /// default leading reads as a wall.
        static let proseLineSpacing: CGFloat = 3
        static let blockSpacing: CGFloat = Theme.Space.sm
        static let codeInset: CGFloat = 9
        static let codeLineHeight: CGFloat = 15
        static let codeLineSpacing: CGFloat = 2
        static let tableRowHeight: CGFloat = 18
        static let tableHeaderHeight: CGFloat = 22
        static let headingTopGap: CGFloat = 10
        static let headingHeight: CGFloat = 24
        /// A rail section's label and the gap under it.
        static let sectionLabel: CGFloat = 12
        static let labelGap: CGFloat = 7
        static let sectionGap: CGFloat = 18
        /// The column the status glyph occupies, and therefore where the timeline's
        /// spine runs.
        static let toolGlyphColumn: CGFloat = 16
        static let toolRow: CGFloat = 21
        static let maxToolRows = 8
        static let pathRow: CGFloat = 17
        static let maxPathRows = 5
        /// The spoken prompt, at most this many lines in the rail.
        static let promptMaxLines = 5
        /// The collapse affordance at the foot of the card.
        static let collapseHint: CGFloat = 14
        /// Share of the display the whole card may occupy before its columns
        /// scroll. A reply is a document; a constant cap meant a 16-inch display
        /// and a laptop both stopped at the same arbitrary line.
        static let screenFraction: CGFloat = 0.62
        /// Floor for the body, used when the screen is unknown (the headless
        /// renderer) and as the minimum on any display.
        static let fallbackBodyHeight: CGFloat = 340
    }

    // MARK: Measurement (shared with `NotchSurfaceLayout`)

    /// The measure the answer's prose is wrapped at — the surface minus the card's
    /// padding, the rail, the gap, and the answer panel's own inset.
    static func answerTextWidth(surfaceWidth: CGFloat) -> CGFloat {
        max(
            220,
            surfaceWidth - Metrics.horizontalPadding * 2 - Metrics.railWidth
                - Metrics.columnGap - Metrics.answerInset * 2)
    }

    /// How tall the rail's three sections come out.
    static func railHeight(prompt: String?, toolCount: Int, changedCount: Int) -> CGFloat {
        var sections: [CGFloat] = []
        if let prompt, !prompt.isEmpty {
            let width = Metrics.railWidth - 3 - Theme.Space.sm
            let measured = proseHeight(prompt, width: width)
            let lineCap = CGFloat(Metrics.promptMaxLines) * (proseLineHeight + Metrics.proseLineSpacing)
            sections.append(Metrics.sectionLabel + Metrics.labelGap + min(measured, lineCap))
        }
        if toolCount > 0 {
            let rows = min(toolCount, Metrics.maxToolRows)
                + (toolCount > Metrics.maxToolRows ? 1 : 0)
            sections.append(
                Metrics.sectionLabel + Metrics.labelGap + CGFloat(rows) * Metrics.toolRow)
        }
        if changedCount > 0 {
            let rows = min(changedCount, Metrics.maxPathRows)
                + (changedCount > Metrics.maxPathRows ? 1 : 0)
            sections.append(
                Metrics.sectionLabel + Metrics.labelGap + CGFloat(rows) * Metrics.pathRow)
        }
        guard !sections.isEmpty else { return 0 }
        return sections.reduce(0, +) + CGFloat(sections.count - 1) * Metrics.sectionGap
    }

    /// The tallest the two columns are allowed to be before they scroll.
    static func bodyCap(for geometry: NotchGeometry) -> CGFloat {
        guard geometry.screenHeight > 0 else { return Metrics.fallbackBodyHeight }
        return max(
            Metrics.fallbackBodyHeight,
            (geometry.screenHeight - geometry.notchHeight) * Metrics.screenFraction)
    }

    /// The height the columns actually take: the taller of the two, capped. Short
    /// answers keep a short band — the card only grows to the cap when there is
    /// something that long to read.
    static func bodyHeight(
        document: AgentReplyDocument, prompt: String?, toolCount: Int, changedCount: Int,
        surfaceWidth: CGFloat, geometry: NotchGeometry
    ) -> CGFloat {
        let answer =
            contentHeight(for: document, width: answerTextWidth(surfaceWidth: surfaceWidth))
            + Metrics.answerInset * 2
        let rail = railHeight(prompt: prompt, toolCount: toolCount, changedCount: changedCount)
        return min(bodyCap(for: geometry), max(answer, rail))
    }

    /// The band thickness for a reply, measured with the same fonts and widths the
    /// body renders at.
    static func thickness(
        for document: AgentReplyDocument, prompt: String?, toolCount: Int,
        changedCount: Int, surfaceWidth: CGFloat, geometry: NotchGeometry
    ) -> CGFloat {
        chrome
            + bodyHeight(
                document: document, prompt: prompt, toolCount: toolCount,
                changedCount: changedCount, surfaceWidth: surfaceWidth, geometry: geometry)
    }

    /// Everything that isn't the two columns: padding, header, its rule, and the
    /// collapse affordance.
    private static var chrome: CGFloat {
        Metrics.verticalPadding * 2 + Metrics.headerHeight + Metrics.headerGap + 1
            + Metrics.collapseHint
    }

    /// The tallest the expanded band can be, for `NotchSurfaceLayout.panelSize`.
    static func maxThickness(for geometry: NotchGeometry) -> CGFloat {
        chrome + bodyCap(for: geometry)
    }

    /// Measured content height. Prose is measured with the notch body's `NSFont` at
    /// the given width; code is a line count times a fixed mono line height, since
    /// it does not wrap.
    static func contentHeight(for document: AgentReplyDocument, width: CGFloat) -> CGFloat {
        var total: CGFloat = 0
        for block in document.blocks {
            switch block {
            case .prose(let text):
                total += proseHeight(text, width: width) + 2  // SwiftUI/AppKit seam
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

    /// One paragraph's height at a measure, with the body font's real metrics.
    static func proseHeight(_ text: String, width: CGFloat) -> CGFloat {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = Metrics.proseLineSpacing
        let bounds = NSAttributedString(
            string: text, attributes: [.font: proseFont, .paragraphStyle: paragraph]
        ).boundingRect(
            with: CGSize(width: max(1, width), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        return ceil(bounds.height)
    }

    private static var proseLineHeight: CGFloat { ceil(proseFont.ascender - proseFont.descender) }

    /// Matched to `Typography.notchBody` (Figtree Medium 13). The system face
    /// stands in when the brand font is not registered — a headless test run.
    private static let proseFont: NSFont =
        NSFont(name: "Figtree-Medium", size: 13) ?? .systemFont(ofSize: 13, weight: .medium)
}
