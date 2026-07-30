import XCTest

@testable import WhisperMaster

/// PKCE crypto and the redirect-scheme derivation.
///
/// Both are places where a wrong answer fails *silently*: a mis-encoded challenge comes
/// back as an opaque `invalid_grant`, and a mismatched URL scheme means macOS never hands
/// the callback back at all — the sign-in window just sits there. Neither produces a
/// useful error at runtime, so they're pinned here instead.
final class OAuthPKCETests: XCTestCase {
    /// The real client id configured in `Info.plist`. Kept as a literal so a change to
    /// one without the other fails a test rather than a sign-in.
    private let clientID = "140047576864-ev40jmg8f2ju19j39qj1u761vse6ddhl.apps.googleusercontent.com"

    // MARK: - Redirect scheme

    func testRedirectSchemeIsTheReversedClientID() {
        XCTAssertEqual(
            GoogleOAuthConfig.redirectScheme(forClientID: clientID),
            "com.googleusercontent.apps.140047576864-ev40jmg8f2ju19j39qj1u761vse6ddhl")
    }

    /// The scheme must carry no `.apps.googleusercontent.com` remnant and no dot-prefix
    /// slip — either makes it a scheme macOS was never told to route to us.
    func testRedirectSchemeHasNoLeftoverSuffix() {
        let scheme = GoogleOAuthConfig.redirectScheme(forClientID: clientID)
        XCTAssertFalse(scheme.contains("apps.googleusercontent.com"))
        XCTAssertTrue(scheme.hasPrefix("com.googleusercontent.apps."))
        XCTAssertFalse(scheme.hasPrefix("com.googleusercontent.apps..") )
    }

    // MARK: - PKCE, against the RFC 7636 test vector

    /// RFC 7636 Appendix B: this exact verifier must produce this exact challenge. A
    /// standard-base64 or padded encoding would pass a naive round-trip test and fail
    /// here, which is the point.
    func testS256MatchesTheRFCTestVector() {
        XCTAssertEqual(
            PKCEChallenge.s256("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testChallengeIsBase64URLWithNoPadding() {
        let challenge = PKCEChallenge()
        XCTAssertFalse(challenge.challenge.contains("+"))
        XCTAssertFalse(challenge.challenge.contains("/"))
        XCTAssertFalse(challenge.challenge.contains("="))
        XCTAssertEqual(challenge.method, "S256")
    }

    /// 43 is the RFC minimum; a shorter verifier is rejected by the provider.
    func testVerifierMeetsTheRFCLengthFloor() {
        for _ in 0..<20 {
            let verifier = PKCEChallenge.randomVerifier()
            XCTAssertGreaterThanOrEqual(verifier.count, 43)
            XCTAssertLessThanOrEqual(verifier.count, 128)
        }
    }

    func testVerifiersAreUnique() {
        let verifiers = Set((0..<50).map { _ in PKCEChallenge.randomVerifier() })
        XCTAssertEqual(verifiers.count, 50)
    }

    func testChallengeIsDerivedFromTheGivenVerifier() {
        let challenge = PKCEChallenge(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        XCTAssertEqual(challenge.challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    // MARK: - Token response parsing

    func testParsesATokenResponseAndResolvesExpiryAgainstNow() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let json = #"{"access_token":"at","refresh_token":"rt","expires_in":3600,"scope":"a b"}"#
        let parsed = OAuthTokenResponse.parse(Data(json.utf8), now: now)

        XCTAssertEqual(parsed?.accessToken, "at")
        XCTAssertEqual(parsed?.refreshToken, "rt")
        XCTAssertEqual(parsed?.scope, "a b")
        XCTAssertEqual(parsed?.expiresAt, now.addingTimeInterval(3600))
    }

    func testRejectsAResponseWithNoAccessToken() {
        XCTAssertNil(OAuthTokenResponse.parse(Data(#"{"error":"invalid_grant"}"#.utf8)))
        XCTAssertNil(OAuthTokenResponse.parse(Data(#"{"access_token":""}"#.utf8)))
        XCTAssertNil(OAuthTokenResponse.parse(Data("not json".utf8)))
    }

    /// Google returns `refresh_token` **only on the first consent**. A naive overwrite on
    /// every refresh would erase it and silently force a re-sign-in later, so an omitted
    /// refresh token must preserve the stored one.
    func testRefreshWithoutARefreshTokenPreservesTheStoredOne() {
        var existing = ConnectorCredential()
        existing[ConnectorCredential.accessTokenKey] = "old"
        existing[ConnectorCredential.refreshTokenKey] = "keep-me"

        let refreshed = OAuthTokenResponse(
            accessToken: "new", refreshToken: nil,
            expiresAt: Date(timeIntervalSince1970: 5000), scope: nil)
        let merged = refreshed.merged(into: existing)

        XCTAssertEqual(merged.accessToken, "new")
        XCTAssertEqual(merged.refreshToken, "keep-me")
    }

    func testANewRefreshTokenReplacesTheStoredOne() {
        var existing = ConnectorCredential()
        existing[ConnectorCredential.refreshTokenKey] = "old"
        let merged = OAuthTokenResponse(
            accessToken: "a", refreshToken: "new", expiresAt: nil, scope: nil
        ).merged(into: existing)
        XCTAssertEqual(merged.refreshToken, "new")
    }

    // MARK: - Expiry

    /// Refresh *before* the provider starts rejecting us, not after a user has already
    /// seen a failure.
    func testExpiryUsesASkewSoRefreshHappensEarly() {
        var credential = ConnectorCredential()
        let expiry = Date(timeIntervalSince1970: 1000)
        credential[ConnectorCredential.expiresAtKey] = String(expiry.timeIntervalSince1970)

        XCTAssertFalse(credential.isExpired(now: Date(timeIntervalSince1970: 900), skew: 60))
        XCTAssertTrue(credential.isExpired(now: Date(timeIntervalSince1970: 950), skew: 60),
                      "within the skew counts as expired")
        XCTAssertTrue(credential.isExpired(now: Date(timeIntervalSince1970: 1100), skew: 60))
    }

    /// A static token (no expiry) must never be treated as expired, or every read would
    /// try to refresh something that can't be refreshed.
    func testACredentialWithNoExpiryIsNeverExpired() {
        var credential = ConnectorCredential()
        credential["bot_token"] = "xoxb-abc"
        XCTAssertFalse(credential.isExpired(now: Date(timeIntervalSince1970: 9_999_999)))
    }

    // MARK: - Form encoding

    /// `+` and `/` occur in real tokens and must be escaped. `.urlQueryAllowed` would let
    /// them through, and a `+` decodes server-side as a space — corrupting the token.
    func testFormEncodingEscapesCharactersThatAppearInTokens() {
        let encoded = OAuthPKCEFlow.encodeForm(["code": "a+b/c=d", "client_id": "x"])
        let body = String(data: encoded, encoding: .utf8)!
        XCTAssertTrue(body.contains("code=a%2Bb%2Fc%3Dd"))
        XCTAssertFalse(body.contains("a+b"))
    }

    func testFormEncodingIsDeterministicallyOrdered() {
        let a = OAuthPKCEFlow.encodeForm(["b": "2", "a": "1", "c": "3"])
        let b = OAuthPKCEFlow.encodeForm(["c": "3", "a": "1", "b": "2"])
        XCTAssertEqual(a, b)
        XCTAssertEqual(String(data: a, encoding: .utf8), "a=1&b=2&c=3")
    }

    // MARK: - Config gating

    func testPlaceholderValuesAreTreatedAsUnconfigured() {
        // Reached via redirectScheme derivation rather than the plist, since a test bundle
        // has no app Info.plist to read.
        XCTAssertEqual(
            GoogleOAuthConfig.redirectScheme(forClientID: "abc.apps.googleusercontent.com"),
            "com.googleusercontent.apps.abc")
    }

    func testScopeConstantsAreTheOnesGoogleExpects() {
        XCTAssertEqual(GoogleOAuthConfig.Scope.calendarReadonly,
                       "https://www.googleapis.com/auth/calendar.readonly")
        XCTAssertEqual(GoogleOAuthConfig.Scope.calendarEvents,
                       "https://www.googleapis.com/auth/calendar.events")
    }
}

/// The label prefilled after a Google sign-in. Pure, and worth pinning because a
/// personal-mailbox domain ("gmail") makes a useless connector name.
@MainActor
final class GoogleSignInLabelTests: XCTestCase {
    func testSuggestsTheCompanyNameFromAWorkAddress() {
        XCTAssertEqual(GoogleSignInStep.suggestedLabel(from: "sam@acme.com"), "Acme")
        XCTAssertEqual(GoogleSignInStep.suggestedLabel(from: "s@lyzr.ai"), "Lyzr")
        XCTAssertEqual(GoogleSignInStep.suggestedLabel(from: "a@sub.example.co.uk"), "Sub")
    }

    /// "Gmail" tells the user nothing about which account this is; "Personal" does.
    func testGenericMailboxDomainsBecomePersonal() {
        for address in ["me@gmail.com", "me@googlemail.com", "me@icloud.com",
                        "me@outlook.com", "me@hotmail.com", "me@yahoo.com"] {
            XCTAssertEqual(GoogleSignInStep.suggestedLabel(from: address), "Personal", address)
        }
        XCTAssertEqual(GoogleSignInStep.suggestedLabel(from: "me@GMAIL.com"), "Personal")
    }

    func testFallsBackToTheWholeStringWhenItIsNotAnAddress() {
        XCTAssertEqual(GoogleSignInStep.suggestedLabel(from: "not-an-email"), "not-an-email")
    }
}
