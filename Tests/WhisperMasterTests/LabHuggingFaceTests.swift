import XCTest

@testable import WhisperMaster

/// Adding a Hugging Face model to the Model Lab: reading the id out of what was
/// typed, deciding from the repo's API answer whether the lab can run it, and the
/// fence that keeps a saved id from becoming a path out of the model cache.
///
/// No network: `assess` takes the decoded API answer, so every refusal is pinned
/// against a fixture shaped like the real one.
@MainActor
final class LabHuggingFaceTests: XCTestCase {

    // MARK: - The id

    func testABareIdAndAPastedURLGiveTheSameRepo() {
        let want = "mlx-community/Qwen3-1.7B-4bit"
        XCTAssertEqual(LabHuggingFace.repoID(from: want), want)
        XCTAssertEqual(LabHuggingFace.repoID(from: "  \(want)\n"), want)
        XCTAssertEqual(LabHuggingFace.repoID(from: "https://huggingface.co/\(want)"), want)
        XCTAssertEqual(LabHuggingFace.repoID(from: "https://huggingface.co/\(want)/tree/main"), want)
        XCTAssertEqual(LabHuggingFace.repoID(from: "hf.co/\(want)/blob/main/config.json"), want)
    }

    /// The id becomes a directory under the cache, and an override can point the
    /// shipped cleanup path at it.
    func testAnIdThatCouldLeaveTheCacheIsRefused() {
        for input in ["../etc", "mlx-community/..", "../../x", "owner/.hidden", "owner/na me",
                      "owner", "", "owner/name/extra", "/owner/name", "owner//name"] {
            XCTAssertNil(LabHuggingFace.repoID(from: input), input)
        }
    }

    func testASavedIdIsCheckedAgainOnEveryRead() throws {
        let defaults = try scratchDefaults()
        LabCustomModels.save([custom("mlx-community/Good-1B-4bit"), custom("../../Library")],
                             defaults: defaults)
        XCTAssertEqual(LabCustomModels.load(defaults: defaults).map(\.huggingFaceId),
                       ["mlx-community/Good-1B-4bit"])
    }

    // MARK: - The check

    func testARunnableRepoIsAddedWithWhatItCostsAndWhatItCanDo() throws {
        let result = LabHuggingFace.assess(
            try info(), existingIDs: [], isSupported: { $0 == "qwen3" })
        let added = try result.get()
        XCTAssertEqual(added.huggingFaceId, "mlx-community/Qwen3-1.7B-4bit")
        XCTAssertEqual(added.modelType, "qwen3")
        XCTAssertEqual(added.parameters, "1.7B")
        XCTAssertEqual(added.quantization, "4-bit")
        XCTAssertEqual(added.approximateDownloadBytes, 900 + 2_000 + 7_000,
                       "weights and json only, which is what MLX fetches; not the README")
        XCTAssertTrue(added.supportsTools)
        XCTAssertEqual(added.model.roles, [.cleanup, .assistant])
        XCTAssertEqual(added.model.provenance, .custom)
    }

    /// A model whose template takes no tools would score zero on the tool suite
    /// for a reason that is not about its quality.
    func testAModelWithNoToolTemplateIsOfferedForCleanupOnly() throws {
        let added = try LabHuggingFace.assess(
            try info(template: "{{ messages }}"), existingIDs: [], isSupported: { _ in true }).get()
        XCTAssertFalse(added.supportsTools)
        XCTAssertEqual(added.model.roles, [.cleanup])
    }

    func testEachRepoTheLabCannotRunSaysWhy() throws {
        func rejection(_ info: LabHuggingFace.RepoInfo, existing: Set<String> = [],
                       supported: Bool = true) -> LabHuggingFace.Rejection? {
            if case .failure(let why) = LabHuggingFace.assess(
                info, existingIDs: existing, isSupported: { _ in supported }) { return why }
            return nil
        }
        XCTAssertEqual(rejection(try info(gated: "\"manual\"")), .gated("mlx-community/Qwen3-1.7B-4bit"))
        XCTAssertEqual(rejection(try info(drop: "tokenizer.json")), .missingFile("tokenizer.json"))
        XCTAssertEqual(rejection(try info(drop: "config.json")), .missingFile("config.json"))
        XCTAssertEqual(rejection(try info(drop: "model.safetensors")), .noSafetensors)
        XCTAssertEqual(rejection(try info(modelType: nil)), .noModelType)
        XCTAssertEqual(rejection(try info(), supported: false), .unsupportedModelType("qwen3"))
        XCTAssertEqual(rejection(try info(), existing: ["mlx-community/qwen3-1.7b-4bit"]),
                       .alreadyListed("mlx-community/Qwen3-1.7B-4bit"),
                       "Hugging Face ids are case-insensitive")
    }

    /// The registry is asked, not a copied list, so this pins the probe against
    /// the pinned MLXLLM: a type it builds, and one it has never heard of.
    func testTheModelTypeProbeAsksTheRealRegistry() {
        XCTAssertTrue(LabHuggingFace.isSupportedModelType("qwen3"))
        XCTAssertTrue(LabHuggingFace.isSupportedModelType("llama"))
        XCTAssertFalse(LabHuggingFace.isSupportedModelType("not-a-real-architecture"))
    }

    func testParametersAreReadFromTheNameNotThePackedTensorCount() {
        XCTAssertEqual(LabHuggingFace.parameters(in: "mlx-community/Qwen3-1.7B-4bit"), "1.7B")
        XCTAssertEqual(LabHuggingFace.parameters(in: "mlx-community/SmolLM2-135M-Instruct-8bit"), "135M")
        XCTAssertEqual(LabHuggingFace.parameters(in: "mlx-community/gemma-3-1b-it-4bit"), "1B")
        XCTAssertNil(LabHuggingFace.parameters(in: "mlx-community/Phi-4-mini-instruct-4bit"))
    }

    // MARK: - In the lab

    func testAnAddedModelJoinsTheRailOnlyForSuitesItCanRun() throws {
        let defaults = try scratchDefaults()
        LabCustomModels.save([custom("mlx-community/NoTools-1B-4bit", tools: false)], defaults: defaults)
        let lab = LabController(load: false, defaults: defaults)
        lab.refresh()

        XCTAssertTrue(lab.eligibleModels.contains { $0.id == "hf:mlx-community/notools-1b-4bit" })
        lab.suite = .tools
        XCTAssertFalse(lab.eligibleModels.contains { $0.provenance == .custom })
        XCTAssertNotNil(LabCatalog.model(id: "hf:mlx-community/notools-1b-4bit", defaults: defaults),
                        "saved runs and the slot override find it by id")
    }

    func testRemovingAnAddedModelReleasesTheSlotItWasUsedFor() throws {
        let defaults = try scratchDefaults()
        let added = custom("mlx-community/Gone-1B-4bit")
        LabCustomModels.save([added], defaults: defaults)
        let lab = LabController(load: false, defaults: defaults)
        lab.refresh()
        LabModelOverride.set(added.id, for: .cleanup, defaults: defaults)
        lab.selectedModelIDs.insert(added.id)

        lab.remove(added.model)

        XCTAssertTrue(LabCustomModels.load(defaults: defaults).isEmpty)
        XCTAssertNil(LabModelOverride.modelID(for: .cleanup, defaults: defaults))
        XCTAssertFalse(lab.selectedModelIDs.contains(added.id))
        XCTAssertFalse(lab.allModels.contains { $0.id == added.id })
    }

    func testDownloadProgressIsReportedOncePerTenthAndNeverBackwards() {
        let tenths = LabDownloadTenths()
        XCTAssertNil(tenths.crossed(0.05))
        XCTAssertEqual(tenths.crossed(0.12), 1)
        XCTAssertNil(tenths.crossed(0.15))
        XCTAssertEqual(tenths.crossed(0.47), 4)
        XCTAssertNil(tenths.crossed(0.30), "a late callback must not report an earlier tenth")
        XCTAssertEqual(tenths.crossed(1.0), 10)
    }

    /// The fixtures above are only worth something while the real API still
    /// answers in their shape. `LAB_HF_LIVE=1 swift test --filter LabHuggingFaceTests`
    /// asks Hugging Face itself; skipped otherwise, so CI and an offline clone
    /// stay green.
    func testLiveTheRealAPIStillDecodesAndDecides() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LAB_HF_LIVE"] == "1",
                          "set LAB_HF_LIVE=1 to ask huggingface.co")
        let added = try await LabHuggingFace.check(
            "https://huggingface.co/mlx-community/Qwen3-1.7B-4bit", existingIDs: []).get()
        XCTAssertEqual(added.modelType, "qwen3")
        XCTAssertTrue(added.supportsTools)
        XCTAssertGreaterThan(added.approximateDownloadBytes, 500_000_000)

        let missing = await LabHuggingFace.check("nobody-xyz/does-not-exist-xyz", existingIDs: [])
        XCTAssertEqual(missing, .failure(.notFound("nobody-xyz/does-not-exist-xyz")))
        let gated = await LabHuggingFace.check("meta-llama/Llama-3.2-1B-Instruct", existingIDs: [])
        XCTAssertEqual(gated, .failure(.gated("meta-llama/Llama-3.2-1B-Instruct")))
    }

    // MARK: - Fixtures

    /// Shaped like `GET /api/models/mlx-community/Qwen3-1.7B-4bit?blobs=true`.
    private func info(
        gated: String = "false",
        drop: String? = nil,
        modelType: String? = "qwen3",
        template: String = "{%- if tools %}<tools>{%- endif %}"
    ) throws -> LabHuggingFace.RepoInfo {
        let files: [(String, Int)] = [
            ("README.md", 873), ("config.json", 900), ("tokenizer.json", 2_000),
            ("model.safetensors", 7_000),
        ].filter { $0.0 != drop }
        let siblings = files.map { #"{"rfilename": "\#($0.0)", "size": \#($0.1)}"# }
            .joined(separator: ",")
        let type = modelType.map { #""model_type": "\#($0)","# } ?? ""
        let json = """
        {"id": "mlx-community/Qwen3-1.7B-4bit", "gated": \(gated), "siblings": [\(siblings)],
         "config": {\(type) "quantization_config": {"bits": 4},
                    "tokenizer_config": {"chat_template": \(try jsonString(template))}}}
        """
        return try JSONDecoder().decode(LabHuggingFace.RepoInfo.self, from: Data(json.utf8))
    }

    private func jsonString(_ text: String) throws -> String {
        String(decoding: try JSONEncoder().encode(text), as: UTF8.self)
    }

    private func custom(_ repo: String, tools: Bool = true) -> LabCustomModel {
        LabCustomModel(huggingFaceId: repo, modelType: "qwen3", approximateDownloadBytes: 1,
                       parameters: "1B", quantization: "4-bit", supportsTools: tools, addedAt: Date())
    }

    private func scratchDefaults() throws -> UserDefaults {
        let name = "lab-hf-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return defaults
    }
}
