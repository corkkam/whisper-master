import Foundation

/// One validated call the model asked for.
struct ToolCall: Equatable, Sendable {
    let tool: String
    /// Validated against the descriptor: every key is a declared parameter, every
    /// required parameter is present, every value is the right type and (where
    /// enumerated) an allowed one.
    let arguments: [String: String]

    /// The value the consent model binds a grant to, for a write tool.
    func target(for descriptor: ToolDescriptor) -> String? {
        descriptor.targetArg.flatMap { arguments[$0] }
    }
}

/// What the model produced this turn.
enum AgentStep: Equatable, Sendable {
    /// It wants to call a tool.
    case call(ToolCall)
    /// It's done and this is the answer.
    case answer(String)
}

enum ToolCallParseError: Error, Equatable {
    case noJSONFound
    case malformedJSON
    case missingToolName
    case unknownTool(String)
    case unknownArgument(tool: String, argument: String)
    case missingRequiredArgument(tool: String, argument: String)
    case wrongType(argument: String, expected: String)
    case valueNotAllowed(argument: String, value: String)
    case emptyAnswer

    /// A short line fed back to the model so it can correct itself on the next
    /// iteration, rather than repeating the same malformed call.
    var modelFeedback: String {
        switch self {
        case .noJSONFound, .malformedJSON:
            return "Reply with one JSON object only."
        case .missingToolName:
            return "The JSON needs a \"tool\" or \"answer\" key."
        case .unknownTool(let name):
            return "There is no tool called \"\(name)\". Use one from the list."
        case .unknownArgument(let tool, let argument):
            return "\(tool) has no argument \"\(argument)\"."
        case .missingRequiredArgument(let tool, let argument):
            return "\(tool) requires \"\(argument)\"."
        case .wrongType(let argument, let expected):
            return "\"\(argument)\" must be a \(expected)."
        case .valueNotAllowed(let argument, let value):
            return "\"\(value)\" isn't a valid \(argument)."
        case .emptyAnswer:
            return "The answer was empty."
        }
    }
}

/// Turns raw model text into a validated `AgentStep`.
///
/// **Rejects rather than coerces**, deliberately. A 4-bit 3B model produces
/// near-miss calls often, and the tempting fix — guessing at the intended argument,
/// coercing `"3"` to `3`, snapping an invented connector name to the closest real one —
/// is how a tool ends up acting on something the user never asked for. A rejected call
/// costs one iteration and gets specific feedback; a silently repaired call can send a
/// message to the wrong channel.
///
/// Pure and synchronous, so the whole surface is unit-testable with no model, which
/// matters because MLX inference can't run under `swift test` at all.
enum ToolCallParser {
    static func parse(_ raw: String, tools: [ToolDescriptor]) -> Result<AgentStep, ToolCallParseError> {
        guard let json = extractJSONObject(from: raw) else {
            return .failure(.noJSONFound)
        }
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            return .failure(.malformedJSON)
        }

        // A final answer short-circuits — checked first so a model that emits both
        // keys is treated as finished rather than making one more call.
        if let answer = object["answer"] as? String {
            let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? .failure(.emptyAnswer) : .success(.answer(trimmed))
        }

        guard let toolName = (object["tool"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !toolName.isEmpty
        else { return .failure(.missingToolName) }

        guard let descriptor = tools.first(where: { $0.name == toolName }) else {
            return .failure(.unknownTool(toolName))
        }

        let rawArguments = (object["args"] as? [String: Any])
            ?? (object["arguments"] as? [String: Any])
            ?? [:]

        switch validate(rawArguments, against: descriptor) {
        case .failure(let error): return .failure(error)
        case .success(let arguments): return .success(.call(ToolCall(tool: toolName, arguments: arguments)))
        }
    }

    // MARK: - Argument validation

    private static func validate(_ raw: [String: Any],
                                 against descriptor: ToolDescriptor) -> Result<[String: String], ToolCallParseError> {
        let declared = Dictionary(uniqueKeysWithValues: descriptor.parameters.map { ($0.name, $0) })
        var validated: [String: String] = [:]

        for (key, value) in raw {
            guard let parameter = declared[key] else {
                return .failure(.unknownArgument(tool: descriptor.name, argument: key))
            }
            // An explicit null is the model's way of saying "not supplied"; treat it as
            // absent rather than as the string "null".
            if value is NSNull { continue }
            guard let string = coerce(value, to: parameter.type) else {
                return .failure(.wrongType(argument: key, expected: parameter.type.rawValue))
            }
            if string.isEmpty { continue }
            if !parameter.allowedValues.isEmpty {
                // Case-insensitive, because the model is echoing a label the user spoke.
                guard let match = parameter.allowedValues.first(where: {
                    $0.compare(string, options: .caseInsensitive) == .orderedSame
                }) else {
                    return .failure(.valueNotAllowed(argument: key, value: string))
                }
                validated[key] = match     // store the canonical label, not the echo
                continue
            }
            validated[key] = string
        }

        for parameter in descriptor.parameters where parameter.isRequired {
            guard validated[parameter.name] != nil else {
                return .failure(.missingRequiredArgument(tool: descriptor.name, argument: parameter.name))
            }
        }
        return .success(validated)
    }

    /// Type checking that permits only what's unambiguous. A JSON number for a
    /// `.string` parameter is fine (`"channel": 123`); a JSON string for an `.integer`
    /// is **not**, because `"limit": "lots"` would otherwise become a silent zero.
    private static func coerce(_ value: Any, to type: ToolParameter.ValueType) -> String? {
        switch type {
        case .string:
            if let string = value as? String { return string }
            if let number = value as? NSNumber { return number.stringValue }
            return nil
        case .integer:
            guard let number = value as? NSNumber, !isJSONBoolean(number),
                  Double(number.intValue) == number.doubleValue else { return nil }
            return String(number.intValue)
        case .boolean:
            guard let bool = value as? Bool else { return nil }
            return bool ? "true" : "false"
        }
    }

    /// Whether this is a JSON `true`/`false` rather than a number.
    ///
    /// `JSONSerialization` hands back a `CFBoolean`-backed `NSNumber` for a boolean,
    /// whose `intValue` is a perfectly integral 1 or 0 — so without this
    /// `{"duration_minutes": true}` was accepted as a 30-minute meeting's worth of
    /// "1". The check has to be on the underlying CF type: `value is Bool` can't tell
    /// the two apart either, because Swift bridges `NSNumber(1) as? Bool` successfully
    /// and that would reject a genuine `1`.
    private static func isJSONBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    // MARK: - JSON extraction

    /// Pull the first balanced `{…}` out of the model's text.
    ///
    /// Necessary because a small instruct model reliably wraps its JSON in prose or a
    /// ```json fence no matter how firmly the prompt forbids it. Brace-counting (rather
    /// than a regex) is what makes a nested object survive extraction intact, and
    /// string-awareness stops a brace inside a message body from ending the scan early.
    static func extractJSONObject(from raw: String) -> String? {
        guard let start = raw.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var result = ""

        for character in raw[start...] {
            result.append(character)
            if escaped { escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if character == "\"" { inString.toggle(); continue }
            if inString { continue }
            if character == "{" { depth += 1 }
            if character == "}" {
                depth -= 1
                if depth == 0 { return result }
            }
        }
        return nil      // unbalanced — a truncated generation
    }
}
