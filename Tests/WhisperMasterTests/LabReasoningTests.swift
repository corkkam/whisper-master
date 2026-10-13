import XCTest

@testable import WhisperMaster

/// Benching reasoning models in the Model Lab: telling from a chat template
/// whether a model reasons, splitting its reasoning from its answer, the rows a
/// hybrid model gets, and the fence that keeps a reasoning row out of the
/// shipped slots.
@MainActor
final class LabReasoningTests: XCTestCase {

    // MARK: - Reading the template

    /// Tails as published: Qwen3-1.7B (hybrid), Qwen3-4B-Thinking-2507 and the
    /// R1 distill (always), and the shipped Instruct-2507, whose template names
    /// `<think>` only to strip it from earlier turns.
    func testTheGenerationPromptDecidesWhetherAModelAlwaysReasons() {
        XCTAssertEqual(LabReasoning.detect(chatTemplate: """
            {%- if add_generation_prompt %}{{- '<|im_start|>assistant\\n' }}
            {%- if enable_thinking is defined and enable_thinking is false %}
            {{- '<think>\\n\\n</think>\\n\\n' }}{%- endif %}{%- endif %}
            """), .optional)
        XCTAssertEqual(LabReasoning.detect(chatTemplate:
            "{%- if add_generation_prompt %}{{- '<|im_start|>assistant\\n<think>\\n' }}{%- endif %}"),
            .always)
        XCTAssertEqual(LabReasoning.detect(chatTemplate:
            "{% if add_generation_prompt and not ns.is_tool %}{{'<｜Assistant｜><think>\\n'}}{% endif %}"),
            .always)
        XCTAssertEqual(LabReasoning.detect(chatTemplate: """
            {%- if '</think>' in content %}{%- set content = content.split('</think>')[-1] %}{%- endif %}
            {%- if add_generation_prompt %}{{- '<|im_start|>assistant\\n' }}{%- endif %}
            """), .none)
    }

    func testReasoningIsSplitFromTheAnswerWithOrWithoutAnOpeningTag() {
        let opened = MlxCleanupService.splitReasoning("<think>\nweather, so get_weather\n</think>\n\n{\"name\":\"x\"}")
        XCTAssertEqual(opened.reasoning, "weather, so get_weather")
        XCTAssertEqual(opened.answer, "{\"name\":\"x\"}")

        // Thinking-only templates open the block in the prompt, so the output
        // carries only the close.
        let promptOpened = MlxCleanupService.splitReasoning("hmm\n</think>\nanswer")
        XCTAssertEqual(promptOpened.reasoning, "hmm")
        XCTAssertEqual(promptOpened.answer, "answer")
    }

    /// Its reasoning can name the tool it is weighing, so a model cut off mid-
    /// thought must not be scored as having called it.
    func testAModelStillReasoningHasNoAnswer() {
        let cut = MlxCleanupService.splitReasoning("<think>\nmaybe {\"name\":\"get_weather\"}")
        XCTAssertNil(cut.answer)
        XCTAssertEqual(cut.reasoning, "maybe {\"name\":\"get_weather\"}")
    }

    // MARK: - Rows

    func testAHybridModelGetsAnAssistantOnlyReasoningRow() throws {
        let base = try XCTUnwrap(LabCatalog.model(id: "qwen3-1.7b-4bit"))
        let variant = try XCTUnwrap(LabCatalog.model(id: "qwen3-1.7b-4bit+reasoning"))
        XCTAssertFalse(base.thinks)
        XCTAssertTrue(variant.thinks)
        XCTAssertEqual(variant.roles, [.assistant], "reasoning before every cleanup is a minute per sentence")
        XCTAssertEqual(variant.huggingFaceId, base.huggingFaceId, "one download serves both rows")
        XCTAssertEqual(variant.railTag, "reasoning")
    }

    func testTheToolSuiteOffersReasoningRowsAndTheCleanupSuitesDoNot() {
        let lab = LabController(load: false)
        lab.suite = .cleanup
        XCTAssertFalse(lab.eligibleModels.contains(where: \.thinks))
        lab.suite = .tools
        let ids = lab.eligibleModels.map(\.id)
        XCTAssertTrue(ids.contains("qwen3-4b-thinking-2507-4bit"))
        XCTAssertTrue(ids.contains("qwen3-1.7b-4bit+reasoning"))
        XCTAssertTrue(ids.contains(LabCatalog.shippedAssistant.id), "the baseline is in the same run")
    }

    /// The shipped paths render with `enable_thinking: false` on a 12 s budget,
    /// so a slot pointed at a reasoning row would run something other than what
    /// the lab measured.
    func testAReasoningRowCanNeverTakeAShippedSlot() throws {
        let lab = LabController(load: false)
        lab.seedForSnapshot(runs: [], installedIDs: ["qwen3-1.7b-4bit", "qwen3-1.7b-4bit+reasoning"])
        let base = try XCTUnwrap(LabCatalog.model(id: "qwen3-1.7b-4bit"))
        let variant = try XCTUnwrap(LabCatalog.model(id: "qwen3-1.7b-4bit+reasoning"))
        XCTAssertTrue(lab.canUse(base, for: .assistant))
        XCTAssertFalse(lab.canUse(variant, for: .assistant))
    }

    // MARK: - Added models

    func testAnAddedHybridModelGetsBothRowsAndRemovingOneRemovesBoth() throws {
        let defaults = try scratchDefaults()
        let added = try LabHuggingFace.assess(
            try info(template: "{%- if tools %}{%- endif %}{%- if enable_thinking %}{%- endif %}"),
            existingIDs: [], isSupported: { _ in true }).get()
        XCTAssertEqual(added.reasoning, .optional)
        XCTAssertEqual(added.models.map(\.thinks), [false, true])

        LabCustomModels.save([added], defaults: defaults)
        let lab = LabController(load: false, defaults: defaults)
        lab.refresh()
        lab.remove(try XCTUnwrap(added.models.last))
        XCTAssertFalse(lab.allModels.contains { $0.provenance == .custom })
    }

    func testAnAddedModelThatAlwaysReasonsIsAnAssistantRow() throws {
        let always = "{%- if tools %}{%- endif %}{%- if add_generation_prompt %}<think>\n{%- endif %}"
        let added = try LabHuggingFace.assess(
            try info(template: always), existingIDs: [], isSupported: { _ in true }).get()
        XCTAssertEqual(added.models.count, 1)
        XCTAssertEqual(added.models[0].roles, [.assistant])
        XCTAssertTrue(added.models[0].thinks)

        let noTools = "{%- if add_generation_prompt %}<think>\n{%- endif %}"
        XCTAssertEqual(
            LabHuggingFace.assess(try info(template: noTools), existingIDs: [], isSupported: { _ in true }),
            .failure(.reasonsWithoutTools))
    }

    /// Records saved before reasoning was benched have no `reasoning` key, and a
    /// decode throw would empty the whole added list.
    func testARecordSavedBeforeReasoningStillLoads() throws {
        let defaults = try scratchDefaults()
        let old = #"[{"huggingFaceId":"mlx-community/Old-1B-4bit","modelType":"qwen3","approximateDownloadBytes":1,"parameters":"1B","quantization":"4-bit","supportsTools":true,"addedAt":0}]"#
        defaults.set(Data(old.utf8), forKey: LabCustomModels.key)
        let loaded = LabCustomModels.load(defaults: defaults)
        XCTAssertEqual(loaded.map(\.reasoning), [.none])
    }

    func testOnlyAReasoningRowReportsReasoningTokens() {
        func result(_ tokens: [Int?]) -> LabModelResult {
            var model = LabModelResult(modelID: "m", modelName: "M")
            model.cases = tokens.enumerated().map { index, count in
                LabCaseResult(id: "\(index)", category: "c", target: "tools", inputKind: "text",
                              prompt: "", deterministic: "", modelOutput: "", finalOutput: "",
                              guardAccepted: true, passed: true, latencyMs: 1, reasoningTokens: count)
            }
            return model
        }
        XCTAssertNil(result([nil, nil]).medianReasoningTokens)
        XCTAssertEqual(result([100, 300, 200]).medianReasoningTokens, 200)
    }

    // MARK: - Fixtures

    private func info(template: String) throws -> LabHuggingFace.RepoInfo {
        let encoded = String(decoding: try JSONEncoder().encode(template), as: UTF8.self)
        let json = """
        {"id": "mlx-community/Hybrid-1.7B-4bit", "gated": false,
         "siblings": [{"rfilename": "config.json", "size": 1}, {"rfilename": "tokenizer.json", "size": 1},
                      {"rfilename": "model.safetensors", "size": 1}],
         "config": {"model_type": "qwen3", "tokenizer_config": {"chat_template": \(encoded)}}}
        """
        return try JSONDecoder().decode(LabHuggingFace.RepoInfo.self, from: Data(json.utf8))
    }

    private func scratchDefaults() throws -> UserDefaults {
        let name = "lab-reasoning-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return defaults
    }
}
