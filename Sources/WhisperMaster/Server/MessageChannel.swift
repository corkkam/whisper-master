import Foundation
import Network

// MARK: - MessageChannel
//
// Length-prefixed message framing over a single `NWConnection`. TCP is a byte
// stream, so every logical message is delimited explicitly.
//
// Frame layout:
//   [1 byte  : MessageKind]
//   [4 bytes : UInt32 payload length, big-endian]
//   [N bytes : payload]
//
// IMPORTANT: keep this file byte-identical with its copy in the iOS repo.
//
// Sends are expected to come from a single logical sequence (the server funnels
// all outbound messages through one task); reads happen on a separate loop.
// The two directions are independent, so concurrent send/receive is fine.

final class MessageChannel: @unchecked Sendable {
    enum ChannelError: Error {
        case connectionClosed
        case malformedFrame
    }

    private let connection: NWConnection

    init(connection: NWConnection) {
        self.connection = connection
    }

    // MARK: Sending

    func send(kind: MessageKind, payload: Data) async throws {
        var frame = Data(capacity: payload.count + 5)
        frame.append(kind.rawValue)
        let length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: length) { frame.append(contentsOf: $0) }
        frame.append(payload)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: frame, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    func send(control: ServerControl) async throws {
        try await send(kind: .control, payload: try control.encoded())
    }

    func send(control: ClientControl) async throws {
        try await send(kind: .control, payload: try control.encoded())
    }

    func sendAudio(_ pcm: Data) async throws {
        try await send(kind: .audio, payload: pcm)
    }

    // MARK: Receiving

    /// Reads exactly one framed message. Throws `connectionClosed` on EOF.
    func receiveFrame() async throws -> (kind: MessageKind, payload: Data) {
        let header = try await receiveExactly(5)
        guard let kind = MessageKind(rawValue: header[0]) else {
            throw ChannelError.malformedFrame
        }
        let length =
            (UInt32(header[1]) << 24)
            | (UInt32(header[2]) << 16)
            | (UInt32(header[3]) << 8)
            | UInt32(header[4])
        let payload = length == 0 ? Data() : Data(try await receiveExactly(Int(length)))
        return (kind, payload)
    }

    /// Blocks until exactly `count` bytes have been read, reassembling across
    /// partial TCP reads.
    private func receiveExactly(_ count: Int) async throws -> [UInt8] {
        guard count > 0 else { return [] }
        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) {
                data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, data.count == count {
                    continuation.resume(returning: [UInt8](data))
                } else if isComplete {
                    continuation.resume(throwing: ChannelError.connectionClosed)
                } else {
                    continuation.resume(throwing: ChannelError.malformedFrame)
                }
            }
        }
    }
}
