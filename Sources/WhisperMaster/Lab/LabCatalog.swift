import Foundation

/// What a lab model can be pointed at. A model that cannot tool-call is useless
/// in the assistant slot, and a chat model in the cleanup slot is a different
/// (worse) job — see `CleanupModel.General` for the whole account of why the app
/// keeps two models rather than one.
enum LabRole: String, Codable, Sendable, CaseIterable {
    case cleanup
    case assistant
}

/// Where a catalogue entry stands relative to what the app actually ships.
/// Purely descriptive: it decides a badge, never behaviour.
enum LabProvenance: String, Codable, Sendable {
    /// The model the shipped cleanup path loads today.
    case shippingCleanup
    /// The model the shipped assistant path loads today.
    case shippingAssistant
    /// Shipped once, replaced. Kept so a regression has a line to be measured against.
    case retired
    /// Never shipped. Here to be measured.
    case candidate
    /// Added on this Mac by its Hugging Face id (`LabCustomModels`).
    case custom

    var badge: String? {
        switch self {
        case .shippingCleanup, .shippingAssistant: return "shipping"
        case .retired: return "retired"
        case .candidate: return nil
        case .custom: return "added"
        }
    }
}

/// Whether a model reasons before it answers, read off its chat template.
enum LabReasoning: String, Codable, Sendable {
    /// Answers directly. The shipped assistant (Qwen3-4B-Instruct-2507) is one.
    case none
    /// The template honours `enable_thinking`: Qwen3's hybrid builds, SmolLM3.
    /// Benched both ways, as two rows.
    case optional
    /// The template opens `<think>` on every turn: Qwen3 Thinking-2507, the R1
    /// distills. There is no way to switch it off.
    case always

    /// Read from the chat template. Only the part after the last
    /// `add_generation_prompt` decides "always", because that is what is appended
    /// to every prompt: the shipped Instruct-2507 template mentions `<think>` too,
    /// but only to strip it from earlier turns.
    static func detect(chatTemplate template: String) -> LabReasoning {
        if template.contains("enable_thinking") { return .optional }
        guard let tail = template.range(of: "add_generation_prompt", options: .backwards) else {
            return .none
        }
        let prompt = template[tail.upperBound...]
        return prompt.contains("<think>") && !prompt.contains("</think>") ? .always : .none
    }
}

/// One open-source model the dev build can install, load and bench.
///
/// Everything here is a fact about the model, not about this Mac — installed
/// state and size on disk are asked of the filesystem by `LabModelStore`, so a
/// catalogue entry stays a pure value and the tests never touch a download.
struct LabModel: Identifiable, Hashable, Sendable {
    /// Stable key. Persisted in run records and in the "use this one" override,
    /// so renaming it invalidates saved runs — pick it once.
    let id: String
    let name: String
    /// Hugging Face repo id. Every entry can be fetched from here; the mirror
    /// below is only a faster path for the two models we already host.
    let huggingFaceId: String
    /// R2 archive base name when we mirror this model, else nil. Mirrored models
    /// unpack into `CleanupModel.modelsRoot`; the rest land in the Hugging Face
    /// cache that MLX's own loader uses.
    let archiveName: String?
    /// Rough download size, shown before a fetch starts. A number to decide with,
    /// not a measurement — the real size on disk is read once it is installed.
    let approximateDownloadBytes: Int64
    let parameters: String
    let quantization: String
    let roles: Set<LabRole>
    let provenance: LabProvenance
    /// One line on why this model is in the list at all.
    let note: String
    /// What the model can do. Decides whether a reasoning row is offered for it.
    var reasoning: LabReasoning = .none
    /// This row is benched with its reasoning on. The same model on disk can be
    /// two rows, one per setting, so a run can put them side by side.
    var thinks = false

    func supports(_ role: LabRole) -> Bool { roles.contains(role) }

    /// The one tag a row has room for. "reasoning" wins over the provenance
    /// badge, because two rows of the same weights read the same otherwise.
    var railTag: String? { thinks ? "reasoning" : provenance.badge }

    /// The row that benches a hybrid model with its reasoning on.
    ///
    /// **Assistant only.** Reasoning before a cleanup triples its latency to
    /// produce one sentence, and the tool suite is where reasoning can earn
    /// its cost.
    var reasoningVariant: LabModel {
        var variant = LabModel(
            id: id + "+reasoning", name: name + " (reasoning)", huggingFaceId: huggingFaceId,
            archiveName: archiveName, approximateDownloadBytes: approximateDownloadBytes,
            parameters: parameters, quantization: quantization, roles: [.assistant],
            provenance: provenance,
            note: "Same weights, reasoning on. Thinks before it calls a tool.")
        variant.reasoning = reasoning
        variant.thinks = true
        return variant
    }

    /// This row, then its reasoning row when it has one.
    var rows: [LabModel] {
        reasoning == .optional && supports(.assistant) ? [self, reasoningVariant] : [self]
    }
}

/// The models the lab offers.
///
/// Adding one for everybody is a row in `builtIn` and nothing else: the runner,
/// the rail and the leaderboard all read this list. Sizes are the 4-bit MLX
/// conversions published by `mlx-community` unless the id says otherwise. Trying
/// one on this Mac only needs its Hugging Face id typed into the rail, which
/// lands in `LabCustomModels` and joins the list here.
///
/// **The three shipped/retired entries earn their place.** A bench with no
/// baseline answers "which candidate is best" when the question is always "is any
/// candidate better than what users already have".
enum LabCatalog {
    static let builtIn: [LabModel] = catalogue.flatMap(\.rows)

    private static let catalogue: [LabModel] = [
        LabModel(
            id: "s1-mini-4bit",
            name: "S1-mini",
            huggingFaceId: "superwhisper/s1-mini",
            archiveName: "s1-mini-4bit",
            approximateDownloadBytes: 335 * 1_000_000,
            parameters: "0.6B",
            quantization: "4-bit",
            roles: [.cleanup],
            provenance: .shippingCleanup,
            note: "The shipped normalizer. Not a chat model: it will not tool-call."),
        LabModel(
            id: "qwen3-4b-instruct-2507-4bit",
            name: "Qwen3-4B-Instruct-2507",
            huggingFaceId: "mlx-community/Qwen3-4B-Instruct-2507-4bit",
            archiveName: "Qwen3-4B-Instruct-2507-4bit",
            approximateDownloadBytes: 2_300 * 1_000_000,
            parameters: "4B",
            quantization: "4-bit",
            roles: [.assistant, .cleanup],
            provenance: .shippingAssistant,
            note: "The shipped tool-caller. Non-thinking by default, so no <think> blocks."),
        LabModel(
            id: "qwen2.5-3b-instruct-4bit",
            name: "Qwen2.5-3B-Instruct",
            huggingFaceId: "mlx-community/Qwen2.5-3B-Instruct-4bit",
            archiveName: "Qwen2.5-3B-Instruct-4bit",
            approximateDownloadBytes: 1_500 * 1_000_000,
            parameters: "3B",
            quantization: "4-bit",
            roles: [.cleanup, .assistant],
            provenance: .retired,
            note: "The cleanup model S1-mini replaced. The regression line."),
        LabModel(
            id: "qwen3-0.6b-4bit",
            name: "Qwen3-0.6B",
            huggingFaceId: "mlx-community/Qwen3-0.6B-4bit",
            archiveName: nil,
            approximateDownloadBytes: 400 * 1_000_000,
            parameters: "0.6B",
            quantization: "4-bit",
            roles: [.cleanup, .assistant],
            provenance: .candidate,
            note: "S1-mini's base model, un-finetuned. What the fine-tune is worth.",
            reasoning: .optional),
        LabModel(
            id: "qwen3-1.7b-4bit",
            name: "Qwen3-1.7B",
            huggingFaceId: "mlx-community/Qwen3-1.7B-4bit",
            archiveName: nil,
            approximateDownloadBytes: 986 * 1_000_000,
            parameters: "1.7B",
            quantization: "4-bit",
            roles: [.cleanup, .assistant],
            provenance: .candidate,
            note: "The cheapest model that might still tool-call.",
            reasoning: .optional),
        LabModel(
            id: "qwen3-4b-thinking-2507-4bit",
            name: "Qwen3-4B-Thinking-2507",
            huggingFaceId: "mlx-community/Qwen3-4B-Thinking-2507-4bit",
            archiveName: nil,
            approximateDownloadBytes: 2_280 * 1_000_000,
            parameters: "4B",
            quantization: "4-bit",
            roles: [.assistant],
            provenance: .candidate,
            note: "The shipped assistant's reasoning twin: same size, always thinks first.",
            reasoning: .always,
            thinks: true),
        LabModel(
            id: "llama-3.2-1b-instruct-4bit",
            name: "Llama-3.2-1B-Instruct",
            huggingFaceId: "mlx-community/Llama-3.2-1B-Instruct-4bit",
            archiveName: nil,
            approximateDownloadBytes: 712 * 1_000_000,
            parameters: "1B",
            quantization: "4-bit",
            roles: [.cleanup, .assistant],
            provenance: .candidate,
            note: "Different family, same size class as the shipped normalizer."),
        LabModel(
            id: "llama-3.2-3b-instruct-4bit",
            name: "Llama-3.2-3B-Instruct",
            huggingFaceId: "mlx-community/Llama-3.2-3B-Instruct-4bit",
            archiveName: nil,
            approximateDownloadBytes: 1_800 * 1_000_000,
            parameters: "3B",
            quantization: "4-bit",
            roles: [.cleanup, .assistant],
            provenance: .candidate,
            note: "Llama's tool-calling posture against Qwen3-4B's."),
        LabModel(
            id: "gemma-3-1b-it-4bit",
            name: "Gemma-3-1b-it",
            huggingFaceId: "mlx-community/gemma-3-1b-it-4bit",
            archiveName: nil,
            approximateDownloadBytes: 768 * 1_000_000,
            parameters: "1B",
            quantization: "4-bit",
            roles: [.cleanup],
            provenance: .candidate,
            note: "Google's small instruct build. No native tool schema."),
        LabModel(
            id: "phi-4-mini-instruct-4bit",
            name: "Phi-4-mini-instruct",
            huggingFaceId: "mlx-community/Phi-4-mini-instruct-4bit",
            archiveName: nil,
            approximateDownloadBytes: 2_200 * 1_000_000,
            parameters: "3.8B",
            quantization: "4-bit",
            roles: [.cleanup, .assistant],
            provenance: .candidate,
            note: "Strong on instruction following for its size."),
        LabModel(
            id: "smollm2-1.7b-instruct-4bit",
            name: "SmolLM2-1.7B-Instruct",
            huggingFaceId: "mlx-community/SmolLM2-1.7B-Instruct-4bit",
            archiveName: nil,
            approximateDownloadBytes: 950 * 1_000_000,
            parameters: "1.7B",
            quantization: "4-bit",
            roles: [.cleanup],
            provenance: .candidate,
            note: "The small-model floor: how bad is bad."),
    ]

    /// The built-in models, then the ones added on this Mac.
    static func all(defaults: UserDefaults = .standard) -> [LabModel] {
        builtIn + LabCustomModels.load(defaults: defaults).flatMap(\.models)
    }

    /// Built-ins first, so the common lookup never decodes the added list.
    /// `CleanupModel.directory` comes through here whenever a slot is overridden.
    static func model(id: String, defaults: UserDefaults = .standard) -> LabModel? {
        if let model = builtIn.first(where: { $0.id == id }) { return model }
        return LabCustomModels.load(defaults: defaults).flatMap(\.models).first { $0.id == id }
    }

    /// The entry the shipped cleanup path uses, which is the default baseline in
    /// every comparison.
    static var shippedCleanup: LabModel { builtIn.first { $0.provenance == .shippingCleanup }! }

    static var shippedAssistant: LabModel { builtIn.first { $0.provenance == .shippingAssistant }! }
}
