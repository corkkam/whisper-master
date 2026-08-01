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
