import Foundation

/// Renders `ToolDescriptor`s as JSON function schemas for the model's **native**
/// tool-calling path — the OpenAI/HF `{"type":"function","function":{…}}` shape the
/// Qwen3 chat template dumps into its `<tools>` block.
///
/// The sibling of `ToolRegistry.promptDescription`, which renders the same tools as
/// the terse plain-line list the hand-rolled JSON prompt uses. It lives here beside
/// the agent loop rather than in `ToolRegistry` because the native path is the loop's,
/// and because the schema is emitted as JSON **strings**: that is what lets it cross
/// into `MlxCleanupService`'s actor without an `[String: Any]` Sendable escape hatch.
///
/// The hand-rolled `ToolParameter` schema is deliberately small (string / integer /
/// boolean, flat, optional enum), so the mapping to JSON Schema is one-to-one and
/// nothing is lost.
enum ToolSchema {
    /// One JSON function schema per tool, in prompt order. A tool that somehow can't
    /// be serialized is dropped rather than aborting the whole set.
    static func functionSchemas(for tools: [ToolDescriptor]) -> [String] {
        tools.compactMap { schemaJSON(for: $0) }
    }

    private static func schemaJSON(for tool: ToolDescriptor) -> String? {
        var properties: [String: Any] = [:]
        var required: [String] = []
        for parameter in tool.parameters {
            var property: [String: Any] = [
                "type": jsonType(parameter.type),
                "description": parameter.description,
            ]
            // Enumerated values are the model's guard against inventing a connector
            // name, same as in the plain-line rendering.
            if !parameter.allowedValues.isEmpty {
                property["enum"] = parameter.allowedValues
            }
            properties[parameter.name] = property
            if parameter.isRequired { required.append(parameter.name) }
        }
        var parameters: [String: Any] = [
            "type": "object",
            "properties": properties,
        ]
        if !required.isEmpty { parameters["required"] = required }
        let function: [String: Any] = [
            "name": tool.name,
            "description": tool.summary,
            "parameters": parameters,
        ]
        let schema: [String: Any] = ["type": "function", "function": function]
        guard let data = try? JSONSerialization.data(withJSONObject: schema),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return json
    }

    private static func jsonType(_ type: ToolParameter.ValueType) -> String {
        switch type {
        case .string: return "string"
        case .integer: return "integer"
        case .boolean: return "boolean"
        }
    }
}
