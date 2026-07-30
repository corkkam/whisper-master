import Foundation
import Security

/// One instance's secret material: the descriptor's field keys → the values the
/// user pasted (or an OAuth flow returned).
///
/// Deliberately a dictionary rather than a struct per provider: the descriptor
/// already declares the field set, so the credential is whatever those fields hold.
/// Refresh/mint metadata rides in the same bag under reserved keys.
struct ConnectorCredential: Codable, Equatable, Sendable {
    var values: [String: String]

    init(_ values: [String: String] = [:]) { self.values = values }

    subscript(key: String) -> String? {
        get { values[key] }
        set {
            if let newValue, !newValue.isEmpty { values[key] = newValue } else { values.removeValue(forKey: key) }
        }
    }

    var isEmpty: Bool { values.isEmpty }

    // MARK: - Reserved keys (refreshable grants / minted tokens)

    static let accessTokenKey = "access_token"
    static let refreshTokenKey = "refresh_token"
    /// Absolute expiry as epoch seconds, stored as a string so the bag stays
    /// homogeneous.
    static let expiresAtKey = "expires_at"

    var accessToken: String? { values[Self.accessTokenKey] }
    var refreshToken: String? { values[Self.refreshTokenKey] }

    var expiresAt: Date? {
        guard let raw = values[Self.expiresAtKey], let seconds = Double(raw) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// True when a refreshable grant needs renewing. A 60 s skew means we refresh
    /// just *before* the provider would start rejecting us rather than after a user
    /// has already seen a failure.
    func isExpired(now: Date = Date(), skew: TimeInterval = 60) -> Bool {
        guard let expiresAt else { return false }
        return now.addingTimeInterval(skew) >= expiresAt
    }
}

/// Keychain-backed secret storage for connector instances, keyed by instance id.
///
/// Every method is a no-op-and-report rather than a throw: a connector whose
/// credential can't be read is a `.credentialInvalid` state on the instance row, not
/// an app-level error. Instances with `authKind == .none` (EventKit) never call in
/// here at all — "no credential" is a real case, not an empty blob.
enum ConnectorCredentials {
    /// One Keychain service for all connector secrets; the instance UUID is the
    /// account. Distinct per bundle id, so the Dev/Beta builds keep their own.
    private static var service: String {
        (Bundle.main.bundleIdentifier ?? "app.whispermaster.mac") + ".connector"
    }

    /// When false, nothing touches the real Keychain — used by the headless
    /// snapshot renderer and by tests, so seeding mock instances can't prompt for
    /// keychain access or leave residue on a developer's login keychain.
    /// Reads fall back to an in-memory store.
    nonisolated(unsafe) static var persistenceEnabled = true
    nonisolated(unsafe) private static var memory: [UUID: ConnectorCredential] = [:]

    // MARK: - API

    static func save(_ credential: ConnectorCredential, for id: UUID) -> Bool {
        guard persistenceEnabled else { memory[id] = credential; return true }
        guard let data = try? JSONEncoder().encode(credential) else { return false }
        // Delete-then-add rather than SecItemUpdate: an update against a missing
        // item fails, and we'd have to probe first anyway.
        SecItemDelete(baseQuery(id) as CFDictionary)
        var attributes = baseQuery(id)
        attributes[kSecValueData as String] = data
        // The app is not sandboxed and runs as a menu-bar agent, so the secret must
        // be readable without an unlock prompt once the user has logged in.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    static func load(for id: UUID) -> ConnectorCredential? {
        guard persistenceEnabled else { return memory[id] }
        var query = baseQuery(id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return try? JSONDecoder().decode(ConnectorCredential.self, from: data)
    }

    @discardableResult
    static func delete(for id: UUID) -> Bool {
        guard persistenceEnabled else { memory.removeValue(forKey: id); return true }
        let status = SecItemDelete(baseQuery(id) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Whether a secret exists at all — used by the UI to distinguish "never
    /// connected" from "connected but rejected", without reading the secret.
    static func exists(for id: UUID) -> Bool {
        guard persistenceEnabled else { return memory[id] != nil }
        var query = baseQuery(id)
        query[kSecReturnData as String] = false
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// Drop the in-memory store. Tests only; the real Keychain is untouched.
    static func resetMemoryStore() { memory.removeAll() }

    // MARK: - Internals

    private static func baseQuery(_ id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
    }
}
