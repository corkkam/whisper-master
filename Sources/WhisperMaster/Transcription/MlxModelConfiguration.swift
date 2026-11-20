import Foundation
import MLXLMCommon

/// How every MLX model this app loads from disk is configured: the shipped
/// cleanup and assistant slots, the eval runner, and the Model Lab.
///
/// **One builder, because the lab is only worth what it shares with the app.**
/// The lab once added the end-of-turn stop tokens below on its own, so Gemma and
/// Phi-4-mini ranked well there while a dev build pointed at either one through
/// `LabModelOverride` loaded them without the stops, ran into invented turns, and
/// had every output rejected by the guard: cleanup silently did nothing. Load a
/// model from a directory through here, or the bench measures a configuration the
/// app does not run.
enum MlxModelConfiguration {
    static func local(_ directory: URL) -> ModelConfiguration {
        ModelConfiguration(directory: directory, extraEOSTokens: EndOfTurnTokens.endOfTurn(in: directory))
    }
}

/// End-of-turn markers a chat template closes the answer with, which generation
/// must stop on.
///
/// MLX stops only on the tokenizer's single `eos_token`. For Gemma that is
/// `<eos>` while the template ends a turn with `<end_of_turn>`; for Phi-4-mini
/// it is `<|endoftext|>` against `<|end|>`. Without this both ran past their
/// answer into invented follow-up turns, every output failed the guard, and run 7
/// scored the two of them as the no-op fallback (138/250 each, identical
/// records), which said nothing about either model. For the shipped Qwen3 models
/// it adds nothing that changes an answer: their `eos_token` is already
/// `<|im_end|>`.
///
/// Only markers present in the model's own `tokenizer.json` are returned: a
/// string the vocabulary lacks could map to the unknown-token id and stop
/// generation on the wrong token.
enum EndOfTurnTokens {
    static let candidates: Set<String> = [
        "<end_of_turn>", "<|end|>", "<|im_end|>", "<|eot_id|>", "<|endoftext|>", "<|end_of_text|>",
    ]

    static func endOfTurn(in directory: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("tokenizer.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let added = json["added_tokens"] as? [[String: Any]]
        else { return [] }
        return Set(added.compactMap { $0["content"] as? String }).intersection(candidates)
    }
}
