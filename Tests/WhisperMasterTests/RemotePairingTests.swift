import Network
import Security
import XCTest
@testable import WhisperMaster

/// Covers the controls that closed the open-listener hole: a pairing key must
/// exist and round-trip through the QR encoding, and the frame reader must
/// refuse an oversized declared length.
final class RemotePairingTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // Never touch the developer's login keychain.
        RemotePairing.persistenceEnabled = false
        RemotePairing.resetMemoryStore()
    }

    override func tearDown() {
        RemotePairing.resetMemoryStore()
        RemotePairing.persistenceEnabled = true
        super.tearDown()
    }

    // MARK: - Key material

    func testKeyIs256BitsAndStable() {
        guard let first = RemotePairing.key() else { return XCTFail("no key generated") }
        XCTAssertEqual(first.count, 32, "pairing key must be 256 bits")
        XCTAssertEqual(RemotePairing.key(), first, "key must be stable across reads")
    }

    func testKeyIsNotAllZeros() {
        guard let key = RemotePairing.key() else { return XCTFail("no key generated") }
        XCTAssertFalse(key.allSatisfy { $0 == 0 }, "a zero key would mean the CSPRNG never ran")
    }

    func testRotateReplacesTheKey() {
        guard let before = RemotePairing.key() else { return XCTFail("no key generated") }
        guard let after = RemotePairing.rotate() else { return XCTFail("rotate produced no key") }
        XCTAssertNotEqual(before, after, "rotate must invalidate every paired device")
        XCTAssertEqual(after.count, 32)
    }

    // MARK: - QR token encoding

    func testBase64URLRoundTrips() {
        // Include bytes that produce '+' and '/' in standard base64, so the
        // URL-safe substitution is actually exercised.
        let raw = Data([0xFB, 0xFF, 0xBE, 0x00, 0x01, 0x7F, 0x80, 0xAA])
        let token = RemotePairing.base64URLEncode(raw)
        XCTAssertFalse(token.contains("+"))
        XCTAssertFalse(token.contains("/"))
        XCTAssertFalse(token.contains("="), "padding would need escaping in a query string")
        XCTAssertEqual(RemotePairing.base64URLDecode(token), raw)
    }

    func testKeyTokenDecodesBackToTheKey() {
        guard let key = RemotePairing.key(), let token = RemotePairing.keyToken() else {
            return XCTFail("no key/token")
        }
        XCTAssertEqual(RemotePairing.base64URLDecode(token), key)
    }

    func testBase64URLDecodeRejectsGarbage() {
        XCTAssertNil(RemotePairing.base64URLDecode("not valid base64 !!!"))
    }

    // MARK: - Pairing URL

    func testPairingURLCarriesKeyAndAddress() {
        let endpoint = TailscaleEndpoint(host: "mac.tailnet.ts.net", port: 47823)
        guard let url = endpoint.pairingURL else { return XCTFail("no pairing URL") }
        guard let components = URLComponents(string: url) else { return XCTFail("unparseable URL") }

        XCTAssertEqual(components.scheme, "whispermaster")
        XCTAssertEqual(components.host, "pair")

        let items = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["host"], "mac.tailnet.ts.net")
        XCTAssertEqual(items["port"], "47823")
        XCTAssertEqual(items["i"], RemotePairing.identity)
        // The key is what makes the QR a pairing act rather than just an address.
        XCTAssertEqual(RemotePairing.base64URLDecode(items["k"] ?? ""), RemotePairing.key())
    }

    // MARK: - TLS parameters

    func testTLSParametersRequireAKey() {
        XCTAssertNil(
            RemotePairing.tlsParameters(key: nil),
            "without a key we must refuse to build parameters, so the listener refuses to start")
        XCTAssertNil(RemotePairing.tlsParameters(key: Data()), "an empty key is not a key")
        XCTAssertNotNil(RemotePairing.tlsParameters(key: Data(repeating: 7, count: 32)))
    }

    /// Two Macs must land on the forward-secret suite, the shipped iOS client
    /// (plain PSK only) must still connect, and a wrong key must not.
    func testHandshakeNegotiatesForwardSecrecyAndRejectsAWrongKey() throws {
        let key = Data(repeating: 7, count: 32)
        let ecdhePSK = UInt16(TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256)
        let plainPSK = UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256)

        let mac = try handshake(client: XCTUnwrap(RemotePairing.tlsParameters(key: key)), serverKey: key)
        XCTAssertEqual(mac, ecdhePSK)

        let legacy = try handshake(client: Self.parameters(key: key, suites: [plainPSK]), serverKey: key)
        XCTAssertEqual(legacy, plainPSK)

        let wrongKey = try handshake(
            client: XCTUnwrap(RemotePairing.tlsParameters(key: Data(repeating: 9, count: 32))),
            serverKey: key)
        XCTAssertNil(wrongKey)
    }

    /// A client built the way the shipped iOS app builds it.
    private static func parameters(key: Data, suites: [UInt16]) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
        sec_protocol_options_add_pre_shared_key(
            sec,
            key.withUnsafeBytes { DispatchData(bytes: $0) } as __DispatchData,
            Data(RemotePairing.identity.utf8).withUnsafeBytes { DispatchData(bytes: $0) } as __DispatchData)
        for suite in suites {
            sec_protocol_options_append_tls_ciphersuite(sec, tls_ciphersuite_t(rawValue: suite)!)
        }
        return NWParameters(tls: tls)
    }

    /// Runs one loopback handshake against a server built by `tlsParameters`.
    /// Returns the negotiated ciphersuite, or nil if the handshake failed.
    private func handshake(client: NWParameters, serverKey: Data) throws -> UInt16? {
        let server = try XCTUnwrap(RemotePairing.tlsParameters(key: serverKey))
        let queue = DispatchQueue(label: "RemotePairingTests.handshake")
        let listener = try NWListener(using: server, on: .any)
        defer { listener.cancel() }
        listener.newConnectionHandler = { $0.start(queue: queue) }

        let done = expectation(description: "handshake settled")
        var negotiated: UInt16?
        var connection: NWConnection?
        listener.stateUpdateHandler = { state in
            guard case .ready = state, let port = listener.port else { return }
            let conn = NWConnection(host: "127.0.0.1", port: port, using: client)
            connection = conn
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let metadata = conn.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata
                    negotiated = metadata.map {
                        sec_protocol_metadata_get_negotiated_tls_ciphersuite($0.securityProtocolMetadata).rawValue
                    }
                    done.fulfill()
                case .failed, .waiting:
                    done.fulfill()
                default:
                    break
                }
            }
            conn.start(queue: queue)
        }
        listener.start(queue: queue)
        wait(for: [done], timeout: 10)
        connection?.cancel()
        return negotiated
    }

    // MARK: - Frame bound

    func testFramePayloadCeilingIsBoundedWellBelowUInt32Max() {
        // The length prefix is a UInt32; the whole point of the cap is that a peer
        // cannot declare gigabytes and make us buffer them.
        XCTAssertLessThan(MessageChannel.maxFramePayloadBytes, Int(UInt32.max))
        XCTAssertEqual(MessageChannel.maxFramePayloadBytes, 4 * 1024 * 1024)
        // Generous for real traffic: 16 kHz mono Int16 is ~32 KB per second, so
        // the cap still admits a ~2-minute audio frame.
        let bytesPerSecond = Int(WireAudioFormat.sampleRate) * 2
        XCTAssertGreaterThan(MessageChannel.maxFramePayloadBytes, bytesPerSecond * 60)
    }

    func testServerAdvertisesABoundedSessionCap() {
        // The cap is now enforced in accept(), not merely advertised.
        XCTAssertGreaterThan(RemoteTranscriptionServer.maxConcurrentSessions, 0)
        XCTAssertLessThanOrEqual(RemoteTranscriptionServer.maxConcurrentSessions, 8)
    }
}
