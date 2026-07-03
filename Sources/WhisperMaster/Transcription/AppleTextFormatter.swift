#if canImport(FoundationModels)
import FoundationModels
import Foundation

/// On-device formatting via Apple's `SystemLanguageModel`. Holds one persistent,
/// prewarmed session; self-gates on availability and falls back to the raw text
/// on any error or guardrail, so it never throws or drops the user's words.
@available(macOS 26, *)
actor AppleTextFormatter: TextFormatting {
    private var session: LanguageModelSession?

    nonisolated var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    nonisolated var isInstant: Bool { false }

    func prewarm() async {
        guard isAvailable else { return }
        ensureSession().prewarm()
    }

    func format(_ text: String) async -> String {
        guard isAvailable,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return text }

        do {
            let response = try await ensureSession().respond(
                to: FormatterPrompt.userPrompt(for: text),
                options: GenerationOptions(sampling: .greedy, maximumResponseTokens: Self.tokenCap(for: text))
            )
            let formatted = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard Self.looksSane(formatted, original: text) else {
                Log.formatter.error("formatter output looked degenerate; using raw text")
                return text
            }
            return formatted
        } catch {
            Log.formatter.error("format failed, using raw text: \(error.localizedDescription, privacy: .public)")
            return text
        }
    }

    /// Generous response bound so a long dictation is never truncated (output is
    /// ~input length; chars comfortably exceed tokens). The repetition/length
    /// checks in `looksSane` are the real guard against a runaway loop.
    private static func tokenCap(for text: String) -> Int {
        min(1200, max(64, text.count))
    }

    /// Reject empty, runaway-long, or looping output (e.g. ".com.com.com") so a
    /// rare model degeneration falls back to the raw transcript instead of
    /// reaching the user.
    private static func looksSane(_ output: String, original: String) -> Bool {
        guard !output.isEmpty, output.count <= original.count * 2 + 24 else { return false }
        // A 2–12 char chunk repeated 3+ times back-to-back is a degeneration loop.
        return output.range(of: #"(.{2,12})\1{2,}"#, options: .regularExpression) == nil
    }

    private func ensureSession() -> LanguageModelSession {
        if let session { return session }
        let created = LanguageModelSession(instructions: FormatterPrompt.instructions)
        session = created
        return created
    }
}
#endif
