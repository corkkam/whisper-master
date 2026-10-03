import Foundation
import Hub
import MLXLLM
import MLXLMCommon

/// A model somebody added to the lab by its Hugging Face id, rather than one the
/// catalogue ships with.
///
/// Everything here was read off the repo at the moment it was added, so the rail
/// can say what a model costs and what it can do without asking the network again.
struct LabCustomModel: Codable, Hashable, Sendable {
    let huggingFaceId: String
    let modelType: String
    let approximateDownloadBytes: Int64
    let parameters: String
    let quantization: String
    /// The repo's chat template takes a `tools` list. Without one, the tool suite
    /// would score the model zero for a reason that is not about its quality.
    let supportsTools: Bool
    let addedAt: Date

    /// `hf:` so a custom id can never collide with a catalogue id, and lowercased
    /// because Hugging Face ids are case-insensitive: the same repo added twice
    /// with different casing must be one model in every saved run.
    var id: String { "hf:" + huggingFaceId.lowercased() }

    var model: LabModel {
        LabModel(
            id: id,
            name: String(huggingFaceId.split(separator: "/").last ?? Substring(huggingFaceId)),
            huggingFaceId: huggingFaceId,
            archiveName: nil,
            approximateDownloadBytes: approximateDownloadBytes,
            parameters: parameters,
            quantization: quantization,
            roles: supportsTools ? [.cleanup, .assistant] : [.cleanup],
            provenance: .custom,
            note: "\(huggingFaceId), model type \(modelType)."
                + (supportsTools ? "" : " Its chat template takes no tools."))
    }
}

/// The models added by hand, kept in defaults beside the lab's other settings.
///
/// **An entry is re-validated on every read, not only when it is added.** The
/// repo id becomes a directory under the Hugging Face cache, and the "use for
/// this slot" override points the shipped cleanup path at that directory. A
/// hand-edited defaults value with `..` in it must not become a path out of the
/// cache, so a bad id is dropped here rather than trusted because it was saved.
enum LabCustomModels {
    static let key = "WhisperMaster.lab.customModels.v1"

    static func load(defaults: UserDefaults = .standard) -> [LabCustomModel] {
        guard let data = defaults.data(forKey: key),
              let saved = try? JSONDecoder().decode([LabCustomModel].self, from: data)
        else { return [] }
        return saved.filter { LabHuggingFace.repoID(from: $0.huggingFaceId) == $0.huggingFaceId }
    }

    static func save(_ models: [LabCustomModel], defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(models) else { return }
        defaults.set(data, forKey: key)
    }
}

/// Reading a Hugging Face repo well enough to decide, before any download, whether
/// the lab can run it.
///
/// **The check happens when the id is entered, not when the run starts.** Same
/// reason the checkout folder is checked when it is chosen: a typo or a PyTorch-only
/// repo has to say so in the second you are looking at it, not 40 minutes into a
/// run after a 4 GB download.
enum LabHuggingFace {
    /// Why a repo cannot be added. Each message names the fix, or says there is
    /// none from this side.
    enum Rejection: Error, Equatable, LocalizedError {
        case notARepoID
        case notFound(String)
        case gated(String)
        case alreadyListed(String)
        case missingFile(String)
        case noSafetensors
        case noChatTemplate
        case noModelType
        case unsupportedModelType(String)
        case network(String)

        var errorDescription: String? {
            switch self {
            case .notARepoID:
                return "Enter a repo id like mlx-community/Qwen3-1.7B-4bit, or paste its URL."
            case .notFound(let id):
                return "No public model at \(id)."
            case .gated(let id):
                return "\(id) is gated behind a Hugging Face login. Try its mlx-community conversion."
            case .alreadyListed(let id):
                return "\(id) is already in the list."
            case .missingFile(let file):
                return "The repo has no \(file), which MLX needs to load it."
            case .noSafetensors:
                return "The repo has no .safetensors weights. Look for an MLX conversion of it."
            case .noChatTemplate:
                return "The repo has no chat template, so it is a base model that cannot follow a prompt."
            case .noModelType:
                return "The repo's config names no model type, so MLX cannot pick an architecture."
            case .unsupportedModelType(let type):
                return "Model type \(type) is not one this build of MLX can load."
            case .network(let detail):
                return "Could not reach Hugging Face: \(detail)"
            }
        }
    }

    /// What `GET /api/models/<id>?blobs=true` returns, reduced to what the check
    /// reads. Every field is optional because the API omits rather than nulls.
    struct RepoInfo: Decodable {
        struct Sibling: Decodable {
            let rfilename: String
            let size: Int64?
        }

        struct Config: Decodable {
            struct Quantization: Decodable { let bits: Int? }
            struct TokenizerConfig: Decodable {
                let chatTemplate: ChatTemplate?
                enum CodingKeys: String, CodingKey { case chatTemplate = "chat_template" }
            }

            let modelType: String?
            let quantizationConfig: Quantization?
            let tokenizerConfig: TokenizerConfig?

            enum CodingKeys: String, CodingKey {
                case modelType = "model_type"
                case quantizationConfig = "quantization_config"
                case tokenizerConfig = "tokenizer_config"
            }
        }

        /// A chat template is a string, or a list of named templates
        /// (`[{"name": "tool_use", "template": "…"}]`). Only its text matters here.
        struct ChatTemplate: Decodable {
            let text: String

            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let single = try? container.decode(String.self) {
                    text = single
                } else if let named = try? container.decode([[String: String]].self) {
                    text = named.compactMap { $0["template"] }.joined(separator: "\n")
                } else {
                    text = ""
                }
            }
        }

        let id: String
        let gated: Gated?
        let siblings: [Sibling]?
        let config: Config?

        /// `false`, or the gating mode as a string (`"auto"`, `"manual"`).
        struct Gated: Decodable {
            let isGated: Bool
            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let flag = try? container.decode(Bool.self) {
                    isGated = flag
                } else {
                    isGated = (try? container.decode(String.self)) != nil
                }
            }
        }
    }

    // MARK: - Pure

    /// The `owner/name` id in what was typed, or nil. Takes a bare id or a pasted
    /// URL (`https://huggingface.co/owner/name/tree/main`).
    ///
    /// **Strict on purpose.** The id becomes a path under the Hugging Face cache,
    /// so each part must look like a Hugging Face name and never like `..`.
    static func repoID(from input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://", "http://"] where text.lowercased().hasPrefix(prefix) {
            text.removeFirst(prefix.count)
        }
        for host in ["huggingface.co/", "www.huggingface.co/", "hf.co/"]
        where text.lowercased().hasPrefix(host) {
            text.removeFirst(host.count)
        }
        let parts = text.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else { return nil }
        // Anything past owner/name is a page inside the repo (`/tree/main`,
        // `/blob/main/config.json`), so a bare id with a third part is refused
        // rather than guessed at.
        if parts.count > 2, !["tree", "blob", "resolve"].contains(parts[2]) { return nil }
        let owner = parts[0], name = parts[1]
        guard isNamePart(owner), isNamePart(name) else { return nil }
        return "\(owner)/\(name)"
    }

    private static func isNamePart(_ part: String) -> Bool {
        guard (1 ... 96).contains(part.count), part != ".", part != "..",
              let first = part.unicodeScalars.first,
              CharacterSet.alphanumerics.contains(first)
        else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return part.unicodeScalars.allSatisfy { allowed.contains($0) } && !part.contains("..")
    }

    /// Decide whether a repo can be added, from what the API said about it. Pure,
    /// so every refusal is tested without a network.
    ///
    /// `chatTemplate` is the repo's `chat_template.jinja` when it has one. Newer
    /// repos (every Qwen3 2507 build, SmolLM3) keep the template there and not in
    /// `tokenizer_config.json`, so the API's `config` carries none, and reading only
    /// the API took the shipped assistant model for one that cannot call tools.
    static func assess(
        _ info: RepoInfo,
        chatTemplate: String? = nil,
        existingIDs: Set<String>,
        isSupported: (String) -> Bool,
        now: Date = Date()
    ) -> Result<LabCustomModel, Rejection> {
        let repo = info.id
        if existingIDs.contains(repo.lowercased()) { return .failure(.alreadyListed(repo)) }
        if info.gated?.isGated == true { return .failure(.gated(repo)) }

        let files = info.siblings ?? []
        let names = Set(files.map(\.rfilename))
        guard names.contains("config.json") else { return .failure(.missingFile("config.json")) }
        // `tokenizer.json` specifically: MLX fetches `*.json` and `*.safetensors`
        // and nothing else, so a sentencepiece-only `tokenizer.model` repo
        // downloads fine and then fails to load.
        guard names.contains("tokenizer.json") else { return .failure(.missingFile("tokenizer.json")) }
        guard names.contains(where: { $0.hasSuffix(".safetensors") }) else { return .failure(.noSafetensors) }

        guard let modelType = info.config?.modelType, !modelType.isEmpty else {
            return .failure(.noModelType)
        }
        guard isSupported(modelType) else { return .failure(.unsupportedModelType(modelType)) }

        // What MLX will actually fetch, which is what the run bar warns about.
        let bytes = files
            .filter { $0.rfilename.hasSuffix(".safetensors") || $0.rfilename.hasSuffix(".json") }
            .reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        let template = chatTemplate ?? info.config?.tokenizerConfig?.chatTemplate?.text ?? ""
        guard !template.isEmpty else { return .failure(.noChatTemplate) }

        return .success(LabCustomModel(
            huggingFaceId: repo,
            modelType: modelType,
            approximateDownloadBytes: bytes,
            parameters: parameters(in: repo) ?? "?",
            quantization: quantization(bits: info.config?.quantizationConfig?.bits, name: repo),
            supportsTools: template.contains("tools"),
            addedAt: now))
    }

    /// "Qwen3-1.7B-4bit" → "1.7B". Read from the name because the API's parameter
    /// count is of the stored tensors, which for a 4-bit conversion is packed
    /// integers and reads as a model a quarter of its size.
    static func parameters(in repoID: String) -> String? {
        let name = repoID.split(separator: "/").last.map(String.init) ?? repoID
        let pattern = #"(?<![A-Za-z0-9.])(\d+(?:\.\d+)?)([BbMm])(?![A-Za-z])"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              let number = Range(match.range(at: 1), in: name),
              let unit = Range(match.range(at: 2), in: name)
        else { return nil }
        return name[number] + name[unit].uppercased()
    }

    static func quantization(bits: Int?, name: String) -> String {
        if let bits { return "\(bits)-bit" }
        let lower = name.lowercased()
        for (marker, label) in [("bf16", "bf16"), ("fp16", "fp16"), ("8bit", "8-bit"), ("6bit", "6-bit"),
                                ("4bit", "4-bit"), ("3bit", "3-bit")]
        where lower.contains(marker) {
            return label
        }
        return "?"
    }

    // MARK: - Network

    /// Look a repo up and decide. The one call in the lab that reaches Hugging
    /// Face outside a model download.
    static func check(
        _ input: String, existingIDs: Set<String>, session: URLSession = .shared
    ) async -> Result<LabCustomModel, Rejection> {
        guard let repo = repoID(from: input) else { return .failure(.notARepoID) }
        guard let url = URL(string: "https://huggingface.co/api/models/\(repo)?blobs=true") else {
            return .failure(.notARepoID)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            // Hugging Face answers 401, not 404, for a repo that does not exist
            // when the caller is not logged in, so the two mean the same here.
            if status == 401 || status == 404 { return .failure(.notFound(repo)) }
            guard status == 200 else { return .failure(.network("HTTP \(status)")) }
            let info = try JSONDecoder().decode(RepoInfo.self, from: data)
            var jinja: String?
            if info.siblings?.contains(where: { $0.rfilename == "chat_template.jinja" }) == true,
               let url = URL(string: "https://huggingface.co/\(repo)/resolve/main/chat_template.jinja") {
                var request = URLRequest(url: url)
                request.timeoutInterval = 20
                let (body, response) = try await session.data(for: request)
                if (response as? HTTPURLResponse)?.statusCode == 200 {
                    jinja = String(decoding: body, as: UTF8.self)
                }
            }
            return assess(info, chatTemplate: jinja, existingIDs: existingIDs,
                          isSupported: isSupportedModelType)
        } catch let error as DecodingError {
            return .failure(.network("unreadable answer (\(error.localizedDescription))"))
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }

    /// Whether the pinned MLXLLM can build this architecture.
    ///
    /// Asked of the registry itself rather than a copied list, so bumping
    /// mlx-swift-examples widens it with no edit here. The registry has no
    /// lookup, so this asks it to build from a file that does not exist: an
    /// unknown type throws `unsupportedModelType` before the file is read, and a
    /// known one fails reading the file instead.
    static func isSupportedModelType(_ type: String) -> Bool {
        let nowhere = URL(fileURLWithPath: "/dev/null/model-lab-probe/config.json")
        do {
            _ = try LLMTypeRegistry.shared.createModel(configuration: nowhere, modelType: type)
            return true
        } catch ModelFactoryError.unsupportedModelType {
            return false
        } catch {
            return true
        }
    }

    /// Fetch a model into the cache MLX's loader reads, with no time limit.
    ///
    /// **Not `MLXLMCommon.downloadModel`**, which fetches `*.safetensors` and
    /// `*.json` only. A repo whose chat template is in `chat_template.jinja` then
    /// arrives without one, and every generation fails to render a prompt. The
    /// tokenizer loader reads that file when it is there, so it is fetched too.
    ///
    /// The runner calls this before loading because the load itself is capped at
    /// 60 seconds (`MlxCleanupService.loadTimeoutSeconds`), and a load that has to
    /// download first spends that minute on the network: anything much over a
    /// gigabyte failed as "load failed" without ever reaching the GPU.
    ///
    /// **⚠️ The first call after launch can be told the Mac is offline.** The hub
    /// client's network monitor is created by that call and reads "not
    /// connected" until `NWPathMonitor` reports, so it refuses with
    /// `offlineModeError`. Found by the first headless reasoning bench: the first
    /// model's download failed and the second, a second later, succeeded. It is
    /// retried after the monitor has had time to report. It also counts Low Data
    /// Mode and a phone hotspot as offline, which no retry fixes, so the error says so.
    static func download(
        _ model: LabModel, onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        for attempt in 1 ... 3 {
            do {
                return try await defaultHubApi.snapshot(
                    from: model.huggingFaceId, matching: ["*.safetensors", "*.json", "*.jinja"]
                ) { onProgress($0.fractionCompleted) }
            } catch HubApi.EnvironmentError.offlineModeError where attempt < 3 {
                try await Task.sleep(nanoseconds: 1_500_000_000)
            } catch HubApi.EnvironmentError.offlineModeError {
                throw DownloadError.seenAsOffline
            }
        }
        throw DownloadError.seenAsOffline
    }

    enum DownloadError: LocalizedError {
        case seenAsOffline
        var errorDescription: String? {
            "the download client sees this Mac as offline. It counts Low Data Mode and a"
                + " phone hotspot as offline too."
        }
    }
}
