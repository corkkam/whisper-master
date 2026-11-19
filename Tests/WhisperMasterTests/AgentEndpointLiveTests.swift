import XCTest

@testable import WhisperMaster

/// A bench arm for the endpoint tier, in the style of `KunaiLiveTests`: it talks to a
/// real server and **skips rather than fails** when none is set, so CI and a fresh
/// clone stay green. It runs the 16 first-turn tool cases (`LabSuiteLoader.toolCases`)
/// through `CloudToolGenerator` and prints the score.
///
/// Two arms, one per kind of server:
///
/// ```bash
/// # A local model server (no key):
/// WM_ENDPOINT_URL=http://127.0.0.1:11434/v1/chat/completions WM_ENDPOINT_MODEL=qwen3:8b \
///   swift test --filter AgentEndpointLiveTests
/// # A cloud model (spends money on your key):
/// WM_ENDPOINT_API=anthropic WM_ENDPOINT_URL=https://api.anthropic.com/v1/messages \
///   WM_ENDPOINT_MODEL=claude-opus-5-5 WM_ENDPOINT_KEY="$KEY" \
///   swift test --filter AgentEndpointLiveTests
/// ```
@MainActor
final class AgentEndpointLiveTests: XCTestCase {
    func testFirstTurnToolChoiceOnALiveEndpoint() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["WM_ENDPOINT_URL"], let model = env["WM_ENDPOINT_MODEL"] else {
            throw XCTSkip("Set WM_ENDPOINT_URL and WM_ENDPOINT_MODEL to run the endpoint bench.")
        }
        let api: AgentEndpoint.API = env["WM_ENDPOINT_API"] == "anthropic" ? .anthropic : .openAICompatible
        let endpoint = AgentEndpoint(api: api, url: raw, model: model)
        let sent = EndpointSendLog(host: endpoint.host)
        guard let generator = CloudToolGenerator(endpoint: endpoint, apiKey: env["WM_ENDPOINT_KEY"],
                                                 sent: sent)
        else { throw XCTSkip("\(raw) is not https or a loopback http address.") }

        let setup = LabToolBench.setup()
        var passed = 0
        for (spoken, expected) in LabSuiteLoader.toolCases {
            let started = Date()
            let reply = await generator.reply(LabToolBench.messages(for: spoken, setup: setup),
                                              tools: setup.schemas)
            let called = reply.flatMap { LabToolBench.calledTool(in: $0, setup: setup) }
            if called == expected { passed += 1 }
            print(String(format: "[endpoint-bench] %@ %5.1fs  %@ -> %@", called == expected ? "PASS" : "FAIL",
                         Date().timeIntervalSince(started), spoken, called ?? "no call"))
        }
        print("[endpoint-bench] \(api.rawValue) \(model): \(passed)/\(LabSuiteLoader.toolCases.count) "
            + "first-turn tool choices, \(sent.snapshot.failures) failed requests")
        XCTAssertEqual(sent.snapshot.failures, 0, "the server failed requests; the score is not a model score")
    }
}
