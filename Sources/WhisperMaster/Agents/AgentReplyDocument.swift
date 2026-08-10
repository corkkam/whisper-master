import Foundation

/// A reply broken into the blocks the expanded band renders: prose and fenced code.
///
/// This exists because "show the full reply" cannot mean "dump the raw markdown on
/// the band" — that is how a title of literally ``` happened. The expanded view
/// renders prose as prose and code as code, and to do that the string has to be
/// split once, in a pure, testable place.
///
/// It deliberately does *not* try to be a markdown engine. Headings and quote
/// markers are stripped (at band size they are noise), inline emphasis is left for
/// the renderer's own markdown pass, and everything else is words.
struct AgentReplyDocument: Equatable, Sendable {

    enum Block: Equatable, Sendable {
        /// Running text. Inline markdown (`code`, **bold**) is left in place for the
        /// renderer; line breaks within a paragraph are preserved.
        case prose(String)
        /// A fenced block, fences and language tag removed.
        case code(String)
    }

    var blocks: [Block]

    static func parse(_ raw: String) -> AgentReplyDocument {
        var blocks: [Block] = []
        var proseLines: [String] = []
        var codeLines: [String] = []
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

        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inFence { flushCode() } else { flushProse() }
                inFence.toggle()
                continue
            }
            if inFence {
                codeLines.append(line)
            } else {
                proseLines.append(Self.strippingBlockChrome(line))
            }
        }
        // An unclosed fence still shows its code — the honest reading of
        // malformed markdown.
        if inFence { flushCode() } else { flushProse() }
        return AgentReplyDocument(blocks: blocks)
    }

    /// Drop the block-level markers that read as noise at band size: heading hashes
    /// and quote arrows. List dashes are kept — a list is content.
    private static func strippingBlockChrome(_ line: String) -> String {
        var text = Substring(line)
        let leadingWhitespace = text.prefix(while: { $0 == " " })
        text = text.drop(while: { $0 == " " })
        while text.first == "#" || text.first == ">" {
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
