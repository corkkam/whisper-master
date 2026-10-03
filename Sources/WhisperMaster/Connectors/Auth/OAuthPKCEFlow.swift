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
/// client is an **iOS-type** client (see `GoogleOAuthConfig`) and the Microsoft one a
/// public client (see `MicrosoftOAuthConfig`).
@MainActor
final class OAuthPKCEFlow: NSObject {
    private var session: ASWebAuthenticationSession?

    /// Which Google account an authorization is for.
    ///
    /// This is the difference between "connect an account" and "this Mac already holds
    /// a grant for sam@acme.com — ask that account for one more scope", and it changes
    /// three things at once (the prompt, `include_granted_scopes`, and whether the web
    /// session is ephemeral), which is why it's one value rather than three flags that
    /// can be set inconsistently.
    enum AccountChoice: Equatable, Sendable {
        /// Force the chooser. **Essential when adding an account**: without it Google
        /// silently reuses the already-signed-in one, so a user adding "Google Calendar
        /// Work" after "Personal" would get a second copy of Personal and never
        /// understand why.
        case chooseAccount
        /// Incremental authorization against an account already connected here: Google
        /// is asked only for the scopes this grant doesn't carry, and the consent screen
        /// names just those. `email` goes out as `login_hint`.
        case reuse(email: String)
    }

    /// Run the full flow and return the tokens.
    func authorize(scopes: [String],
                   account: AccountChoice = .chooseAccount) async throws -> OAuthTokenResponse {
        guard let clientID = GoogleOAuthConfig.clientID,
              let redirectURI = GoogleOAuthConfig.redirectURI,
              let redirectScheme = GoogleOAuthConfig.redirectScheme
        else { throw OAuthFlowError.notConfigured }

        let pkce = PKCEChallenge()
        let state = PKCEChallenge.randomVerifier(byteCount: 16)

        guard let authURL = Self.authorizationURL(
            clientID: clientID, redirectURI: redirectURI, scopes: scopes,
            challenge: pkce.challenge, method: pkce.method, state: state, account: account)
        else { throw OAuthFlowError.notConfigured }

        // A fresh session per attempt when adding an account: reusing the shared web
        // credential would let Google skip the picker, defeating `.chooseAccount`.
        //
        // Reusing a grant wants the opposite. An ephemeral session carries no Google
        // cookies, so `login_hint` would only *prefill* the address and the user
        // would still be made to sign in from scratch — which is precisely the work
        // reusing an existing grant exists to save.
        let callback = try await present(authURL: authURL, scheme: redirectScheme,
                                         ephemeral: account == .chooseAccount)
        let code = try Self.authorizationCode(from: callback, state: state)

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
        ], to: GoogleOAuthConfig.tokenEndpoint)
    }

    /// Refresh whichever issuer minted `credential`. The issuer rides in the credential
    /// bag (`MicrosoftOAuthConfig.CredentialKey`), so this needs no instance in hand.
    static func refresh(_ credential: ConnectorCredential,
                        refreshToken: String) async throws -> OAuthTokenResponse {
        guard credential.isMicrosoftGrant else { return try await refresh(refreshToken: refreshToken) }
        guard let clientID = MicrosoftOAuthConfig.clientID else { throw OAuthFlowError.notConfigured }
        let keys = MicrosoftOAuthConfig.CredentialKey.self
        let tenant = credential[keys.tenant].flatMap(MicrosoftOAuthConfig.Tenant.init(rawValue:)) ?? .common
        var form = [
            "client_id": clientID,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ]
        if let scope = credential[keys.requestedScope] { form["scope"] = scope }
        return try await post(form: form, to: MicrosoftOAuthConfig.tokenEndpoint(tenant))
    }

    /// The Microsoft half of `authorize`: same PKCE, same browser session, different
    /// issuer. The returned credential already carries the issuer, tenant and the
    /// scopes asked for, which is what `refresh(_:refreshToken:)` routes on.
    ///
    /// `loginHint` is the repair path's account pin. Microsoft has no incremental
    /// consent to reuse, so unlike Google it only prefills the picker.
    func authorizeMicrosoft(scopes: [String],
                            tenant: MicrosoftOAuthConfig.Tenant,
                            loginHint: String? = nil) async throws -> ConnectorCredential {
        guard let clientID = MicrosoftOAuthConfig.clientID else { throw OAuthFlowError.notConfigured }
        let redirectURI = MicrosoftOAuthConfig.redirectURI
        let pkce = PKCEChallenge()
        let state = PKCEChallenge.randomVerifier(byteCount: 16)
        guard let authURL = Self.microsoftAuthorizationURL(
            clientID: clientID, redirectURI: redirectURI, scopes: scopes, tenant: tenant,
            challenge: pkce.challenge, method: pkce.method, state: state, loginHint: loginHint)
        else { throw OAuthFlowError.notConfigured }

        // Ephemeral only when picking a fresh account, for the same reason as Google:
        // a shared session would let Microsoft sign the last account straight back in.
        let callback = try await present(authURL: authURL,
                                         scheme: MicrosoftOAuthConfig.redirectScheme,
                                         ephemeral: loginHint == nil)
        let code = try Self.authorizationCode(from: callback, state: state)
        let tokens = try await Self.post(form: [
            "client_id": clientID,
            "code": code,
            "code_verifier": pkce.verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI,
            "scope": scopes.joined(separator: " "),
        ], to: MicrosoftOAuthConfig.tokenEndpoint(tenant))

        let keys = MicrosoftOAuthConfig.CredentialKey.self
        var credential = tokens.merged(into: ConnectorCredential())
        credential[keys.issuer] = keys.microsoftIssuer
        credential[keys.tenant] = tenant.rawValue
        credential[keys.requestedScope] = scopes.joined(separator: " ")
        return credential
    }

    /// The Microsoft authorization URL. Pure for the same reason as the Google one:
    /// a missing `offline_access` or `prompt` fails as a grant that dies in an hour or
    /// a picker that silently reuses the wrong account, neither of which throws.
    nonisolated static func microsoftAuthorizationURL(clientID: String,
                                                      redirectURI: String,
                                                      scopes: [String],
                                                      tenant: MicrosoftOAuthConfig.Tenant,
                                                      challenge: String,
                                                      method: String,
                                                      state: String,
                                                      loginHint: String?) -> URL? {
        var components = URLComponents(url: MicrosoftOAuthConfig.authorizationEndpoint(tenant),
                                       resolvingAgainstBaseURL: false)!
        var query: [URLQueryItem] = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "response_mode", value: "query"),
            .init(name: "scope", value: scopes.joined(separator: " ")),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: method),
            .init(name: "state", value: state),
        ]
        if let loginHint {
            query.append(.init(name: "login_hint", value: loginHint))
        } else {
            // Adding a second Outlook must not quietly become a second copy of the first.
            query.append(.init(name: "prompt", value: "select_account"))
        }
        components.queryItems = query
        return components.url
    }

    // MARK: - Internals

    /// Build the authorization URL.
    ///
    /// Pure and `nonisolated` so the query — where a missing parameter fails as a
    /// consent screen that asks for the wrong thing, or a grant that arrives with no
    /// refresh token and dies an hour later — is directly testable without a browser.
    nonisolated static func authorizationURL(clientID: String,
                                             redirectURI: String,
                                             scopes: [String],
                                             challenge: String,
                                             method: String,
                                             state: String,
                                             account: AccountChoice) -> URL? {
        var components = URLComponents(url: GoogleOAuthConfig.authorizationEndpoint,
                                       resolvingAgainstBaseURL: false)!
        var query: [URLQueryItem] = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: scopes.joined(separator: " ")),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: method),
            .init(name: "state", value: state),
            // Without offline access there's no refresh token, and the connection
            // would quietly die an hour after it was made.
            .init(name: "access_type", value: "offline"),
        ]
        switch account {
        case .chooseAccount:
            query.append(.init(name: "prompt", value: "select_account consent"))
        case .reuse(let email):
            query.append(.init(name: "login_hint", value: email))
            // Carry the scopes this account already granted into the new token, so the
            // consent screen names only what's actually new.
            query.append(.init(name: "include_granted_scopes", value: "true"))
            // `consent` without `select_account`: don't re-ask *which* account — we
            // know — but **do** force the consent screen. Google returns a
            // `refresh_token` only when it does, and each instance keeps its own grant;
            // a second Gmail connection that came back access-token-only would work for
            // an hour and then be unrepairable except by reconnecting.
            query.append(.init(name: "prompt", value: "consent"))
        }
        components.queryItems = query
        return components.url
    }

    /// The code from a redirect, after checking it answers *this* attempt. State is
    /// verified before the code is touched — an unmatched state means the callback
    /// isn't ours. An `error` the provider put on the redirect (a refused consent, an
    /// account the tenant rule turned away) is surfaced verbatim rather than read as
    /// a missing code.
    private static func authorizationCode(from callback: URL, state: String) throws -> String {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard items.first(where: { $0.name == "state" })?.value == state else {
            throw OAuthFlowError.stateMismatch
        }
        if let error = items.first(where: { $0.name == "error" })?.value {
            let detail = items.first(where: { $0.name == "error_description" })?.value
            throw OAuthFlowError.tokenExchangeFailed(detail.map { "\(error): \($0)" } ?? error)
        }
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw OAuthFlowError.noAuthorizationCode
        }
        return code
    }

    private func present(authURL: URL, scheme: String,
                         ephemeral: Bool) async throws -> URL {
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
            session.prefersEphemeralWebBrowserSession = ephemeral
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
        ], to: GoogleOAuthConfig.tokenEndpoint)
    }

    private static func post(form: [String: String], to endpoint: URL) async throws -> OAuthTokenResponse {
        var request = URLRequest(url: endpoint)
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
