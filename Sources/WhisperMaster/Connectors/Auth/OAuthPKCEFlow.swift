import AuthenticationServices
import CryptoKit
import Foundation

/// PKCE (RFC 7636) parameters for one authorization attempt.
///
/// Pure and separately testable — the crypto is where a subtle mistake silently
/// downgrades the flow's security, and it needs no network to verify.
struct PKCEChallenge: Equatable, Sendable {
    let verifier: String
    let challenge: String
    let method = "S256"

    /// A fresh verifier: 43–128 chars from the unreserved set. 32 random bytes
    /// base64url-encoded lands at 43, the minimum the RFC allows and what Google's own
    /// samples use.
    init(verifier: String = PKCEChallenge.randomVerifier()) {
        self.verifier = verifier
        self.challenge = Self.s256(verifier)
    }

    static func randomVerifier(byteCount: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return base64URL(Data(bytes))
    }

    /// `BASE64URL(SHA256(verifier))`, unpadded — a padded or standard-base64 challenge
    /// is rejected by the provider with an opaque `invalid_grant`.
    static func s256(_ verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// What a token endpoint returned.
struct OAuthTokenResponse: Equatable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date?
    let scope: String?

    /// Fold into the credential bag, **preserving an existing refresh token** when the
    /// response omits one. Google returns `refresh_token` only on the first consent, so
    /// a naive overwrite on refresh would erase it and force a re-sign-in later.
    func merged(into existing: ConnectorCredential) -> ConnectorCredential {
        var credential = existing
        credential[ConnectorCredential.accessTokenKey] = accessToken
        if let refreshToken { credential[ConnectorCredential.refreshTokenKey] = refreshToken }
        if let expiresAt {
            credential[ConnectorCredential.expiresAtKey] = String(expiresAt.timeIntervalSince1970)
        }
        if let scope { credential["scope"] = scope }
        return credential
    }

    /// Parse a token response body. `expires_in` is seconds-from-now, so it's resolved
    /// against `now` here rather than stored relative.
    static func parse(_ data: Data, now: Date = Date()) -> OAuthTokenResponse? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String, !accessToken.isEmpty
        else { return nil }
        let expiresIn = (json["expires_in"] as? Double) ?? (json["expires_in"] as? Int).map(Double.init)
        return OAuthTokenResponse(
            accessToken: accessToken,
            refreshToken: json["refresh_token"] as? String,
            expiresAt: expiresIn.map { now.addingTimeInterval($0) },
            scope: json["scope"] as? String)
    }
}

enum OAuthFlowError: Error, Equatable {
    case notConfigured
    case userCancelled
    case noAuthorizationCode
    case stateMismatch
    case tokenExchangeFailed(String)
}

/// The desktop authorization-code + PKCE flow (RFC 8252), via
/// `ASWebAuthenticationSession` and a custom-scheme redirect.
///
/// No client secret is used or shipped — that's only possible because the Google
/// client is an **iOS-type** client (see `GoogleOAuthConfig`).
@MainActor
final class OAuthPKCEFlow: NSObject {
    private var session: ASWebAuthenticationSession?

    /// Run the full flow and return the tokens.
    ///
    /// - Parameter forceAccountPicker: send `prompt=select_account consent`.
    ///   **Essential for this feature**: without it Google silently reuses the
    ///   already-signed-in account, so a user trying to add "Google Calendar Work"
    ///   after "Personal" would get a second copy of Personal and never understand why.
    func authorize(scopes: [String],
                   forceAccountPicker: Bool = true) async throws -> OAuthTokenResponse {
        guard let clientID = GoogleOAuthConfig.clientID,
              let redirectURI = GoogleOAuthConfig.redirectURI,
              let redirectScheme = GoogleOAuthConfig.redirectScheme
        else { throw OAuthFlowError.notConfigured }

        let pkce = PKCEChallenge()
        let state = PKCEChallenge.randomVerifier(byteCount: 16)

        var components = URLComponents(url: GoogleOAuthConfig.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        var query: [URLQueryItem] = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: scopes.joined(separator: " ")),
            .init(name: "code_challenge", value: pkce.challenge),
            .init(name: "code_challenge_method", value: pkce.method),
            .init(name: "state", value: state),
            // Without offline access there's no refresh token, and the connection
            // would quietly die an hour after it was made.
            .init(name: "access_type", value: "offline"),
        ]
        if forceAccountPicker {
            query.append(.init(name: "prompt", value: "select_account consent"))
        }
        components.queryItems = query
        guard let authURL = components.url else { throw OAuthFlowError.notConfigured }

        let callback = try await present(authURL: authURL, scheme: redirectScheme)

        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        // Verify state before touching the code — an unmatched state means this
        // callback isn't ours.
        guard items.first(where: { $0.name == "state" })?.value == state else {
            throw OAuthFlowError.stateMismatch
        }
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw OAuthFlowError.noAuthorizationCode
        }

        return try await exchange(code: code, verifier: pkce.verifier,
                                 clientID: clientID, redirectURI: redirectURI)
    }

    /// Swap a refresh token for a fresh access token. Called by `CredentialStrategy`
    /// just before an expiring credential is used.
    static func refresh(refreshToken: String) async throws -> OAuthTokenResponse {
        guard let clientID = GoogleOAuthConfig.clientID else { throw OAuthFlowError.notConfigured }
        return try await post(form: [
            "client_id": clientID,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ])
    }

    // MARK: - Internals

    private func present(authURL: URL, scheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: authURL, callbackURLScheme: scheme
            ) { callback, error in
                if let callback {
                    continuation.resume(returning: callback)
                } else if let error = error as? ASWebAuthenticationSessionError,
                          error.code == .canceledLogin {
                    continuation.resume(throwing: OAuthFlowError.userCancelled)
                } else {
                    continuation.resume(throwing: error ?? OAuthFlowError.userCancelled)
                }
            }
            session.presentationContextProvider = self
            // A fresh session per attempt: reusing the shared web credential would let
            // Google skip the account picker, defeating `forceAccountPicker`.
            session.prefersEphemeralWebBrowserSession = true
            self.session = session
            session.start()
        }
    }

    private func exchange(code: String, verifier: String,
                          clientID: String, redirectURI: String) async throws -> OAuthTokenResponse {
        try await Self.post(form: [
            "client_id": clientID,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI,
        ])
    }

    private static func post(form: [String: String]) async throws -> OAuthTokenResponse {
        var request = URLRequest(url: GoogleOAuthConfig.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.encodeForm(form)
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            // Surface the provider's own error text — "invalid_grant" vs
            // "redirect_uri_mismatch" are completely different setup mistakes.
            let body = String(data: data, encoding: .utf8) ?? "no response body"
            throw OAuthFlowError.tokenExchangeFailed(body)
        }
        guard let parsed = OAuthTokenResponse.parse(data) else {
            throw OAuthFlowError.tokenExchangeFailed("token response had no access_token")
        }
        return parsed
    }

    /// Form-encode with a strict allowed set. `+` and `/` appear in real tokens and
    /// must be escaped, which `.urlQueryAllowed` would let through (and a `+` decodes
    /// server-side as a space, corrupting the token).
    ///
    /// `nonisolated` because it's pure — no reason to require the main actor to encode a
    /// dictionary, and it keeps the function directly testable.
    nonisolated static func encodeForm(_ form: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = form
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
        return Data(body.utf8)
    }
}

extension OAuthPKCEFlow: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // A menu-bar app often has no key window; any visible window will anchor the
        // sheet, and nil is a valid anchor that falls back to a standalone window.
        NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first { $0.isVisible } ?? ASPresentationAnchor()
    }
}
