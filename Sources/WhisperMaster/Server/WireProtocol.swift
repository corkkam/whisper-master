import Foundation

// MARK: - Wire protocol
//
// The contract between the Mac transcription server and the iOS client.
//
// IMPORTANT: keep the message shapes byte-identical with the copy in the iOS
// repo (`whisper-master-ios`) — the two processes only interoperate if both
// sides encode/decode the same shapes. `ping`/`pong` serve two callers: Macs use
// them for mesh latency probes, and the iOS client sends them as a liveness
// heartbeat to detect zombie connections (e.g. a dead Tailscale path that never
// reports a failure).
//
// ⚠️ BREAKING TRANSPORT CHANGE — the iOS client needs a matching update.
//
// The frame shapes below are unchanged, but they no longer travel over bare TCP.
// The connection is now TLS with a pre-shared key (see `RemotePairing`), because
// the old plaintext-and-unauthenticated socket let anyone who could reach the
// port use this Mac's models, and let anyone on the path read the audio and
// transcripts. An old client will fail the handshake and never reach these
// messages.
//
// To update iOS:
//   1. Parse the pairing QR's new `k` (URL-safe base64 256-bit key) and `i`
//      (identity hint) query items and store the key in the Keychain.
//   2. Build `NWParameters` exactly as `RemotePairing.tlsParameters` does —
//      `NWProtocolTLS.Options`, min TLS 1.2, `sec_protocol_options_add_pre_shared_key`
//      with that key + identity, and append the
//      `TLS_PSK_WITH_AES_128_GCM_SHA256` ciphersuite — then dial with those
//      instead of `.tcp`.
//   3. Mirror `MessageChannel.maxFramePayloadBytes` so both ends reject
//      oversized frames identically.
// Re-pair each device after a key rotation (Settings → Nearby Macs → Rotate).

/// Bonjour / framing constants.
enum WireProtocol {
    /// Bonjour service type advertised by the Mac and browsed for by iOS.
    static let serviceType = "_whispermaster._tcp"
    /// Bonjour domain (the local Wi-Fi/LAN).
    static let serviceDomain = "local."
    /// Fixed TCP port the server listens on. Bonjour advertises it for LAN
    /// clients, but the fixed value is what lets an off-LAN client (e.g. over
    /// Tailscale, where mDNS can't reach) dial the Mac directly at a known
    /// host:port. Must match the iOS copy.
    static let fixedPort: UInt16 = 47823
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
    /// Mesh latency probe (Mac-to-Mac only). The server answers with
    /// `.pong(nonce:)` immediately, without starting transcription.
    case ping(nonce: UInt32)
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
    /// Reply to a mesh `.ping` (Mac-to-Mac only).
    case pong(nonce: UInt32)
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
