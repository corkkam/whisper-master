import Foundation

/// A reply broken into the blocks the expanded band renders.
///
/// This exists because "show the full reply" cannot mean "dump the raw markdown on
/// the band". Real replies use the whole vocabulary — fenced code, headings, and
/// **tables**, which as raw text render as the `| tool | path | |---|---|` pipe
/// garbage that kept getting reported. The band can only look designed if the
/// blocks Claude actually writes are parsed into things a view can lay out.
///
/// Still deliberately not a markdown engine: four block shapes cover what replies
/// use, inline emphasis is left for the renderer's own markdown pass, and anything
/// unrecognised is words.
struct AgentReplyDocument: Equatable, Sendable {

    enum Block: Equatable, Sendable {
        /// Running text. Inline markdown (`code`, **bold**) is left in place for the
        /// renderer; line breaks within a paragraph are preserved.
        case prose(String)
        /// A fenced block, fences and language tag removed.
        case code(String)
        /// A `#`-prefixed line: a real heading, not just a bold word mid-paragraph.
        case heading(String)
        /// A pipe table: header cells, then body rows. The separator row is layout
        /// instruction, not content, and is consumed by the parser.
        case table(header: [String], rows: [[String]])
    }

    var blocks: [Block]

    /// Whether the reply carries something that is *scanned in columns* rather than
    /// read in lines — a fenced block or a table. Those are the only blocks that
    /// want the whole display; prose does not, and a two-sentence answer laid out
    /// at console width was the "why is it a slab" complaint. This is what decides
    /// whether the band opens to a reading measure or all the way out.
    var wantsFullWidth: Bool {
        blocks.contains {
            if case .prose = $0 { return false }
            if case .heading = $0 { return false }
            return true
        }
    }

    static func parse(_ raw: String) -> AgentReplyDocument {
        var blocks: [Block] = []
        var proseLines: [String] = []
        var codeLines: [String] = []
        var tableLines: [String] = []
        var inFence = false

        func flushProse() {
            let text = proseLines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(.prose(text)) }
            proseLines = []
        }
        func flushCode() {
            let text = codeLines.joined(separator: "\n")
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks.append(.code(text))
            }
            codeLines = []
        }
        func flushTable() {
            guard !tableLines.isEmpty else { return }
            if let table = parseTable(tableLines) { blocks.append(table) }
            tableLines = []
        }

        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if inFence { flushCode() } else { flushProse(); flushTable() }
                inFence.toggle()
                continue
            }
            if inFence {
                codeLines.append(line)
                continue
            }
            if trimmed.hasPrefix("|"), trimmed.dropFirst().contains("|") {
                flushProse()
                tableLines.append(trimmed)
                continue
            }
            flushTable()
            if trimmed.hasPrefix("#") {
                flushProse()
                let text = trimmed.drop(while: { $0 == "#" })
                    .trimmingCharacters(in: .whitespaces)
                if !text.isEmpty { blocks.append(.heading(text)) }
                continue
            }
            proseLines.append(Self.strippingBlockChrome(line))
        }
        // An unclosed fence still shows its code — the honest reading of
        // malformed markdown.
        if inFence { flushCode() } else { flushProse(); flushTable() }
        return AgentReplyDocument(blocks: blocks)
    }

    /// Cells of one pipe row, outer pipes shed.
    private static func cells(of line: String) -> [String] {
        var body = Substring(line)
        if body.hasPrefix("|") { body = body.dropFirst() }
        if body.hasSuffix("|") { body = body.dropLast() }
        return body.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// A run of pipe lines becomes a table; the `|---|---|` separator marks the
    /// line above it as the header and is itself consumed.
    private static func parseTable(_ lines: [String]) -> Block? {
        guard !lines.isEmpty else { return nil }
        var header: [String] = []
        var rows: [[String]] = []
        for (index, line) in lines.enumerated() {
            let lineCells = cells(of: line)
            let isSeparator = lineCells.allSatisfy { cell in
                !cell.isEmpty && cell.allSatisfy { "-: ".contains($0) }
            }
            if isSeparator, index == 1, header.isEmpty, let first = rows.first {
                header = first
                rows.removeFirst()
                continue
            }
            if isSeparator { continue }
            rows.append(lineCells)
        }
        guard !rows.isEmpty || !header.isEmpty else { return nil }
        return .table(header: header, rows: rows)
    }

    /// Drop the block-level markers that read as noise at band size: quote arrows.
    /// (Headings are their own block now; list dashes are kept — a list is content.)
    private static func strippingBlockChrome(_ line: String) -> String {
        var text = Substring(line)
        let leadingWhitespace = text.prefix(while: { $0 == " " })
        text = text.drop(while: { $0 == " " })
        while text.first == ">" {
            text = text.dropFirst()
            text = text.drop(while: { $0 == " " })
        }
        return String(leadingWhitespace + text)
    }

    /// Line counts per block, which is what the height estimate needs for code
    /// (mono, unwrapped) without measuring anything.
    var codeLineCount: Int {
        blocks.reduce(0) { total, block in
            guard case .code(let text) = block else { return total }
            return total + text.split(separator: "\n", omittingEmptySubsequences: false).count
        }
    }

    var isEmpty: Bool { blocks.isEmpty }
}
