import Foundation

/// An evaluation case in the generalized schema. `input` is text or audio; audio
/// cases carry an `asr_reference` (exact words) so WER can be computed. Legacy
/// rows (a bare string `input`, no `targets`) are normalized on decode so the
/// existing committed cases keep working.
public struct EvalCase {
    public let id, category: String
    public let inputText, inputAudio, reference, asrReference: String?
    public let targets, mustContain, mustNotContain: [String]
    /// Case-**sensitive** variants. Every other assertion in the suite is
    /// case-insensitive, which means nothing could see a casing defect:
    /// `vocab-preserve` expects the custom term "Parakeet", the pipeline emits
    /// "parakeet", and `must_contain: ["Parakeet"]` passes. That is also why
    /// three cases had reached for a first-letter-dropped stem. These two lists
    /// compare exactly, so casing becomes assertable without changing what the
    /// existing 100-odd cases mean.
    public let mustContainExact, mustNotContainExact: [String]

    public static func decode(_ line: String) throws -> EvalCase {
        guard let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let id = obj["id"] as? String
        else { throw err("missing id") }

        var text: String?, audio: String?
        if let s = obj["input"] as? String {
            text = s
        } else if let d = obj["input"] as? [String: Any] {
            text = d["text"] as? String
            audio = d["audio"] as? String
        }
        if text == nil, audio == nil { throw err("case \(id): input must be text or audio") }

        let asrRef = obj["asr_reference"] as? String
        if audio != nil, (asrRef ?? "").isEmpty { throw err("case \(id): audio case needs asr_reference") }

        return EvalCase(
            id: id,
            category: obj["category"] as? String ?? "uncategorized",
            inputText: text, inputAudio: audio,
            reference: obj["reference"] as? String, asrReference: asrRef,
            targets: obj["targets"] as? [String] ?? ["light", "polish"],
            mustContain: obj["must_contain"] as? [String] ?? [],
            mustNotContain: obj["must_not_contain"] as? [String] ?? [],
            mustContainExact: obj["must_contain_exact"] as? [String] ?? [],
            mustNotContainExact: obj["must_not_contain_exact"] as? [String] ?? [])
    }

    public static func load(_ path: String) throws -> [EvalCase] {
        try String(contentsOfFile: path, encoding: .utf8)
            .split(separator: "\n").map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { try decode($0) }
    }

    private static func err(_ message: String) -> NSError {
        NSError(domain: "EvalCase", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
