import Foundation

/// One answered question, kept so the answer outlives its banner.
///
/// The notch band shows a single truncated line for a few seconds and then it's gone —
/// which is fine for "you have three meetings" and useless for anything longer, and
/// worse than useless for a scheduled automation that answered while nobody was looking.
/// Nothing else in the app records these: an assistant capture deliberately skips the
/// transcript history (`routeCommandCapture` returns before `appendHistory`), so without
/// this the answer genuinely is unrecoverable. That's also what makes a tool-less answer
/// a legitimate outcome for the chord — `CommandAgentService` may return words rather
/// than an artifact precisely because the words become an artifact here.
struct AnsweredQuestion: Identifiable, Codable, Hashable {
    /// Where the question came from — the Today card labels an automation so a line the
    /// user never spoke isn't mistaken for one they did.
    enum Source: String, Codable {
        case spoken
        case automation
    }

    let id: UUID
    /// The question as asked. For an automation this is the task's title.
    let question: String
    let answer: String
    /// "From Work Calendar", or empty. Kept separate so it can be styled as the aside
    /// it is rather than run into the answer.
    let provenance: String
    let askedAt: Date
    let source: Source

    init(
        id: UUID = UUID(),
        question: String,
        answer: String,
        provenance: String = "",
        askedAt: Date = Date(),
        source: Source = .spoken
    ) {
        self.id = id
        self.question = question
        self.answer = answer
        self.provenance = provenance
        self.askedAt = askedAt
        self.source = source
    }
}

/// Load/save/trim for the answer log. Free functions rather than a store object because
/// the list lives on `AppState` beside `history`, follows the same
/// `UserDefaults`-JSON-capped-ring shape, and has no behaviour of its own worth a type.
enum AnswerLog {
    static let defaultsKey = "WhisperMaster.answerLog.v1"

    /// Deliberately smaller than the 50-entry transcript history. This is a "what did it
    /// just tell me" list, not an archive — a long one would need search and filtering to
    /// be useful, which is a different feature.
    static let limit = 20

    static func load() -> [AnsweredQuestion] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([AnsweredQuestion].self, from: data)) ?? []
    }

    static func persist(_ entries: [AnsweredQuestion]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    /// Newest first, capped. Pure, so the trimming is testable without touching defaults.
    static func appending(
        _ entry: AnsweredQuestion,
        to entries: [AnsweredQuestion],
        limit: Int = limit
    ) -> [AnsweredQuestion] {
        var next = entries
        next.insert(entry, at: 0)
        if next.count > limit { next.removeLast(next.count - limit) }
        return next
    }
}
