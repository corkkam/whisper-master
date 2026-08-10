import AppKit
import SwiftUI

/// The finished turn, opened out of the notch.
///
/// The composition is editorial, not administrative. A quiet eyebrow names the
/// session; **your question is the card's one piece of display type**, set in the
/// brand's heading face, because it is the thing that gives the answer its meaning
/// and it is the only line on the band that is *yours*; the answer runs beneath it
/// as body copy at a reading measure, directly on the bezel with no container. Only
/// code and tables get a well, because they are the only blocks that are scanned in
/// columns instead of read in lines. When a turn actually ran something, the run
/// moves to a right-hand margin — a sidenote column, so reading still starts with
/// the answer rather than with metadata.
///
/// **The band opens as much as it needs**, the same idiom `NotchSurfaceWidth` uses
/// for every other surface: a prose answer takes the reading width, and only a reply
/// carrying code, a table or a run opens the console width. A two-sentence answer
/// laid out across a thousand points is a slab, however well it is styled.
///
/// **The band's height is decided before this lays out** (the standing rule —
/// `NotchAgentChoiceCard.Metrics` explains the clipped-context-row bug that minted
/// it), so `thickness(...)` measures the same faces at the same measures the body
/// renders at, and the answer scrolls rather than clips once it passes the cap.
struct NotchAgentReplyExpanded: View {
    let document: AgentReplyDocument
    /// What the user asked — the hero line. An answer with no visible question reads
    /// as content from nowhere.
    var prompt: String?
    let repo: String
    var duration: TimeInterval?
    var editedPaths: [String] = []
    /// The turn's tool calls, listed in the margin.
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            eyebrow
                .frame(height: Metrics.eyebrow)
            Rectangle()
                .fill(Theme.Notch.hairline)
                .frame(height: 1)
                .padding(.top, Metrics.eyebrowGap)
            if let prompt, !prompt.isEmpty {
                // Deliberately *not* pinned to the measured height: display type
                // renders a taller line box than `boundingRect` reports, and a frame
                // shorter than the glyphs let the answer start inside the question.
                // The measurement carries slack instead, so the band is a hair
                // roomier than the text rather than a hair shorter.
                question(prompt)
                    .padding(.top, Metrics.questionTopGap)
            }
            HStack(alignment: .top, spacing: 0) {
                answer
                    .frame(width: answerColumnWidth, alignment: .topLeading)
                if hasMargin {
                    Spacer(minLength: 0)
                    margin
                        .frame(width: Metrics.marginWidth, alignment: .leading)
                }
            }
            .frame(height: bodyHeight, alignment: .top)
            .padding(.top, Metrics.answerTopGap)
            foot
                .frame(height: Metrics.foot)
                .padding(.top, Metrics.footGap)
        }
        .padding(.horizontal, Metrics.horizontalPadding)
        .padding(.vertical, Metrics.verticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Reply from \(repo)")
    }

    // MARK: Eyebrow

    /// Session, how long it took, and the two things you can do with the answer. All
    /// of it is chrome, so it is set small and quiet above a rule — the card's
    /// masthead, not its headline.
    private var eyebrow: some View {
        HStack(spacing: 0) {
            Circle()
                .fill(Theme.Notch.success)
                .frame(width: 5, height: 5)
                .padding(.trailing, 8)
            Text(repo.isEmpty ? "agent" : repo)
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.3)
                .foregroundStyle(Theme.Notch.textSecondary)
                .lineLimit(1)
            Text(durationLabel)
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.Notch.textTertiary)
                .padding(.leading, 10)
            Spacer(minLength: Theme.Space.md)
            ghostButton(
                didCopy ? "Copied" : "Copy",
                glyph: didCopy ? "checkmark" : "square.on.square",
                tint: didCopy ? Theme.Notch.success : Theme.Notch.textSecondary
            ) {
                onCopy()
                withAnimation(.easeOut(duration: 0.15)) { didCopy = true }
            }
            if let kunaiURL {
                ghostButton("Open in kunai", glyph: "arrow.up.forward") {
                    openURL(kunaiURL)
                }
                .padding(.leading, Theme.Space.md)
            }
        }
    }

    /// The eyebrow's controls: type and a glyph, no capsule. A filled pill up here
    /// would out-weigh the question, which is the one thing on the card that should
    /// carry weight.
    private func ghostButton(
        _ title: String, glyph: String, tint: Color = Theme.Notch.textSecondary,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: glyph)
                    .font(.system(size: 9, weight: .semibold))
                Text(title)
                    .font(.system(size: 10.5, weight: .semibold))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint)
        .pointerCursor()
        .accessibilityLabel(title)
    }

    private var durationLabel: String {
        guard let duration, duration >= 1 else { return "done" }
        return NotchAgentReplyBanner.compact(duration)
    }

    // MARK: The question — the card's one piece of display type

    /// Your words, in the brand's display face. Ember is *your voice* everywhere in
    /// this app — the listening wave, the dictation rail — so the tick that marks it
    /// wears ember, and everything the machine wrote below is body copy.
    private func question(_ prompt: String) -> some View {
        HStack(alignment: .top, spacing: Metrics.questionTickGap) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Theme.Notch.accent)
                .frame(width: 3)
                .frame(maxHeight: .infinity)
            Text(prompt)
                .font(Typography.heading(Metrics.questionSize, .semibold, relativeTo: .title3))
                .tracking(Typography.trackingFor(Metrics.questionSize))
                .lineSpacing(Metrics.questionLineSpacing)
                .foregroundStyle(Theme.Notch.text)
                .lineLimit(Metrics.questionMaxLines)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: Metrics.maxProseMeasure + Metrics.questionTickGap + 3, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: The answer

    /// The reply, unboxed, on the bezel. The container it used to sit in was the
    /// thing that made a two-sentence answer read as a form field with a lot of
    /// empty space in it.
    @ViewBuilder
    private var answer: some View {
        let measured = Self.contentHeight(for: document, width: answerTextWidth)
        if measured > bodyHeight, !isSnapshot {
            // **Nothing in a reply is unreachable.** Clipping the tail behind a fade
            // was the original defect: the answer stopped mid-sentence with no way
            // to read the rest without leaving for the browser.
            ScrollView(.vertical, showsIndicators: true) { blocks }
        } else {
            blocks.frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private var blocks: some View {
        VStack(alignment: .leading, spacing: Metrics.blockSpacing) {
            ForEach(Array(document.blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .prose(let text):
                    // **Prose gets a measure; data gets the width.** A paragraph run
                    // edge to edge on a card this wide is a line the eye loses its
                    // place on. Code and tables are exempt below.
                    Text(Self.inlineMarkdown(text))
                        .font(Typography.sans(Metrics.answerSize, .regular, relativeTo: .body))
                        .lineSpacing(Metrics.answerLineSpacing)
                        .foregroundStyle(Theme.Notch.text.opacity(0.92))
                        .frame(maxWidth: Metrics.maxProseMeasure, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                case .heading(let text):
                    Text(Self.inlineMarkdown(text))
                        .font(.system(size: 9.5, weight: .bold))
                        .tracking(1.2)
                        .foregroundStyle(Theme.Notch.success)
                        .padding(.top, Metrics.headingTopGap)
                case .code(let text):
                    well { codeLines(text) }
                case .table(let header, let rows):
                    well { table(header: header, rows: rows) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The one container left on the card. Code and tables need an edge because they
    /// are grids; prose does not.
    private func well<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.vertical, Metrics.wellInset)
            .padding(.horizontal, Metrics.wellInset + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Metrics.wellRadius)
                    .fill(Color.white.opacity(0.04)))
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.wellRadius)
                    .strokeBorder(Theme.Notch.hairline, lineWidth: 1))
    }

    /// One `Text` per line, never wrapped: wide output (a worktree list, a table
    /// dump) shatters into soup when wrapped at the card's measure — and a wrapped
    /// line also breaks the height math, which counts source lines. Truncation is
    /// middle, where paths keep both their root and their leaf.
    private func codeLines(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: Metrics.codeLineSpacing) {
            ForEach(
                Array(
                    text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()),
                id: \.offset
            ) { _, line in
                Text(String(line))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.Notch.textSecondary)
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
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.Notch.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        }
    }

    // MARK: The margin — what the turn did

    /// The run as a sidenote column. It only exists when the turn actually called
    /// something: a margin holding nothing but a repeated repo name is what made the
    /// card read as two thirds empty.
    private var margin: some View {
        VStack(alignment: .leading, spacing: Metrics.marginSectionGap) {
            if !visibleTools.isEmpty {
                marginSection("Ran") {
                    ForEach(visibleTools) { tool in
                        toolRow(tool).frame(height: Metrics.toolRow)
                    }
                    if hiddenToolCount > 0 {
                        Text("+\(hiddenToolCount) more")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Theme.Notch.textTertiary)
                            .frame(height: Metrics.toolRow, alignment: .leading)
                    }
                }
            }
            if !visiblePaths.isEmpty {
                marginSection("Changed") {
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
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Theme.Notch.textTertiary)
                            .frame(height: Metrics.pathRow, alignment: .leading)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) {
            // The margin's own edge, run the column's full height, so the sidenotes
            // read as a margin rather than as text that drifted right.
            Rectangle()
                .fill(Theme.Notch.hairline)
                .frame(width: 1)
                .offset(x: -Metrics.marginRuleGap)
        }
    }

    @ViewBuilder
    private func marginSection<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Metrics.marginLabelGap) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(Theme.Notch.textTertiary)
                .frame(height: Metrics.marginLabel, alignment: .leading)
            VStack(alignment: .leading, spacing: 0) { content() }
        }
    }

    /// One tool call: a verdict glyph, then the call in kunai web's own idiom — a
    /// shell command reads as a terminal prompt (the ❯ says "command", so the word
    /// "Bash" is dropped) and every other tool leads with its name.
    private func toolRow(_ tool: AgentTurnLog.ToolLine) -> some View {
        HStack(spacing: 0) {
            Image(systemName: verdictGlyph(tool.verdict))
                .font(.system(size: 8.5, weight: .bold))
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
                    .font(.system(size: 10, weight: .semibold))
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

    /// The detail without the tool's own verb repeated: the headline reads
    /// "Edit  UI/NotchGlow.swift" and the label beside it already says edit.
    private func nonShellDetail(_ tool: AgentTurnLog.ToolLine) -> String {
        guard !tool.detail.isEmpty else { return tool.name }
        let prefix = "\(tool.name)  "
        return tool.detail.hasPrefix(prefix)
            ? String(tool.detail.dropFirst(prefix.count)) : tool.detail
    }

    // MARK: Foot

    /// The way back. The whole card is tappable, but a surface this size has to say
    /// so — a band that fills half the screen with no visible exit reads as stuck.
    private var foot: some View {
        HStack(spacing: 6) {
            Spacer()
            Image(systemName: "chevron.compact.up")
                .font(.system(size: 11, weight: .bold))
            Text("click anywhere, or esc, to close")
                .font(.system(size: 10, weight: .medium))
            Spacer()
        }
        .foregroundStyle(Theme.Notch.textTertiary.opacity(0.7))
        .accessibilityLabel("Collapse this reply")
    }

    // MARK: Derived

    private var visibleTools: [AgentTurnLog.ToolLine] { Array(tools.prefix(Metrics.maxToolRows)) }
    private var hiddenToolCount: Int { max(0, tools.count - Metrics.maxToolRows) }
    private var visiblePaths: [String] { Array(editedPaths.prefix(Metrics.maxPathRows)) }
    private var hiddenPathCount: Int { max(0, editedPaths.count - Metrics.maxPathRows) }

    private var hasMargin: Bool {
        Self.hasMargin(toolCount: tools.count, changedCount: editedPaths.count)
    }
    private var answerColumnWidth: CGFloat {
        Self.answerColumnWidth(surfaceWidth: surfaceWidth, hasMargin: hasMargin)
    }
    private var answerTextWidth: CGFloat { answerColumnWidth }
    private var questionHeight: CGFloat {
        Self.questionHeight(prompt, width: Self.questionMeasure(surfaceWidth: surfaceWidth))
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

    // MARK: The two widths the band opens to

    /// The band opens as much as it needs, which is the same idiom every other notch
    /// surface uses. Prose takes a reading width; only a reply carrying a grid or a
    /// run takes the console.
    enum Layout {
        /// One column of body copy plus its air. Sized so the measure lands on
        /// `Metrics.maxProseMeasure` with the card's padding either side.
        static let readingWidth: CGFloat = 760
        /// Answer plus margin, with grids at full width.
        static let consoleWidth: CGFloat = 1120

        static func wantsConsole(
            document: AgentReplyDocument, toolCount: Int, changedCount: Int
        ) -> Bool {
            document.wantsFullWidth || hasMargin(toolCount: toolCount, changedCount: changedCount)
        }
    }

    // MARK: Measurement (shared with `NotchSurfaceLayout`)

    /// Whether the run earns a margin. Only tool calls and changed files do — a
    /// column holding nothing was a third of the card doing nothing.
    static func hasMargin(toolCount: Int, changedCount: Int) -> Bool {
        toolCount > 0 || changedCount > 0
    }

    /// The column the answer is laid out in. Prose is capped inside it by
    /// `maxProseMeasure`; grids take all of it.
    static func answerColumnWidth(surfaceWidth: CGFloat, hasMargin: Bool) -> CGFloat {
        let content = surfaceWidth - Metrics.horizontalPadding * 2
        return max(240, hasMargin ? content - Metrics.marginWidth - Metrics.marginGap : content)
    }

    /// The measure the question is set at — display type, capped like the prose so
    /// the two columns of text share an edge.
    static func questionMeasure(surfaceWidth: CGFloat) -> CGFloat {
        min(
            Metrics.maxProseMeasure,
            surfaceWidth - Metrics.horizontalPadding * 2 - Metrics.questionTickGap - 3)
    }

    /// How tall the question block comes out, display face and all — with a line of
    /// slack, because SwiftUI sets display type on a taller line box than
    /// `boundingRect` reports and this number decides the band's height.
    static func questionHeight(_ prompt: String?, width: CGFloat) -> CGFloat {
        guard let prompt, !prompt.isEmpty else { return 0 }
        let line = ceil(questionFont.ascender - questionFont.descender + questionFont.leading)
            + Metrics.questionLineSpacing
        let measured = height(
            prompt, font: questionFont, width: width, lineSpacing: Metrics.questionLineSpacing)
        let lines = min(CGFloat(Metrics.questionMaxLines), max(1, ceil(measured / line)))
        return lines * line + Metrics.questionSlack
    }

    /// The question block plus the air around it — what the height math reserves.
    private static func questionReserve(_ prompt: String?, surfaceWidth: CGFloat) -> CGFloat {
        let block = questionHeight(prompt, width: questionMeasure(surfaceWidth: surfaceWidth))
        return block > 0 ? block + Metrics.questionTopGap : 0
    }

    /// The tallest the body is allowed to be before the answer scrolls.
    static func bodyCap(for geometry: NotchGeometry) -> CGFloat {
        guard geometry.screenHeight > 0 else { return Metrics.fallbackBodyHeight }
        return max(
            Metrics.fallbackBodyHeight,
            (geometry.screenHeight - geometry.notchHeight) * Metrics.screenFraction)
    }

    /// The height the body actually takes: the taller of the answer and the margin,
    /// capped, and with the question's own block already paid for. A short answer
    /// keeps a short band.
    static func bodyHeight(
        document: AgentReplyDocument, prompt: String?, toolCount: Int, changedCount: Int,
        surfaceWidth: CGFloat, geometry: NotchGeometry
    ) -> CGFloat {
        let margined = hasMargin(toolCount: toolCount, changedCount: changedCount)
        let answer = contentHeight(
            for: document,
            width: answerColumnWidth(surfaceWidth: surfaceWidth, hasMargin: margined))
        let margin = marginHeight(toolCount: toolCount, changedCount: changedCount)
        let available = bodyCap(for: geometry)
            - questionReserve(prompt, surfaceWidth: surfaceWidth)
        return min(available, max(answer, margin))
    }

    /// How tall the sidenote column comes out.
    static func marginHeight(toolCount: Int, changedCount: Int) -> CGFloat {
        var sections: [CGFloat] = []
        if toolCount > 0 {
            let rows = min(toolCount, Metrics.maxToolRows)
                + (toolCount > Metrics.maxToolRows ? 1 : 0)
            sections.append(
                Metrics.marginLabel + Metrics.marginLabelGap + CGFloat(rows) * Metrics.toolRow)
        }
        if changedCount > 0 {
            let rows = min(changedCount, Metrics.maxPathRows)
                + (changedCount > Metrics.maxPathRows ? 1 : 0)
            sections.append(
                Metrics.marginLabel + Metrics.marginLabelGap + CGFloat(rows) * Metrics.pathRow)
        }
        guard !sections.isEmpty else { return 0 }
        return sections.reduce(0, +) + CGFloat(sections.count - 1) * Metrics.marginSectionGap
    }

    /// The band thickness for a reply, measured with the same faces at the same
    /// measures the body renders at.
    static func thickness(
        for document: AgentReplyDocument, prompt: String?, toolCount: Int,
        changedCount: Int, surfaceWidth: CGFloat, geometry: NotchGeometry
    ) -> CGFloat {
        chrome + questionReserve(prompt, surfaceWidth: surfaceWidth)
            + bodyHeight(
                document: document, prompt: prompt, toolCount: toolCount,
                changedCount: changedCount, surfaceWidth: surfaceWidth, geometry: geometry)
    }

    /// Everything that is not the question or the body: padding, the eyebrow, its
    /// rule, and the foot.
    private static var chrome: CGFloat {
        Metrics.verticalPadding * 2 + Metrics.eyebrow + Metrics.eyebrowGap + 1
            + Metrics.answerTopGap + Metrics.footGap + Metrics.foot
    }

    /// The tallest the band can be, for `NotchSurfaceLayout.panelSize`.
    static func maxThickness(for geometry: NotchGeometry) -> CGFloat {
        chrome + bodyCap(for: geometry)
    }

    /// Measured content height. Prose is measured with the body face at the measure
    /// it renders at; code is a line count times a fixed mono line height, since it
    /// does not wrap.
    static func contentHeight(for document: AgentReplyDocument, width: CGFloat) -> CGFloat {
        var total: CGFloat = 0
        for block in document.blocks {
            switch block {
            case .prose(let text):
                total += height(
                    text, font: answerFont, width: min(width, Metrics.maxProseMeasure),
                    lineSpacing: Metrics.answerLineSpacing) + 2  // SwiftUI/AppKit seam
            case .heading:
                total += Metrics.headingHeight + Metrics.headingTopGap
            case .code(let text):
                let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
                total += CGFloat(lines) * Metrics.codeLineHeight + Metrics.wellInset * 2
            case .table(let header, let rows):
                total += (header.isEmpty ? 0 : Metrics.tableHeaderHeight)
                    + CGFloat(rows.count) * Metrics.tableRowHeight + Metrics.wellInset * 2
            }
        }
        return total + CGFloat(max(0, document.blocks.count - 1)) * Metrics.blockSpacing
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
    private static let answerFont: NSFont =
        NSFont(name: BrandFont.body, size: Metrics.answerSize)
        ?? .systemFont(ofSize: Metrics.answerSize)
    private static let questionFont: NSFont =
        NSFont(name: BrandFont.heading, size: Metrics.questionSize)
        ?? .systemFont(ofSize: Metrics.questionSize, weight: .semibold)

    // MARK: Metrics

    enum Metrics {
        static let horizontalPadding: CGFloat = 30
        static let verticalPadding: CGFloat = 20

        /// The masthead row and the air under it, before the rule.
        static let eyebrow: CGFloat = 16
        static let eyebrowGap: CGFloat = 13

        /// The question: the card's one piece of display type.
        static let questionSize: CGFloat = 17
        static let questionLineSpacing: CGFloat = 3
        static let questionMaxLines = 3
        static let questionTickGap: CGFloat = 11
        static let questionTopGap: CGFloat = 18
        /// Headroom on the measured question, covering the difference between
        /// `boundingRect` and SwiftUI's own line box for display type.
        static let questionSlack: CGFloat = 6

        /// The answer.
        static let answerSize: CGFloat = 14
        static let answerLineSpacing: CGFloat = 5
        static let answerTopGap: CGFloat = 16
        static let blockSpacing: CGFloat = 11
        /// The longest line of prose the card sets. Grids are exempt — they are
        /// scanned in columns, and wrapping them to a measure shatters them.
        static let maxProseMeasure: CGFloat = 660
        static let headingTopGap: CGFloat = 9
        static let headingHeight: CGFloat = 14

        /// Code and table wells.
        static let wellInset: CGFloat = 11
        static let wellRadius: CGFloat = 10
        static let codeLineHeight: CGFloat = 16
        static let codeLineSpacing: CGFloat = 2.5
        static let tableRowHeight: CGFloat = 19
        static let tableHeaderHeight: CGFloat = 24

        /// The sidenote column.
        static let marginWidth: CGFloat = 240
        static let marginGap: CGFloat = 40
        /// Where the margin's rule sits inside that gap — nearer the sidenotes than
        /// the answer, so it reads as their edge.
        static let marginRuleGap: CGFloat = 18
        static let marginSectionGap: CGFloat = 18
        static let marginLabel: CGFloat = 12
        static let marginLabelGap: CGFloat = 8
        static let toolGlyphColumn: CGFloat = 15
        static let toolRow: CGFloat = 20
        static let maxToolRows = 8
        static let pathRow: CGFloat = 17
        static let maxPathRows = 6

        /// The foot.
        static let foot: CGFloat = 13
        static let footGap: CGFloat = 16

        /// Share of the display the card may occupy before the answer scrolls.
        static let screenFraction: CGFloat = 0.62
        /// Floor for the body, used when the screen is unknown (the headless
        /// renderer) and as the minimum on any display.
        static let fallbackBodyHeight: CGFloat = 300
    }
}
