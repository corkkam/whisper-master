import Foundation

/// The tools available *to this user, right now* — the catalog filtered to what their
/// connections can actually serve, with the `connector` argument's allowed values
/// filled in from their own labels.
///
/// Filtering matters more than it looks: offering `list_messages` to a user with no
/// chat connector invites the model to call it and fail, and every failed call burns an
/// iteration of a budget a 3B model can't spare.
@MainActor
enum ToolRegistry {
    /// Tools the user's connections can serve.
    static func available(store: ConnectorInstanceStore,
                          includeWrites: Bool = true) -> [ToolDescriptor] {
        ToolCatalog.all.compactMap { descriptor in
            // A local tool needs no connection and has no consent card to bind to —
            // it's the user's own on-device data — so neither gate below applies.
            if descriptor.access == .local { return descriptor }
            if descriptor.access == .write {
                guard includeWrites else { return nil }
                // A write tool with no target argument could only ever be granted
                // blanket permission, so it is never published. Fail closed.
                guard descriptor.targetArg != nil else { return nil }
            }
            guard let capability = descriptor.capability else {
                return descriptor       // `list_connectors` needs no connection
            }
            let labels = store.readable(providing: capability).map(\.displayLabel)
            guard !labels.isEmpty else { return nil }
            return withInstanceArgument(descriptor, labels: labels)
        }
    }

    /// Add the `connector` parameter, constrained to the user's real labels.
    ///
    /// Enumerating the allowed values (rather than a free-text hint) is what stops the
    /// model inventing a connector name: an invented value fails schema validation
    /// before it reaches a provider.
    private static func withInstanceArgument(_ descriptor: ToolDescriptor,
                                            labels: [String]) -> ToolDescriptor {
        let instanceParameter = ToolParameter(
            ToolDescriptor.instanceArgument,
            isRequired: false,
            description: labels.count > 1
                ? "Which connector to use. Omit to use all of them."
                : "Which connector to use.",
            allowedValues: labels)
        return ToolDescriptor(
            name: descriptor.name,
            summary: descriptor.summary,
            access: descriptor.access,
            capability: descriptor.capability,
            targetArg: descriptor.targetArg,
            parameters: [instanceParameter] + descriptor.parameters)
    }

    /// The tool list rendered for the model's system prompt.
    ///
    /// Plain lines rather than JSON Schema: a 4-bit 3B model follows a terse list far
    /// more reliably than a nested schema blob, and the schema we'd be showing it is
    /// enforced on the way back in regardless.
    static func promptDescription(for tools: [ToolDescriptor]) -> String {
        tools.map { tool in
            let args = tool.parameters.map { parameter -> String in
                var rendered = parameter.name
                if !parameter.allowedValues.isEmpty {
                    rendered += "=<\(parameter.allowedValues.joined(separator: "|"))>"
                } else {
                    rendered += "=<\(parameter.type.rawValue)>"
                }
                return parameter.isRequired ? rendered : "[\(rendered)]"
            }.joined(separator: " ")
            let signature = args.isEmpty ? tool.name : "\(tool.name) \(args)"
            return "- \(signature) — \(tool.summary)"
        }.joined(separator: "\n")
    }
}
