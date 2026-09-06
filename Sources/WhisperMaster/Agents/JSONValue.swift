import Foundation

/// A decoded JSON value of unknown shape.
///
/// Tool inputs on the kunai wire are `json.RawMessage`: their shape is whatever the
/// tool takes, so `Bash` carries `command`, `Edit` carries `file_path`, and
/// `AskUserQuestion` carries a nested array of questions and options. The notch
/// needs to read a handful of named fields out of that without modelling every tool
/// Claude Code has, and without a decode failure on an unfamiliar tool taking the
/// whole event with it.
///
/// Deliberately read-only and deliberately small: this exists to *look things up*,
/// not to round-trip. Anything it cannot represent decodes as `.null` rather than
/// throwing, for the same reason `KunaiWire.Event` decodes leniently — the server
/// updates on its own schedule.
enum JSONValue: Decodable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Double.self) { self = .number(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([JSONValue].self) { self = .array(v); return }
        if let v = try? c.decode([String: JSONValue].self) { self = .object(v); return }
        self = .null
    }

    // MARK: Lookups

    /// The string at `key`, or nil if this isn't an object or the value isn't a
    /// string. Numbers are **not** coerced: a path or a command is a string, and a
    /// silent number-to-string would hide a shape change rather than surface it.
    func string(_ key: String) -> String? {
        guard case .object(let o) = self, case .string(let s) = o[key] ?? .null else { return nil }
        return s
    }

    /// The array at `key`, or an empty array. Empty is the useful answer here: every
    /// caller is about to iterate.
    func array(_ key: String) -> [JSONValue] {
        guard case .object(let o) = self, case .array(let a) = o[key] ?? .null else { return [] }
        return a
    }

    /// This value as a string, when it is one.
    var stringValue: String? {
        guard case .string(let s) = self else { return nil }
        return s
    }

    /// The strings of an array value, skipping anything that isn't one.
    var stringArray: [String] {
        guard case .array(let a) = self else { return [] }
        return a.compactMap(\.stringValue)
    }
}

extension [String: JSONValue] {
    /// Convenience so callers can treat a decoded `input` dictionary the same way
    /// they treat a nested `JSONValue` object.
    var asJSON: JSONValue { .object(self) }
}
