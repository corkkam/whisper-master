import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Result type

struct ClassifiedIntent {
    enum Action {
        case note
        case reminder
        case dictate
    }
    let action: Action
    /// Transcription with the trigger phrase stripped out.
    let content: String
    let source: Source

    enum Source {
        case foundationModel
        case keywordRules
    }
}

// MARK: - Classifier

actor IntentClassifier {

    // MARK: - Public API

    /// Classifies `text` using Apple Foundation Models when available on macOS 26+,
    /// otherwise uses fast keyword rules.
    func classify(_ text: String, useAI: Bool = true) async -> ClassifiedIntent {
        if useAI {
            if #available(macOS 26, *) {
                if let result = try? await classifyWithFoundationModels(text) {
                    return result
                }
            }
        }
        return classifyWithRules(text)
    }

    // MARK: - Foundation Models path (macOS 26+)

    @available(macOS 26, *)
    private func classifyWithFoundationModels(_ text: String) async throws -> ClassifiedIntent {
        #if canImport(FoundationModels)
        // Only proceed when the on-device model is actually usable (Apple Intelligence
        // enabled, model downloaded, device not in a restricted state). Otherwise throw
        // so the caller falls back to keyword rules.
        guard case .available = SystemLanguageModel.default.availability else {
            throw FoundationModelsError.notAvailable
        }

        let session = LanguageModelSession(instructions: Self.classifierInstructions)
        let response = try await session.respond(
            to: "Transcription: \"\(text)\"",
            generating: IntentClassification.self
        )
        let classification = response.content

        // The model returns content with the command phrase already stripped; fall back to
        // the raw transcription if it handed back something empty.
        let trimmed = classification.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = trimmed.isEmpty ? text : trimmed

        let action: ClassifiedIntent.Action
        switch classification.action {
        case .note:     action = .note
        case .reminder: action = .reminder
        case .dictate:  action = .dictate
        }

        return ClassifiedIntent(action: action, content: content, source: .foundationModel)
        #else
        throw FoundationModelsError.notAvailable
        #endif
    }

    private static let classifierInstructions = """
        You are an intent classifier for a voice dictation app. The user speaks, and their \
        speech is transcribed. Classify each transcription into exactly one intent:

        - note: The user wants to save a note (e.g. "add a note to call Sam", "jot down the \
          grocery list", "make a note that the meeting moved").
        - reminder: The user wants to set a time- or task-based reminder (e.g. "remind me to \
          call the dentist", "don't forget to submit the report").
        - dictate: Anything else — the user is dictating text to be typed as-is.

        Spoken transcriptions often start with filler words like "so", "um", "okay", "yeah", \
        or "like" — ignore those when deciding the intent.

        For the `content` field, return only the actionable text with the command phrase \
        removed. For example, "so add a note to call Sam" → action: note, content: "call Sam". \
        For dictate, return the full transcription unchanged as the content.
        """

    enum FoundationModelsError: Error {
        case notAvailable
    }

    // MARK: - Keyword-rule fallback

    private func classifyWithRules(_ text: String) -> ClassifiedIntent {
        // Spoken transcriptions routinely begin with filler ("So…", "Okay…", "Um…").
        // Strip those first so trigger phrases still sit at the start for `hasPrefix`.
        let cleaned = stripLeadingFillers(text)
        let lower = cleaned.lowercased()

        let noteTriggers = [
            "add a note to", "add a note about", "add a note",
            "create a note about", "create a note",
            "new note about", "new note",
            "make a note about", "make a note",
            "quick note about", "quick note",
            "jot this down", "jot down",
            "write this down", "write down",
            "save a note", "note to self",
            "note that", "take a note",
        ]

        let reminderTriggers = [
            "remind me to", "remind me that", "remind me about", "remind me",
            "set a reminder to", "set a reminder for", "set a reminder about", "set a reminder",
            "add a reminder to", "add a reminder for", "add a reminder",
            "create a reminder to", "create a reminder",
            "reminder to", "reminder for",
            "don't forget to", "don't forget that", "don't forget",
            "remember to", "remember that",
            "i need to remember",
        ]

        for trigger in noteTriggers {
            if lower.hasPrefix(trigger) {
                return ClassifiedIntent(
                    action: .note,
                    content: stripped(cleaned, prefixCount: trigger.count),
                    source: .keywordRules
                )
            }
        }

        for trigger in reminderTriggers {
            if lower.hasPrefix(trigger) {
                return ClassifiedIntent(
                    action: .reminder,
                    content: stripped(cleaned, prefixCount: trigger.count),
                    source: .keywordRules
                )
            }
        }

        return ClassifiedIntent(action: .dictate, content: text, source: .keywordRules)
    }

    /// Leading discourse fillers that carry no intent and commonly open a dictation.
    private static let leadingFillers: Set<String> = [
        "so", "um", "uh", "uhm", "er", "okay", "ok", "well", "yeah", "yep",
        "yes", "like", "hey", "hmm", "alright", "please",
    ]

    /// Drops leading filler words (and the punctuation/space between them) so the first
    /// meaningful word lands at the start. Returns the original text if it's all filler.
    private func stripLeadingFillers(_ text: String) -> String {
        var remainder = text[...]
        while true {
            let afterTrim = remainder.drop { $0 == " " || $0 == "," || $0 == "." }
            let word = afterTrim.prefix { !$0.isWhitespace && $0 != "," }
            let normalized = word.lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?"))
            guard !normalized.isEmpty, Self.leadingFillers.contains(normalized) else {
                let result = String(afterTrim)
                return result.isEmpty ? text : result
            }
            remainder = afterTrim[word.endIndex...]
        }
    }

    private func stripped(_ text: String, prefixCount: Int) -> String {
        let idx = text.index(text.startIndex, offsetBy: prefixCount, limitedBy: text.endIndex) ?? text.endIndex
        let remainder = text[idx...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ":,."))
            .trimmingCharacters(in: .whitespaces)
        return remainder.isEmpty ? text : remainder
    }
}

// MARK: - Guided generation schema (macOS 26+)

#if canImport(FoundationModels)
@available(macOS 26, *)
@Generable
enum IntentAction {
    /// Save a note.
    case note
    /// Set a time- or task-based reminder.
    case reminder
    /// Plain dictation to be typed as-is.
    case dictate
}

@available(macOS 26, *)
@Generable
struct IntentClassification {
    @Guide(description: "The user's intent for this transcription.")
    let action: IntentAction

    @Guide(description: "The actionable text with any command phrase (e.g. 'add a note to') and leading filler words removed. For dictate, the full transcription unchanged.")
    let content: String
}
#endif
