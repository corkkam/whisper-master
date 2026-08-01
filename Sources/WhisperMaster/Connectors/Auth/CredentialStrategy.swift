import Foundation

/// Resolves an instance's stored credential into a usable bearer token, doing whatever
/// its `authKind` requires first.
///
/// This is the layer that exists because credentials come in genuinely different
/// shapes, not because "a token" needed wrapping:
///
/// - `.none` — nothing to resolve (EventKit).
/// - `.staticSecret` — hand back what the user pasted.
/// - `.refreshableGrant` — refresh in place when it's near expiry, then hand back.
/// - `.mintedToken` — exchange stored client credentials for a fresh short-lived token
///   on every use; nothing is ever cached to disk.
@MainActor
enum CredentialStrategy {
    /// A resolved token plus whether the stored credential changed (so the caller
    /// persists it once, rather than every read re-writing the Keychain).
    struct Resolved {
        let token: String
        let updatedCredential: ConnectorCredential?
    }

    enum ResolveError: Error, Equatable {
        case noCredential
        case notRefreshable
        case refreshFailed(String)
        case mintFailed(String)
    }

    static func resolve(for instance: ConnectorInstance) async throws -> Resolved {
        let descriptor = instance.descriptor
        // The *instance's* auth kind, not the descriptor's: one kind can carry both
        // a credential-less EventKit instance and a signed-in API one. See
        // `ConnectorInstance.authKind`.
        switch instance.authKind {
        case .none:
            return Resolved(token: "", updatedCredential: nil)

        case .staticSecret:
            guard let credential = ConnectorCredentials.load(for: instance.id),
                  let token = staticToken(from: credential, descriptor: descriptor)
            else { throw ResolveError.noCredential }
            return Resolved(token: token, updatedCredential: nil)

        case .refreshableGrant:
            guard let credential = ConnectorCredentials.load(for: instance.id) else {
                throw ResolveError.noCredential
            }
            guard credential.isExpired() else {
                guard let token = credential.accessToken else { throw ResolveError.noCredential }
                return Resolved(token: token, updatedCredential: nil)
            }
            guard let refreshToken = credential.refreshToken else {
                // Expired with nothing to refresh from — the user must reconnect. This
                // is `.tokenExpired` on the instance row, not a silent empty read.
                throw ResolveError.notRefreshable
            }
            do {
                let response = try await OAuthPKCEFlow.refresh(refreshToken: refreshToken)
                let updated = response.merged(into: credential)
                return Resolved(token: response.accessToken, updatedCredential: updated)
            } catch {
                throw ResolveError.refreshFailed(String(describing: error))
            }

        case .mintedToken:
            guard let credential = ConnectorCredentials.load(for: instance.id) else {
                throw ResolveError.noCredential
            }
            let token = try await mintZoomToken(credential)
            // Deliberately not persisted: a 1-hour token on disk is a liability with no
            // upside, since minting is one cheap request.
            return Resolved(token: token, updatedCredential: nil)
        }
    }

    /// Map a resolve failure onto the instance error state the UI renders.
    static func connectorError(for error: Error) -> ConnectorError {
        switch error {
        case ResolveError.noCredential: return .credentialInvalid
        case ResolveError.notRefreshable, ResolveError.refreshFailed: return .tokenExpired
        case ResolveError.mintFailed: return .credentialInvalid
        default: return .credentialInvalid
        }
    }

    /// The first non-empty secret field the descriptor declares — so a new
    /// manual-token connector needs no code here, just its descriptor.
    private static func staticToken(from credential: ConnectorCredential,
                                   descriptor: ConnectorDescriptor) -> String? {
        for field in descriptor.fields where field.isSecret {
            if let value = credential[field.key], !value.isEmpty { return value }
        }
        return credential.accessToken
    }

    /// Zoom server-to-server OAuth: account credentials → a fresh ~1 h token.
    private static func mintZoomToken(_ credential: ConnectorCredential) async throws -> String {
        guard let accountID = credential["account_id"],
              let clientID = credential["client_id"],
              let clientSecret = credential["client_secret"]
        else { throw ResolveError.noCredential }

        var components = URLComponents(string: "https://zoom.us/oauth/token")!
        components.queryItems = [
            .init(name: "grant_type", value: "account_credentials"),
            .init(name: "account_id", value: accountID),
        ]
        guard let url = components.url else { throw ResolveError.mintFailed("bad URL") }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        // Zoom is the one provider here that authenticates the *mint* call with Basic
        // client credentials; the minted token is then a normal bearer.
        let basic = Data("\(clientID):\(clientSecret)".utf8).base64EncodedString()
        request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let parsed = OAuthTokenResponse.parse(data)
        else {
            throw ResolveError.mintFailed(String(data: data, encoding: .utf8) ?? "mint failed")
        }
        return parsed.accessToken
    }
}
