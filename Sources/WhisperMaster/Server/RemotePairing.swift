import CryptoKit
import Foundation
import Network
import Security

// MARK: - RemotePairing
//
// The shared secret that authenticates and encrypts every connection to this
// Mac's transcription service.
//
// WHY THIS EXISTS
// The server used to accept any inbound TCP connection on a fixed port and hand
// it a full transcription session — no pairing, no credential, no transport
// security. Two consequences:
//
//   1. Anyone who could reach port 47823 (same café Wi-Fi, same office LAN, or
//      anywhere on the tailnet) could open a session and use this Mac's models.
//   2. The stream was plaintext TCP, so a passive observer on the path could
//      reconstruct the dictated audio and read back the transcripts — which is
//      squarely at odds with "your voice never leaves your Mac".
//
// Both are fixed by a single mechanism: TLS with a pre-shared key. PSK-TLS gives
// authentication *and* encryption in one handshake, with no certificate
// authority to run — a peer that doesn't hold the key cannot complete the
// handshake, so unauthorised clients are rejected by the TLS stack before any
// app code sees a frame.
//
// The key is 256 bits from the system CSPRNG, generated once and kept in the
// Keychain. It reaches the phone through the pairing QR code, which is shown
// only in Settings on an already-unlocked Mac.
//
// COMPATIBILITY: this changes the wire protocol. The iOS client must adopt the
// same PSK handshake (read the key from the QR payload, pass it as the TLS PSK)
// or it will no longer connect. See `Docs` note in CLAUDE.md.
enum RemotePairing {
    /// Keychain service for the pairing key. Distinct per bundle id so Dev/Beta
    /// builds keep their own key and can't cross-connect with the release app.
    private static var service: String {
        (Bundle.main.bundleIdentifier ?? "app.whispermaster.mac") + ".remotePairing"
    }

    private static let account = "psk.v1"

    /// PSK identity hint sent alongside the key. Not a secret — it just labels
    /// which key is in play, so a future rotation can be negotiated.
    static let identity = "whispermaster.psk.v1"

    /// Test seam: when false the key lives in memory only, so unit tests and the
    /// headless snapshot renderer never touch the login keychain.
    nonisolated(unsafe) static var persistenceEnabled = true
    nonisolated(unsafe) private static var memoryKey: Data?

    // MARK: - Key material

    /// The pairing key, generating and persisting one on first use.
    ///
    /// Returns nil only if the Keychain refuses both the read and the write, in
    /// which case the caller must refuse to start the listener — running without
    /// a key would mean running unauthenticated, which is the bug this fixes.
    static func key() -> Data? {
        if let existing = load() { return existing }
        var fresh = Data(count: 32)
        let status = fresh.withUnsafeMutableBytes { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return errSecAllocate }
            return SecRandomCopyBytes(kSecRandomDefault, buffer.count, base)
        }
        guard status == errSecSuccess else { return nil }
        guard save(fresh) else { return nil }
        return fresh
    }

    /// Discard the current key and mint a new one. Every previously paired
    /// device stops connecting until it is re-paired — which is the point: this
    /// is the "revoke access" control.
    @discardableResult
    static func rotate() -> Data? {
        delete()
        return key()
    }

    /// The key in the compact form the QR code and Settings display use.
    /// URL-safe base64 with no padding, so it survives a query string intact.
    static func keyToken() -> String? {
        key().map(base64URLEncode)
    }

    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64URLDecode(_ token: String) -> Data? {
        var s = token
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s.append("=") }
        return Data(base64Encoded: s)
    }

    // MARK: - TLS parameters

    /// `NWParameters` for a PSK-authenticated, encrypted TCP connection.
    ///
    /// Both ends build these the same way; the handshake fails unless both hold
    /// the identical key, so this is simultaneously the encryption and the
    /// authentication. Returns nil when no key is available.
    static func tlsParameters(key: Data? = RemotePairing.key()) -> NWParameters? {
        guard let key, !key.isEmpty else { return nil }

        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions

        // TLS 1.2 is the floor; 1.3 is negotiated when both ends support it.
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)

        let keyData = key.withUnsafeBytes { DispatchData(bytes: $0) }
        let identityData = Data(identity.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(
            sec,
            keyData as __DispatchData,
            identityData as __DispatchData
        )
        // A PSK handshake needs an explicitly offered PSK ciphersuite.
        sec_protocol_options_append_tls_ciphersuite(
            sec,
            tls_ciphersuite_t(rawValue: TLS_PSK_WITH_AES_128_GCM_SHA256)!
        )

        let params = NWParameters(tls: tls)
        // The server binds a fixed port and may restart quickly (app relaunch);
        // without this the rebind fails while the old socket lingers.
        if let tcp = params.defaultProtocolStack.internetProtocol as? NWProtocolTCP.Options {
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 30
        }
        params.allowLocalEndpointReuse = true
        return params
    }

    // MARK: - Keychain

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func load() -> Data? {
        guard persistenceEnabled else { return memoryKey }
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, !data.isEmpty
        else { return nil }
        return data
    }

    private static func save(_ data: Data) -> Bool {
        guard persistenceEnabled else { memoryKey = data; return true }
        SecItemDelete(baseQuery() as CFDictionary)
        var attributes = baseQuery()
        attributes[kSecValueData as String] = data
        // Menu-bar agent: must be readable after login without an unlock prompt.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    private static func delete() -> Bool {
        guard persistenceEnabled else { memoryKey = nil; return true }
        let status = SecItemDelete(baseQuery() as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Tests only.
    static func resetMemoryStore() { memoryKey = nil }
}
