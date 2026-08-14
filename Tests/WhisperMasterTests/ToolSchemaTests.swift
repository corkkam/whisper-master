import XCTest

@testable import WhisperMaster

/// `ToolSchema` renders `ToolDescriptor`s as the JSON function schemas the native
/// chat template expects. Pure, so it needs no model.
final class ToolSchemaTests: XCTestCase {
    private func schema(for name: String) -> [String: Any] {
        let tool = ToolCatalog.all.first { $0.name == name }!
        let json = ToolSchema.functionSchemas(for: [tool])[0]
        return (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    }

    func testWrapsEachToolAsAFunction() {
        let object = schema(for: "list_tasks")
        XCTAssertEqual(object["type"] as? String, "function")
        let function = object["function"] as? [String: Any]
        XCTAssertEqual(function?["name"] as? String, "list_tasks")
        XCTAssertFalse((function?["description"] as? String ?? "").isEmpty)
    }

    func testRequiredParametersAreListed() {
        let function = schema(for: "send_message")["function"] as? [String: Any]
        let parameters = function?["parameters"] as? [String: Any]
        let required = parameters?["required"] as? [String] ?? []
        XCTAssertTrue(required.contains("channel"))
        XCTAssertTrue(required.contains("text"))
    }

    func testOptionalParametersAreNotRequired() {
        let function = schema(for: "list_calendar_events")["function"] as? [String: Any]
        let parameters = function?["parameters"] as? [String: Any]
        // `when` is the only parameter and it is optional, so `required` is omitted.
        XCTAssertNil(parameters?["required"])
        let properties = parameters?["properties"] as? [String: Any]
        XCTAssertNotNil(properties?["when"])
    }

    func testIntegerParameterKeepsItsType() {
        let function = schema(for: "create_calendar_event")["function"] as? [String: Any]
        let properties = (function?["parameters"] as? [String: Any])?["properties"] as? [String: Any]
        let duration = properties?["duration_minutes"] as? [String: Any]
        XCTAssertEqual(duration?["type"] as? String, "integer")
    }

    /// The enum on an instance-scoped argument survives, which is what stops the model
    /// inventing a connector name.
    func testAllowedValuesBecomeAnEnum() {
        let descriptor = ToolDescriptor(
            name: "send_message", summary: "Post a message.", access: .write,
            capability: .messages, targetArg: "channel",
            parameters: [
                ToolParameter("connector", description: "Which connector.",
                              allowedValues: ["Work", "Personal"])
            ])
        let json = ToolSchema.functionSchemas(for: [descriptor])[0]
        let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
        let properties = ((object?["function"] as? [String: Any])?["parameters"] as? [String: Any])?["properties"] as? [String: Any]
        let connector = properties?["connector"] as? [String: Any]
        XCTAssertEqual(connector?["enum"] as? [String], ["Work", "Personal"])
    }
}
