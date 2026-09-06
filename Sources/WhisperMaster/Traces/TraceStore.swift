import Foundation

/// The two trace lists, persisted and capped.
///
/// A store rather than two more arrays on `AppState`: the polish and the delivery of a
/// dictation both land *after* the trace is written, so this needs in-place updates
/// keyed by id (the shape `updateHistoryText` already has), and traces are the fourth
/// thing to want that. Written only by `DictationViewModel`, exactly like
/// `usageStore.record` — the one-writer rule is unchanged.
///
/// `load: false` (and an injected `defaults`) is how a test gets one that touches no
/// real preferences. The app's own instance loads at init, like `history` and
/// `answerLog` and unlike the per-account stores beside it — there is no account to
/// wait for, because a trace describes this machine rather than a person.
@MainActor
@Observable
final class TraceStore {
    /// Newest first, both lists.
    private(set) var dictation: [DictationTrace] = []
    private(set) var assistant: [AssistantTrace] = []

    /// Deliberately smaller than the 50-entry transcript history, and for the opposite
    /// reason: a trace is many times the size of the transcript it describes (raw text,
    /// every stage, the polish before *and* after), and this is a "what just happened"
    /// instrument, not an archive. Past a couple of dozen entries the answer to "why did
    /// it do that" is never further down the list.
    nonisolated static let limit = 40

    static let dictationDefaultsKey = "WhisperMaster.traces.dictation.v1"
    static let assistantDefaultsKey = "WhisperMaster.traces.assistant.v1"

    private let defaults: UserDefaults?

    init(load: Bool = true, defaults: UserDefaults? = .standard) {
        self.defaults = load ? defaults : nil
        guard load, let defaults else { return }
        dictation = Self.read(key: Self.dictationDefaultsKey, from: defaults)
        assistant = Self.read(key: Self.assistantDefaultsKey, from: defaults)
    }

    // MARK: - Recording

    func record(_ trace: DictationTrace) {
        dictation = Self.capped(trace, in: dictation)
        persistDictation()
    }

    func record(_ trace: AssistantTrace) {
        assistant = Self.capped(trace, in: assistant)
        persistAssistant()
    }

    /// Attach the polish verdict once it lands. No-op when the trace has aged out —
    /// a polish can arrive after 40 more dictations only in a pathological case, but
    /// it must not resurrect a dropped row.
    func attachPolish(_ id: UUID, _ polish: PolishTrace) {
        mutateDictation(id) { $0.polish = polish }
    }

    func attachDelivery(_ id: UUID, _ delivery: DeliveryTrace) {
        mutateDictation(id) { $0.delivery = delivery }
    }

    private func mutateDictation(_ id: UUID, _ change: (inout DictationTrace) -> Void) {
        guard let index = dictation.firstIndex(where: { $0.id == id }) else { return }
        var next = dictation
        change(&next[index])
        dictation = next
        persistDictation()
    }

    // MARK: - Clearing

    func clearDictation() {
        dictation = []
        persistDictation()
    }

    func clearAssistant() {
        assistant = []
        persistAssistant()
    }

    func deleteDictation(_ id: UUID) {
        dictation.removeAll { $0.id == id }
        persistDictation()
    }

    func deleteAssistant(_ id: UUID) {
        assistant.removeAll { $0.id == id }
        persistAssistant()
    }

    /// Fill both lists **without persisting** — the headless snapshot renderer's door
    /// in, and the only writer that isn't the view model. It runs inside a real app
    /// process, so a seed that went through `record` would overwrite a real user's
    /// traces with mock ones (the hazard `NotesStore.persistenceEnabled` and
    /// `SnapshotMode`'s direct `state.history` assignment both exist for).
    func seed(dictation: [DictationTrace] = [], assistant: [AssistantTrace] = []) {
        self.dictation = dictation
        self.assistant = assistant
    }

    // MARK: - Pure helpers

    /// Newest first, capped. Pure, so the trimming is testable without defaults.
    nonisolated static func capped<T>(_ entry: T, in entries: [T], limit: Int = limit) -> [T] {
        var next = entries
        next.insert(entry, at: 0)
        if next.count > limit { next.removeLast(next.count - limit) }
        return next
    }

    // MARK: - Persistence

    private func persistDictation() {
        Self.write(dictation, key: Self.dictationDefaultsKey, to: defaults)
    }

    private func persistAssistant() {
        Self.write(assistant, key: Self.assistantDefaultsKey, to: defaults)
    }

    /// A failed decode reads as an empty list rather than throwing — see
    /// `DictationTrace`'s note on why that trade is right *here* and wrong for `Note`.
    private static func read<T: Decodable>(key: String, from defaults: UserDefaults) -> [T] {
        guard let data = defaults.data(forKey: key) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([T].self, from: data)) ?? []
    }

    private static func write<T: Encodable>(_ value: T, key: String, to defaults: UserDefaults?) {
        guard let defaults else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return }
        defaults.set(data, forKey: key)
    }
}
