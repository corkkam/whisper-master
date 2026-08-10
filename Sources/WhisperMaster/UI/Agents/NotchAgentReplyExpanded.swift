import AppKit
import SwiftUI

/// The finished turn, opened out of the notch.
///
/// **The answer is the headline.** Every earlier version of this surface made the
/// question the largest thing on the band and hung the reply underneath it, which is
/// backwards: you already know what you asked, and what you came back for is what
/// happened. So the reply's opening paragraph is set in display type as the verdict,
/// the question shrinks to one ember line above it, and everything else — the
/// supporting detail, the command output, the run — falls away underneath at
/// supporting size.
///
/// Below the headline the blocks split by kind rather than by source: **words on the
/// left, data on the right.** Prose and headings stack in a reading column; code and
/// tables stack beside it, where being scanned in columns is what they want. Either
/// side takes the full measure when the other is empty, so an all-prose answer and a
/// wall of test output both lay out correctly.
///
/// **The band opens as much as it needs** — the same idiom `NotchSurfaceWidth` gives
/// every other surface. A prose-only reply takes the reading width; only one carrying
/// a grid opens the console.
///
/// **The band's height is decided before this lays out** (the standing rule —
/// `NotchAgentChoiceCard.Metrics` explains the clipped-context-row bug that minted
/// it), so `thickness(...)` measures the same faces at the same measures the body
/// renders at, and each column scrolls rather than clips once it passes the cap.
struct NotchAgentReplyExpanded: View {
    let document: AgentReplyDocument
    /// What the user asked. One line, above the verdict.
    var prompt: String?
    let repo: String
    var duration: TimeInterval?
    var editedPaths: [String] = []
    /// The turn's tool calls, reduced to one index line at the foot.
    var tools: [AgentTurnLog.ToolLine] = []
    /// The full width of the black surface. Every column is derived from it, and the
    /// height is measured from the same derivation — measuring at one width while
    /// rendering at another is what produced the skinny over-wrapped tower.
    var surfaceWidth: CGFloat = Layout.readingWidth
    /// This session's page in kunai's web app.
    var kunaiURL: URL?
    /// The display this is drawn on. A reply is a document, so the card sizes itself
    /// against the screen rather than a constant.
    var geometry: NotchGeometry = .none
    /// Puts the whole answer on the clipboard. Injected so the view stays free of the
    /// pasteboard, the same shape the undelivered hint's Copy uses.
    var onCopy: () -> Void = {}

    /// Latched for a beat after a copy, so the button reports what it did. Local
    /// because it is presentation, not app state.
    @State private var didCopy = false
    @Environment(\.openURL) private var openURL
    /// `ImageRenderer` collapses a flexible `ScrollView` to nothing, so the headless
    /// renderer gets the plain stack. Same gate the other AppKit-backed surfaces use.
    @Environment(\.isSnapshot) private var isSnapshot

    private var split: AgentReplyDocument.Split { document.split() }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            eyebrow
                .frame(height: Metrics.eyebrow)
            if let headline = split.headline {
                verdict(headline)
                    .padding(.top, Metrics.headlineTopGap)
            }
            columns
                .frame(height: bodyHeight, alignment: .top)
                .padding(.top, Metrics.bodyTopGap)
            foot
                .frame(height: Metrics.foot)
                .padding(.top, Metrics.footGap)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Theme.Notch.hairline)
                        .frame(height: 1)
                        .offset(y: -Metrics.footGap / 2)
                }
        }
        .padding(.horizontal, Metrics.horizontalPadding)
        .padding(.top, Metrics.topPadding)
        .padding(.bottom, Metrics.bottomPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Reply from \(repo)")
    }

    // MARK: The line above

    /// Your question, and where the turn ran. Both are context for the verdict, so
    /// both are small — but the question wears ember, because it is the one line on
    /// the band that is yours.
    private var eyebrow: some View {
        HStack(spacing: 9) {
            Image(systemName: "mic.fill")
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(Theme.Notch.accent)
            Text(prompt ?? "")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Theme.Notch.accent)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 20)
            Text(context)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Theme.Notch.textTertiary)
                .lineLimit(1)
        }
    }

    /// "whisper-master · 3m 12s · 1 file changed" — the turn's provenance in one
    /// line, so nothing further down has to spend a row on it.
    private var context: String {
        var parts: [String] = []
        if !repo.isEmpty { parts.append(repo) }
        if let duration, duration >= 1 { parts.append(NotchAgentReplyBanner.compact(duration)) }
        if !editedPaths.isEmpty {
            parts.append(
                editedPaths.count == 1 ? "1 file changed" : "\(editedPaths.count) files changed")
        }
        return parts.joined(separator: "  ·  ")
    }

    // MARK: The verdict

    /// The reply's opening paragraph, in display type. This is the whole idea of the
    /// surface: what happened, at a size you read from across the room.
    private func verdict(_ text: String) -> some View {
        Text(Self.inlineMarkdown(text))
            .font(Typography.heading(Metrics.verdictSize, .semibold, relativeTo: .title))
            .tracking(Typography.trackingFor(Metrics.verdictSize))
            .lineSpacing(Metrics.verdictLineSpacing)
            .foregroundStyle(Theme.Notch.text)
            .lineLimit(Metrics.verdictMaxLines)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: Self.verdictMeasure(surfaceWidth: surfaceWidth), alignment: .leading)
    }

    // MARK: Words on the left, data on the right

    private var columns: some View {
        HStack(alignment: .top, spacing: Metrics.columnGap) {
            if !split.words.isEmpty {
                scrolling(height: wordsHeight) {
                    VStack(alignment: .leading, spacing: Metrics.blockSpacing) {
                        ForEach(Array(split.words.enumerated()), id: \.offset) { _, block in
                            switch block {
                            case .heading(let text):
                                Text(Self.inlineMarkdown(text))
                                    .font(.system(size: 9.5, weight: .bold))
                                    .tracking(1.4)
                                    .foregroundStyle(Theme.Notch.output)
                                    .padding(.top, Metrics.headingTopGap)
                            default:
                                Text(Self.inlineMarkdown(block.text))
                                    .font(Typography.sans(Metrics.proseSize, .regular, relativeTo: .body))
                                    .lineSpacing(Metrics.proseLineSpacing)
                                    .foregroundStyle(Theme.Notch.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .frame(width: wordsWidth, alignment: .leading)
                }
                .frame(width: wordsWidth, alignment: .topLeading)
            }
            if !split.data.isEmpty {
                scrolling(height: dataHeight) {
                    VStack(alignment: .leading, spacing: Metrics.blockSpacing) {
                        ForEach(Array(split.data.enumerated()), id: \.offset) { _, block in
                            switch block {
                            case .table(let header, let rows):
                                table(header: header, rows: rows)
                            default:
                                codeLines(block.text)
                            }
                        }
                    }
                    .frame(width: dataWidth, alignment: .leading)
                }
                .frame(width: dataWidth, alignment: .topLeading)
            }
            Spacer(minLength: 0)
        }
    }

    /// A column scrolls only when its own content outgrows the band. **Nothing in a
    /// reply is unreachable** — clipping the tail behind a fade was the original
    /// defect of this surface.
    @ViewBuilder
    private func scrolling<Content: View>(
        height: CGFloat, @ViewBuilder _ content: () -> Content
    ) -> some View {
        if height > bodyHeight, !isSnapshot {
            ScrollView(.vertical, showsIndicators: true) { content() }
        } else {
            // Clipped even in the headless render: a snapshot that lets an
            // over-long column draw straight through the foot rule hides exactly
            // the overflow the render exists to catch.
            content()
                .frame(height: bodyHeight, alignment: .top)
                .clipped()
        }
    }

    /// One `Text` per line, never wrapped: command output shatters into soup when
    /// wrapped at a card measure — and a wrapped line also breaks the height math,
    /// which counts source lines. Truncation is middle, where paths keep both their
    /// root and their leaf.
    private func codeLines(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: Metrics.codeLineSpacing) {
            ForEach(
                Array(text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()),
                id: \.offset
            ) { _, line in
                Text(String(line))
                    .font(.system(size: Metrics.codeSize, design: .monospaced))
                    .foregroundStyle(Theme.Notch.output)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    /// A pipe table as a real grid. This is what was rendering as literal
    /// `| tool | path |` pipes.
    private func table(header: [String], rows: [[String]]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: Theme.Space.xl, verticalSpacing: 5) {
            if !header.isEmpty {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                        Text(cell.uppercased())
                            .font(.system(size: 9, weight: .bold))
                            .tracking(1)
                            .foregroundStyle(Theme.Notch.textTertiary)
                    }
                }
                Divider().overlay(Theme.Notch.hairline)
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        Text(Self.inlineMarkdown(cell))
                            .font(.system(size: Metrics.codeSize, design: .monospaced))
                            .foregroundStyle(Theme.Notch.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        }
    }

    // MARK: The foot

    /// The run reduced to one index line, and the three things you can do. A turn's
    /// tool calls are worth being able to check and not worth a column, so they are
    /// set small and dim and allowed to run out of room.
    private var foot: some View {
        HStack(spacing: 0) {
            Text(Self.runIndex(tools))
                .foregroundStyle(Theme.Notch.textTertiary.opacity(0.8))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 24)
            footAction(didCopy ? "copied" : "copy", tint: didCopy ? Theme.Notch.output : nil) {
                onCopy()
                withAnimation(.easeOut(duration: 0.15)) { didCopy = true }
            }
            if let kunaiURL {
                footAction("kunai") { openURL(kunaiURL) }
                    .padding(.leading, 18)
            }
            Text("esc")
                .foregroundStyle(Theme.Notch.textTertiary.opacity(0.55))
                .padding(.leading, 18)
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .foregroundStyle(Theme.Notch.textTertiary.opacity(0.8))
    }

    private func footAction(
        _ title: String, tint: Color? = nil, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint ?? Theme.Notch.textSecondary)
        .pointerCursor()
        .accessibilityLabel(title)
    }

    /// The commands, joined — trimmed the same way the working row trims them, so a
    /// compound shell line doesn't spend the whole index.
    static func runIndex(_ tools: [AgentTurnLog.ToolLine]) -> String {
        tools
            .map { tool -> String in
                let detail = tool.detail.hasPrefix("Run  ")
                    ? String(tool.detail.dropFirst(5)) : tool.detail
                let trimmed = AgentTurnLog.trimmedCommand(detail)
                return trimmed.isEmpty ? tool.name.lowercased() : trimmed
            }
            .joined(separator: "  ·  ")
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

    // MARK: Derived widths and heights

    private var wordsWidth: CGFloat {
        Self.wordsWidth(surfaceWidth: surfaceWidth, hasData: !split.data.isEmpty,
                        hasWords: !split.words.isEmpty)
    }
    private var dataWidth: CGFloat {
        Self.dataWidth(surfaceWidth: surfaceWidth, hasData: !split.data.isEmpty,
                       hasWords: !split.words.isEmpty)
    }
    private var wordsHeight: CGFloat { Self.wordsHeight(split.words, width: wordsWidth) }
    private var dataHeight: CGFloat { Self.dataHeight(split.data) }
    private var bodyHeight: CGFloat {
        Self.bodyHeight(document: document, surfaceWidth: surfaceWidth, geometry: geometry)
    }

    // MARK: The two widths the band opens to

    /// The band opens as much as it needs. Prose takes a reading width; only a reply
    /// carrying a grid — command output, a table — takes the console.
    enum Layout {
        /// Verdict plus one reading column, and nothing wider.
        static let readingWidth: CGFloat = 860
        /// Words beside data.
        static let consoleWidth: CGFloat = 1120

        static func wantsConsole(
            document: AgentReplyDocument, toolCount: Int, changedCount: Int
        ) -> Bool {
            !document.split().data.isEmpty
        }
    }

    // MARK: Measurement (shared with `NotchSurfaceLayout`)

    private static func contentWidth(_ surfaceWidth: CGFloat) -> CGFloat {
        max(280, surfaceWidth - Metrics.horizontalPadding * 2)
    }

    /// The measure the verdict is set at. Display type at 27pt wants a shorter line
    /// than body copy does, so it is capped well inside the card.
    static func verdictMeasure(surfaceWidth: CGFloat) -> CGFloat {
        min(Metrics.maxVerdictMeasure, contentWidth(surfaceWidth))
    }

    static func wordsWidth(surfaceWidth: CGFloat, hasData: Bool, hasWords: Bool) -> CGFloat {
        let content = contentWidth(surfaceWidth)
        guard hasData else { return min(Metrics.maxProseMeasure, content) }
        return min(Metrics.maxProseMeasure, (content - Metrics.columnGap) * Metrics.wordsShare)
    }

    static func dataWidth(surfaceWidth: CGFloat, hasData: Bool, hasWords: Bool) -> CGFloat {
        let content = contentWidth(surfaceWidth)
        guard hasWords else { return content }
        return content - Metrics.columnGap
            - wordsWidth(surfaceWidth: surfaceWidth, hasData: hasData, hasWords: hasWords)
    }

    /// The tallest the body is allowed to be before a column scrolls.
    static func bodyCap(for geometry: NotchGeometry) -> CGFloat {
        guard geometry.screenHeight > 0 else { return Metrics.fallbackBodyHeight }
        return max(
            Metrics.fallbackBodyHeight,
            (geometry.screenHeight - geometry.notchHeight) * Metrics.screenFraction)
    }

    static func wordsHeight(_ blocks: [AgentReplyDocument.Block], width: CGFloat) -> CGFloat {
        guard !blocks.isEmpty else { return 0 }
        var total: CGFloat = 0
        for block in blocks {
            if case .heading = block {
                total += Metrics.headingHeight + Metrics.headingTopGap
            } else {
                // Measured at a slightly narrower measure than it renders at.
                // `boundingRect` sees one plain regular face, but the renderer sets
                // inline markdown — **bold** runs and `code` runs in a mono face,
                // both wider — so a straight measurement under-reports the line
                // count and the column scrolls when it did not need to.
                total += ceil(
                    height(
                        block.text, font: proseFont, width: width * Metrics.proseMeasureSlack,
                        lineSpacing: Metrics.proseLineSpacing) * Metrics.proseHeightSlack)
            }
        }
        return total + CGFloat(blocks.count - 1) * Metrics.blockSpacing
    }

    static func dataHeight(_ blocks: [AgentReplyDocument.Block]) -> CGFloat {
        guard !blocks.isEmpty else { return 0 }
        var total: CGFloat = 0
        for block in blocks {
            switch block {
            case .table(let header, let rows):
                total += (header.isEmpty ? 0 : Metrics.tableHeaderHeight)
                    + CGFloat(rows.count) * Metrics.tableRowHeight
            default:
                let lines = block.text
                    .split(separator: "\n", omittingEmptySubsequences: false).count
                total += CGFloat(lines) * Metrics.codeLineHeight
            }
        }
        return total + CGFloat(blocks.count - 1) * Metrics.blockSpacing
    }

    /// How tall the verdict comes out — with a line of slack, because SwiftUI sets
    /// display type on a taller line box than `boundingRect` reports and this number
    /// decides the band's height.
    static func verdictHeight(_ text: String?, surfaceWidth: CGFloat) -> CGFloat {
        guard let text, !text.isEmpty else { return 0 }
        let line = ceil(verdictFont.ascender - verdictFont.descender + verdictFont.leading)
            + Metrics.verdictLineSpacing
        let measured = height(
            text, font: verdictFont, width: verdictMeasure(surfaceWidth: surfaceWidth),
            lineSpacing: Metrics.verdictLineSpacing)
        let lines = min(CGFloat(Metrics.verdictMaxLines), max(1, ceil(measured / line)))
        return lines * line + Metrics.verdictSlack
    }

    /// The verdict block plus the air above it — what the height math reserves.
    private static func verdictReserve(
        _ document: AgentReplyDocument, surfaceWidth: CGFloat
    ) -> CGFloat {
        let block = verdictHeight(document.split().headline, surfaceWidth: surfaceWidth)
        return block > 0 ? block + Metrics.headlineTopGap : 0
    }

    /// The height the two columns take: the taller of them, capped, with the verdict
    /// already paid for. A one-line answer still gets a one-line band.
    static func bodyHeight(
        document: AgentReplyDocument, surfaceWidth: CGFloat, geometry: NotchGeometry
    ) -> CGFloat {
        let split = document.split()
        let words = wordsHeight(
            split.words,
            width: wordsWidth(
                surfaceWidth: surfaceWidth, hasData: !split.data.isEmpty,
                hasWords: !split.words.isEmpty))
        let available = bodyCap(for: geometry)
            - verdictReserve(document, surfaceWidth: surfaceWidth)
        return min(available, max(words, dataHeight(split.data)))
    }

    /// The band thickness for a reply, measured with the same faces at the same
    /// measures the body renders at.
    static func thickness(
        for document: AgentReplyDocument, prompt: String?, toolCount: Int,
        changedCount: Int, surfaceWidth: CGFloat, geometry: NotchGeometry
    ) -> CGFloat {
        chrome + verdictReserve(document, surfaceWidth: surfaceWidth)
            + bodyHeight(document: document, surfaceWidth: surfaceWidth, geometry: geometry)
    }

    /// Everything that is not the verdict or the columns.
    private static var chrome: CGFloat {
        Metrics.topPadding + Metrics.bottomPadding + Metrics.eyebrow + Metrics.bodyTopGap
            + Metrics.footGap + Metrics.foot
    }

    /// The tallest the band can be, for `NotchSurfaceLayout.panelSize`.
    static func maxThickness(for geometry: NotchGeometry) -> CGFloat {
        chrome + bodyCap(for: geometry)
    }

    /// One run of text's height at a measure, with a real font's metrics.
    private static func height(
        _ text: String, font: NSFont, width: CGFloat, lineSpacing: CGFloat
    ) -> CGFloat {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        let bounds = NSAttributedString(
            string: text, attributes: [.font: font, .paragraphStyle: paragraph]
        ).boundingRect(
            with: CGSize(width: max(1, width), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        return ceil(bounds.height)
    }

    /// The measuring faces, resolved from the brand families rather than from a
    /// hard-coded PostScript name — the families have been swapped once already, and
    /// a stale name here silently measures the system face while rendering another.
    private static let proseFont: NSFont =
        NSFont(name: BrandFont.body, size: Metrics.proseSize)
        ?? .systemFont(ofSize: Metrics.proseSize)
    private static let verdictFont: NSFont =
        NSFont(name: BrandFont.heading, size: Metrics.verdictSize)
        ?? .systemFont(ofSize: Metrics.verdictSize, weight: .semibold)

    // MARK: Metrics

    enum Metrics {
        static let horizontalPadding: CGFloat = 40
        static let topPadding: CGFloat = 30
        static let bottomPadding: CGFloat = 22

        static let eyebrow: CGFloat = 16

        /// The verdict — the card's one piece of display type.
        static let verdictSize: CGFloat = 21
        static let verdictLineSpacing: CGFloat = 4
        static let verdictMaxLines = 4
        static let headlineTopGap: CGFloat = 18
        static let maxVerdictMeasure: CGFloat = 720
        /// Headroom on the measured verdict, covering the difference between
        /// `boundingRect` and SwiftUI's own line box for display type.
        static let verdictSlack: CGFloat = 8

        /// The two columns under it.
        static let bodyTopGap: CGFloat = 26
        static let columnGap: CGFloat = 44
        /// Share of the body the words take when there is data beside them.
        static let wordsShare: CGFloat = 0.52
        static let maxProseMeasure: CGFloat = 470
        static let proseSize: CGFloat = 13
        static let proseLineSpacing: CGFloat = 6
        /// How much narrower prose is measured than it is set — headroom for the
        /// bold and monospaced inline runs the measurement cannot see.
        static let proseMeasureSlack: CGFloat = 0.94
        /// And a little taller than `boundingRect` reports: SwiftUI sets a slightly
        /// looser line box than the `NSFont` metrics give. Under-measuring here is
        /// the one error that shows — the column clips a sentence in half.
        static let proseHeightSlack: CGFloat = 1.14
        static let blockSpacing: CGFloat = 12
        static let headingTopGap: CGFloat = 8
        static let headingHeight: CGFloat = 14

        static let codeSize: CGFloat = 10.5
        static let codeLineHeight: CGFloat = 18
        static let codeLineSpacing: CGFloat = 3
        static let tableRowHeight: CGFloat = 20
        static let tableHeaderHeight: CGFloat = 24

        static let foot: CGFloat = 13
        static let footGap: CGFloat = 18

        /// Share of the display the columns may occupy before they scroll.
        static let screenFraction: CGFloat = 0.55
        /// Floor for the body, used when the screen is unknown (the headless
        /// renderer) and as the minimum on any display.
        static let fallbackBodyHeight: CGFloat = 240
    }
}
