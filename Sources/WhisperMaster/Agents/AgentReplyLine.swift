import Foundation

/// The one line of a reply that fits on the band.
///
/// Claude writes markdown: fenced code, headings, bullet lists. The finish banner
/// holds a single line, and putting the raw string there produced a title of
/// literally ``` ``` ``` when a reply opened with a code fence — which is what "some
/// weird notch thing" looks like from the outside.
///
/// So this takes the first *prose* line: fenced blocks are dropped whole (code is
/// unreadable at one truncated line anyway; the full reply lives in kunai), and
/// markdown chrome is stripped from what remains. Pure, so it is testable, and
/// deliberately small — it presents, it does not summarise.
enum AgentReplyLine {

    /// The first readable line of `raw`, or nil when there is none (a reply that was
    /// only code). The caller falls back to a plain "Finished".
    static func compact(_ raw: String) -> String? {
        var inFence = false
        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                // The closing fence flips back; an unclosed fence swallows the rest,
                // which is the honest reading of malformed markdown.
                inFence.toggle()
                continue
            }
            if inFence || line.isEmpty { continue }
            let stripped = strippingMarkdownChrome(line)
            if !stripped.isEmpty { return stripped }
        }
        return nil
    }

    /// Remove the markup that reads as noise at one line: heading/quote/bullet
    /// markers at the front, inline code ticks and bold/italic stars throughout.
    /// The *words* are untouched — this is presentation, not paraphrase.
    private static func strippingMarkdownChrome(_ line: String) -> String {
        var text = Substring(line)
        while let first = text.first, "#>-*• ".contains(first) {
            text = text.dropFirst()
        }
        return text
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "**", with: "")
            .trimmingCharacters(in: .whitespaces)
    }
}
