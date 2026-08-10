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

        /// The block's plain text — what the height math measures, and what a
        /// renderer sets when it doesn't care about the kind. A table has no single
        /// string, so it reports its rows joined, which is what its line count is.
        var text: String {
            switch self {
            case .prose(let text), .code(let text), .heading(let text): return text
            case .table(let header, let rows):
                return ([header] + rows).map { $0.joined(separator: "  ") }
                    .joined(separator: "\n")
            }
        }
    }

    var blocks: [Block]

    /// How the expanded band reads a reply: **a headline, words, and data.**
    ///
    /// The opening paragraph is the verdict and is set in display type; the rest
    /// splits by *kind* rather than by order — prose and headings into a reading
    /// column, code and tables into a column beside it, because those are scanned in
    /// columns and shatter when wrapped to a measure. Splitting by kind rather than
    /// interleaving is what lets both columns be measured independently, which is
    /// what the band's height needs.
    struct Split: Equatable, Sendable {
        /// The opening **sentence**, if the reply starts with prose. A reply that
        /// opens with a code fence has no verdict to set, and inventing one from the
        /// fence would put a shell command in display type.
        var headline: String?
        var words: [Block] = []
        var data: [Block] = []
    }

    /// The verdict is one sentence, not the whole opening paragraph.
    ///
    /// A model often answers in a single long paragraph, and setting all of it in
    /// display type either ran off the band or truncated with an ellipsis — the
    /// headline is the one line on this surface that must never be cut, because it
    /// is the thing the design exists to show. So the first sentence leads and the
    /// remainder rejoins the body as ordinary prose.
    static func firstSentence(_ text: String) -> (lead: String, rest: String?) {
        let terminators: Set<Character> = [".", "!", "?"]
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if terminators.contains(character) {
                // A terminator only ends a sentence when whitespace follows it, so
                // "0.6b-v3" and "e.g" stay inside their sentence.
                guard next < text.endIndex else { break }
                if text[next].isWhitespace {
                    let lead = String(text[..<next])
                    let rest = String(text[next...])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    return (lead, rest.isEmpty ? nil : rest)
                }
            }
            index = next
        }
        return (text, nil)
    }

    func split() -> Split {
        var result = Split()
        var rest = blocks[...]
        if case .prose(let first)? = blocks.first {
            let (lead, remainder) = Self.firstSentence(first)
            result.headline = lead
            // The remainder leads the body, so the paragraph still reads in order.
            if let remainder { result.words.append(.prose(remainder)) }
            rest = blocks.dropFirst()
        }
        let remaining = Array(rest)
        for (index, block) in remaining.enumerated() {
            switch block {
            case .prose:
                result.words.append(block)
            case .code, .table:
                result.data.append(block)
            case .heading:
                // **A heading travels with what it heads.** Splitting purely by kind
                // stranded "Toolchain" and "Worktrees" in the words column while the
                // table and the fence they captioned sat in the other one, which
                // reads as three labels with nothing under them.
                let next = remaining[safe: index + 1]
                let headsData: Bool
                switch next {
                case .code, .table: headsData = true
                default: headsData = false
                }
                if headsData {
                    result.data.append(block)
                } else {
                    result.words.append(block)
                }
            }
        }
        return result
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

extension Array {
    /// Bounds-checked lookup, so the split's one-block lookahead reads as a
    /// lookahead rather than as an index dance.
    fileprivate subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
