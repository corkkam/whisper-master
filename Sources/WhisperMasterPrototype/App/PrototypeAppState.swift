import Foundation
import Observation

// MARK: - Phase

enum PrototypePhase: Equatable {
    case idle
    case preparingModels
    case recording
    case stopping
    case failed(String)
}

// MARK: - Output mode

enum OutputMode: String, CaseIterable, Identifiable, Codable {
    case auto          = "auto"
    case dictate       = "dictate"
    case createNote    = "createNote"
    case createReminder = "createReminder"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto:            return "Smart (Auto-detect)"
        case .dictate:         return "Type at cursor"
        case .createNote:      return "Create Note"
        case .createReminder:  return "Add Reminder"
        }
    }

    var systemImage: String {
        switch self {
        case .auto:            return "wand.and.stars"
        case .dictate:         return "keyboard"
        case .createNote:      return "note.text.badge.plus"
        case .createReminder:  return "bell.badge.plus"
        }
    }

    var shortName: String {
        switch self {
        case .auto:            return "Auto"
        case .dictate:         return "Dictate"
        case .createNote:      return "Note"
        case .createReminder:  return "Reminder"
        }
    }
}

// MARK: - Snapshot types

struct ModelDownloadSnapshot: Equatable {
    let fractionCompleted: Double
    let detail: String
}

struct TranscriptSnapshot: Equatable {
    var latestPartial: String = ""
    var latestConfirmed: String = ""
    var finalText: String = ""
}

// MARK: - History entry

struct TranscriptHistoryEntry: Identifiable, Equatable, Codable {
    let id: UUID
    let text: String
    let createdAt: Date
    let engineRawValue: String
    var outputModeRawValue: String

    init(
        id: UUID = UUID(),
        text: String,
        createdAt: Date = Date(),
        engineRawValue: String,
        outputModeRawValue: String = OutputMode.dictate.rawValue
    ) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.engineRawValue = engineRawValue
        self.outputModeRawValue = outputModeRawValue
    }

    var preview: String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = 64
        if trimmed.count <= limit { return trimmed }
        let idx = trimmed.index(trimmed.startIndex, offsetBy: limit)
        return String(trimmed[..<idx]) + "…"
    }
}

// MARK: - Log entry

struct LogEntry: Identifiable {
    let id: UUID
    let timestamp: Date
    let level: Level
    let category: Category
    let message: String

    enum Level: String {
        case info    = "info"
        case success = "success"
        case warning = "warning"
        case error   = "error"
    }

    enum Category: String {
        case recording    = "recording"
        case transcription = "transcription"
        case notes        = "notes"
        case reminders    = "reminders"
        case system       = "system"
    }

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        level: Level = .info,
        category: Category = .system,
        message: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.message = message
    }
}

// MARK: - State

@MainActor
@Observable
final class PrototypeAppState {
    static let historyDefaultsKey    = "WhisperMaster.transcriptHistory.v1"
    static let outputModeDefaultsKey = "WhisperMaster.outputMode"
    static let historyLimit  = 50
    static let logEntriesLimit = 500

    // Engine
    var selectedEngine: TranscriberEngine = .slidingWindow
    var preparedEngine: TranscriberEngine?
    var preparingEngine: TranscriberEngine?

    // Recording settings
    var hotkey: HotkeyManager.HotkeyOption = .rightOption
    var holdToTalkEnabled: Bool = true
    var autoPasteEnabled: Bool = true
    var soundEnabled: Bool = true
    var preferBuiltInMic: Bool = false
    var hidePillWhenIdle: Bool = true

    // Output mode (persisted)
    var outputMode: OutputMode = .auto {
        didSet {
            UserDefaults.standard.set(outputMode.rawValue, forKey: Self.outputModeDefaultsKey)
        }
    }

    // Recording state
    var phase: PrototypePhase = .idle
    var download: ModelDownloadSnapshot?
    var transcript = TranscriptSnapshot()
    var statusMessage: String = "Getting voice engine ready..."
    var audioLevel: Float = 0

    // History
    var history: [TranscriptHistoryEntry] = []

    // Logs (in-memory, newest first)
    private(set) var logEntries: [LogEntry] = []

    // File logger queue — shared static so it's safe to capture in nonisolated context
    private static let logFileQueue = DispatchQueue(label: "app.whispermaster.logfile", qos: .background)

    init() {
        history = Self.loadHistory()
        if let raw = UserDefaults.standard.string(forKey: Self.outputModeDefaultsKey),
           let mode = OutputMode(rawValue: raw) {
            outputMode = mode
        }
        log("Whisper Master started.", level: .info, category: .system)
    }

    // MARK: - Phase helpers

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

    // MARK: - History

    func appendHistory(text: String, engine: TranscriberEngine, outputMode: OutputMode) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        let entry = TranscriptHistoryEntry(
            text: cleaned,
            engineRawValue: engine.rawValue,
            outputModeRawValue: outputMode.rawValue
        )
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

    // MARK: - Logging

    func log(_ message: String, level: LogEntry.Level = .info, category: LogEntry.Category = .system) {
        let entry = LogEntry(level: level, category: category, message: message)
        logEntries.insert(entry, at: 0)
        if logEntries.count > Self.logEntriesLimit {
            logEntries.removeLast(logEntries.count - Self.logEntriesLimit)
        }
        let line = Self.formatLogLine(entry)
        Self.appendLogLine(line)
    }

    func clearLogs() {
        logEntries = []
    }

    nonisolated static var logFileURL: URL {
        let logsDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs/WhisperMaster", isDirectory: true)
        return logsDir.appendingPathComponent("whispermaster.log")
    }

    private static func formatLogLine(_ entry: LogEntry) -> String {
        let ts = isoFormatter.string(from: entry.timestamp)
        return "[\(ts)] [\(entry.level.rawValue.uppercased())] [\(entry.category.rawValue)] \(entry.message)\n"
    }

    private static func appendLogLine(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        logFileQueue.async {
            let url = Self.logFileURL
            let fm = FileManager.default
            let dir = url.deletingLastPathComponent()
            if !fm.fileExists(atPath: dir.path) {
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            if fm.fileExists(atPath: url.path) {
                if let handle = try? FileHandle(forWritingTo: url) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    try? handle.close()
                }
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
