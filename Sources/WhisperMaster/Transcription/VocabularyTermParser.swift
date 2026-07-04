import FluidAudio
import Foundation

/// Parses "Words to get right" glossary lines into FluidAudio vocabulary terms.
///
/// Each line is either a bare term ("Parakeet") or FluidAudio's alias
/// convention — "canonical: mishearing1, mishearing2". Aliases teach the
/// rescorer what the engine tends to hear instead; the transcript always
/// shows the canonical form.
enum VocabularyTermParser {
    /// A parsed glossary line, independent of FluidAudio types so state code
    /// can use it without importing the engine.
    struct ParsedLine: Equatable {
        let text: String
        let aliases: [String]
    }

    static func terms(from lines: [String]) -> [CustomVocabularyTerm] {
        lines.compactMap { term(from: $0) }
    }

    static func term(from line: String) -> CustomVocabularyTerm? {
        guard let parsed = parse(line) else { return nil }
        return CustomVocabularyTerm(
            text: parsed.text,
            aliases: parsed.aliases.isEmpty ? nil : parsed.aliases
        )
    }

    static func parse(_ line: String) -> ParsedLine? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let colon = trimmed.firstIndex(of: ":") else {
            return ParsedLine(text: trimmed, aliases: [])
        }
        let text = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        let aliases = trimmed[trimmed.index(after: colon)...]
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return ParsedLine(text: text, aliases: aliases)
    }
}
