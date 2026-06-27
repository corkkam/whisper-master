import Foundation
import Observation

enum RecordingPhase: Equatable {
    case idle
    case preparingModels
    case recording
    case stopping
    case failed(String)
}

struct ModelDownloadSnapshot: Equatable {
    let fractionCompleted: Double
    let detail: String
}

struct TranscriptSnapshot: Equatable {
    var latestPartial: String = ""
    var latestConfirmed: String = ""
    var finalText: String = ""
}

struct TranscriptHistoryEntry: Identifiable, Equatable, Codable {
    let id: UUID
    let text: String
    let createdAt: Date
    let engineRawValue: String

    init(id: UUID = UUID(), text: String, createdAt: Date = Date(), engineRawValue: String) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.engineRawValue = engineRawValue
    }

    var preview: String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = 64
        if trimmed.count <= limit { return trimmed }
        let idx = trimmed.index(trimmed.startIndex, offsetBy: limit)
        return String(trimmed[..<idx]) + "…"
    }
}

@MainActor
@Observable
final class AppState {
    static let historyDefaultsKey = "WhisperMaster.transcriptHistory.v1"
    static let historyLimit = 50
    static let vocabularyDefaultsKey = "WhisperMaster.customVocabulary.v1"

    var selectedEngine: TranscriberEngine = .slidingWindow
    var preparedEngine: TranscriberEngine?
    var preparingEngine: TranscriberEngine?
    var hotkey: HotkeyManager.HotkeyOption = .rightOption
    var holdToTalkEnabled: Bool = true
    var autoPasteEnabled: Bool = true
    var soundEnabled: Bool = true
    var hidePillWhenIdle: Bool = true
    var phase: RecordingPhase = .idle
    var download: ModelDownloadSnapshot?
    var transcript = TranscriptSnapshot()
    var statusMessage: String = "Getting voice engine ready..."
    var audioLevel: Float = 0
    var history: [TranscriptHistoryEntry] = []
    /// User-maintained terms to bias decoding toward (proper nouns, jargon
    /// like "RAG"). Persisted; applied on each recording.
    var customVocabulary: [String] = [] {
        didSet { Self.persistVocabulary(customVocabulary) }
    }

    /// The device mesh: this Mac plus other Macs running Whisper Master on the
    /// network. Written by `MeshCoordinator`; observed by the mesh settings panel.
    var meshPeers: [MeshPeer] = []

    init() {
        history = Self.loadHistory()
        customVocabulary = Self.loadVocabulary()
    }

    var canStart: Bool {
        switch phase {
        case .idle, .failed:
            return preparingEngine == nil
        case .preparingModels, .recording, .stopping:
            return false
        }
    }

    var canStop: Bool {
        phase == .recording
    }

    func resetTranscript() {
        transcript = TranscriptSnapshot()
    }

    func appendHistory(text: String, engine: TranscriberEngine) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        let entry = TranscriptHistoryEntry(text: cleaned, engineRawValue: engine.rawValue)
        var next = history
        next.insert(entry, at: 0)
        if next.count > Self.historyLimit {
            next.removeLast(next.count - Self.historyLimit)
        }
        history = next
        Self.persistHistory(next)
    }

    func clearHistory() {
        history = []
        Self.persistHistory([])
    }

    func removeHistoryEntry(_ id: UUID) {
        history.removeAll { $0.id == id }
        Self.persistHistory(history)
    }

    private static func loadHistory() -> [TranscriptHistoryEntry] {
        guard let data = UserDefaults.standard.data(forKey: historyDefaultsKey) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([TranscriptHistoryEntry].self, from: data)) ?? []
    }

    private static func persistHistory(_ entries: [TranscriptHistoryEntry]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: historyDefaultsKey)
    }

    private static func loadVocabulary() -> [String] {
        UserDefaults.standard.stringArray(forKey: vocabularyDefaultsKey) ?? []
    }

    private static func persistVocabulary(_ terms: [String]) {
        UserDefaults.standard.set(terms, forKey: vocabularyDefaultsKey)
    }
}
