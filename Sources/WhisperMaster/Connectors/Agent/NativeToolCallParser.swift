import Foundation

/// Parses the model's **native** tool-call output — Qwen3's
/// `<tool_call>{"name":…,"arguments":{…}}</tool_call>` — into the same validated
/// `AgentStep` the hand-rolled `ToolCallParser` produces.
///
/// It does **not** re-implement validation. It remaps the native `{name,arguments}`
/// shape onto `ToolCallParser`'s `{tool,args}` shape and hands it straight over, so
/// there is exactly one place that rejects an unknown tool, a wrong-typed argument,
/// or an invented connector. Text with no `<tool_call>` block is the model's final
/// answer.
///
/// Pure and synchronous, like `ToolCallParser`, so the native path is unit-testable
/// with no model — which matters because MLX inference can't run under `swift test`.
enum NativeToolCallParser {
    static func parse(_ raw: String, tools: [ToolDescriptor]) -> Result<AgentStep, ToolCallParseError> {
        guard let block = extractToolCall(from: raw) else {
            // No tool call → the plain text is the answer. A model asked to "call a
            // function first" but that answered anyway is still handled the same as
            // the hand-rolled path — `CommandAgentService` counts execution, not text.
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? .failure(.emptyAnswer) : .success(.answer(trimmed))
        }
        guard let object = try? JSONSerialization.jsonObject(with: Data(block.utf8)) as? [String: Any] else {
            return .failure(.malformedJSON)
        }
        // Remap {name, arguments} → {tool, args}, then let the one validator judge it.
        // `arguments` may be absent (a no-argument tool like list_tasks).
        let name = (object["name"] as? String) ?? ""
        let remapped: [String: Any] = ["tool": name, "args": object["arguments"] ?? [String: Any]()]
        guard let data = try? JSONSerialization.data(withJSONObject: remapped),
              let json = String(data: data, encoding: .utf8) else {
            return .failure(.malformedJSON)
        }
        return ToolCallParser.parse(json, tools: tools)
    }

    /// The JSON inside the first `<tool_call>` block. Tolerates a missing closing tag
    /// (a truncated generation) by brace-matching the remainder, reusing
    /// `ToolCallParser`'s balanced-object scan so nested argument objects survive.
    static func extractToolCall(from raw: String) -> String? {
        guard let openRange = raw.range(of: "<tool_call>") else { return nil }
        let afterOpen = raw[openRange.upperBound...]
        let inner: Substring
        if let closeRange = afterOpen.range(of: "</tool_call>") {
            inner = afterOpen[..<closeRange.lowerBound]
        } else {
            inner = afterOpen
        }
        return ToolCallParser.extractJSONObject(from: String(inner))
    }
}
