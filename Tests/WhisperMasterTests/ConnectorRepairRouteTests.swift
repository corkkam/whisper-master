import XCTest
@testable import WhisperMaster

/// Pins the repair routing that used to dead-end an expired Google sign-in.
/// `canReconnect` was descriptor-based only, so a signed-in Google Calendar (no
/// paste fields) fell to the Add sheet — where the same account is refused as a
/// duplicate, making Remove + re-add (losing label, default, and grants) the only
/// exit — and a signed-in Gmail (paste fields on its descriptor) fell to the
/// paste sheet, whose saved plain token the `.googleOAuth` config then treated as
/// a refreshable grant.
@MainActor
final class ConnectorRepairRouteTests: XCTestCase {
    private func instance(_ kind: ConnectorKind, _ config: ConnectorConfig) -> ConnectorInstance {
        ConnectorInstance(kind: kind, label: "Work", identity: "sam@acme.com", config: config)
    }

    func testASignedInGoogleCalendarRepairsBySigningInAgain() {
        XCTAssertEqual(
            ConnectorsSettingsView.repairRoute(
                for: instance(.googleCalendar, .googleAPI(calendarIDs: ["primary"])),
                oauthConfigured: true),
            .signInAgain)
    }

    func testASignedInGmailRepairsBySigningInAgainNotByPasting() {
        XCTAssertEqual(
            ConnectorsSettingsView.repairRoute(
                for: instance(.gmail, .googleOAuth), oauthConfigured: true),
            .signInAgain)
    }

    func testWithoutAClientIDTheManagedGrantFallsToTheAddSheet() {
        XCTAssertEqual(
            ConnectorsSettingsView.repairRoute(
                for: instance(.googleCalendar, .googleAPI(calendarIDs: [])),
                oauthConfigured: false),
            .addSheet)
    }

    func testAPastedCredentialStillReplacesItsSecretInPlace() {
        XCTAssertEqual(
            ConnectorsSettingsView.repairRoute(
                for: instance(.zoom, .account(accountID: "acc")), oauthConfigured: true),
            .replaceSecret)
    }

    func testASystemBackedCalendarNeverGetsACredentialRepair() {
        XCTAssertEqual(
            ConnectorsSettingsView.repairRoute(
                for: instance(.appleCalendar, .calendars(identifiers: [], sourceTitle: "iCloud")),
                oauthConfigured: true),
            .addSheet)
    }

    /// The repair pins the account: grants name this mailbox, so a browser
    /// sign-in that comes back as a different one must be refused, not saved.
    func testTheRepairedAccountMustBeTheSameMailbox() {
        XCTAssertTrue(ConnectorsSettingsView.identityMatches("Sam@Acme.com", existing: "sam@acme.com"))
        XCTAssertFalse(ConnectorsSettingsView.identityMatches("other@acme.com", existing: "sam@acme.com"))
    }

    /// The repair re-requests the same scopes the original connect asked for; a
    /// kind with no managed sign-in has no re-sign-in scopes.
    func testReSignInScopesMatchTheOriginalConnect() {
        XCTAssertEqual(ConnectorsSettingsView.reSignInScopes(for: .googleCalendar),
                       GoogleOAuthConfig.Scope.calendarConnect)
        XCTAssertEqual(ConnectorsSettingsView.reSignInScopes(for: .gmail),
                       GoogleOAuthConfig.Scope.gmailConnect)
        XCTAssertNil(ConnectorsSettingsView.reSignInScopes(for: .zoom))
    }
}
