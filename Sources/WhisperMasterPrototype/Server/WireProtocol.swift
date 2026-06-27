import Foundation

// MARK: - Wire protocol
//
// The contract between the Mac transcription server and the iOS client.
//
// IMPORTANT: keep this file byte-identical with its copy in the iOS repo
// (`whisper-master-ios`). The two processes only interoperate if both sides
// encode and decode the exact same shapes.

/// Bonjour / framing constants.
enum WireProtocol {
    /// Bonjour service type advertised by the Mac and browsed for by iOS.
    static let serviceType = "_whispermaster._tcp"
    /// Bonjour domain (the local Wi-Fi/LAN).
    static let serviceDomain = "local."
    /// TCP port is assigned dynamically by `NWListener`; clients resolve it
    /// through Bonjour, so no fixed port is baked in.
}

/// Audio format streamed by the client and expected by the server: the
/// transcriber resamples internally, but agreeing on 16 kHz mono Int16 keeps
/// the bytes on the wire small (~32 KB/s).
enum WireAudioFormat {
    static let sampleRate: Double = 16_000
    static let channelCount: UInt32 = 1
}

/// Frame kinds multiplexed over a single connection. Control frames carry
/// JSON; audio frames carry raw little-endian Int16 PCM (no base64 overhead).
enum MessageKind: UInt8 {
    case control = 0
    case audio = 1
}

// MARK: - Client → Server

/// Parameters the client sends when opening a dictation session.
struct SessionConfig: Codable, Sendable {
    var sampleRate: Double
    var channels: Int
    var vocabulary: [String]

    init(
        sampleRate: Double = WireAudioFormat.sampleRate,
        channels: Int = Int(WireAudioFormat.channelCount),
        vocabulary: [String] = []
    ) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.vocabulary = vocabulary
    }
}

/// Control messages from the iOS client to the Mac.
enum ClientControl: Codable, Sendable {
    case startSession(SessionConfig)
    case stopSession
    case cancelSession
}

// MARK: - Server → Client

/// Coarse server status, mirrored from the desktop app's preparation phases.
enum ServerState: Codable, Sendable {
    case preparingModels(fraction: Double, detail: String)
    case ready
    case recording
    case error(message: String)
}

/// Control messages from the Mac back to the iOS client.
enum ServerControl: Codable, Sendable {
    case state(ServerState)
    case transcript(partial: String, confirmed: String, isConfirmed: Bool)
    case finalTranscript(text: String)
}

// MARK: - JSON coding helpers

extension ClientControl {
    func encoded() throws -> Data { try JSONEncoder().encode(self) }
    static func decode(_ data: Data) throws -> ClientControl {
        try JSONDecoder().decode(ClientControl.self, from: data)
    }
}

extension ServerControl {
    func encoded() throws -> Data { try JSONEncoder().encode(self) }
    static func decode(_ data: Data) throws -> ServerControl {
        try JSONDecoder().decode(ServerControl.self, from: data)
    }
}
