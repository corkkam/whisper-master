import XCTest

@testable import WhisperMaster

/// Outlook and Teams over Microsoft Graph: the sign-in URL, the shapes Graph answers
/// in, chat addressing for a write, and the per-instance rules that keep an EventKit
/// Outlook from being offered tools it can't serve.
@MainActor
final class MicrosoftConnectorTests: XCTestCase {

    // MARK: - Sign-in

    private func authURL(loginHint: String? = nil,
                         tenant: MicrosoftOAuthConfig.Tenant = .common) -> [String: String] {
        let url = OAuthPKCEFlow.microsoftAuthorizationURL(
            clientID: "client", redirectURI: MicrosoftOAuthConfig.redirectURI,
            scopes: MicrosoftOAuthConfig.Scope.outlookConnect, tenant: tenant,
            challenge: "challenge", method: "S256", state: "state", loginHint: loginHint)
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.path.hasPrefix("/\(tenant.rawValue)/oauth2/v2.0/authorize") == true)
        let items = URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    func testAddingAnAccountForcesThePickerAndAsksForARefreshToken() {
        let query = authURL()
        XCTAssertEqual(query["prompt"], "select_account")
        XCTAssertNil(query["login_hint"])
        XCTAssertTrue(query["scope"]?.split(separator: " ").contains("offline_access") == true,
                      "without offline_access the connection dies an hour after it is made")
        XCTAssertEqual(query["code_challenge_method"], "S256")
        XCTAssertEqual(query["response_mode"], "query")
        XCTAssertEqual(query["redirect_uri"], "msauth.app.whispermaster.mac://auth")
    }

    func testTheRepairPinsTheAccountInsteadOfForcingThePicker() {
        let query = authURL(loginHint: "sam@acme.com", tenant: .organizations)
        XCTAssertEqual(query["login_hint"], "sam@acme.com")
        XCTAssertNil(query["prompt"])
    }

    /// Teams chats are not in Graph for a personal account, so the Teams sign-in
    /// refuses one in Microsoft's own picker; Outlook takes every account type.
    func testTeamsSignsInWorkAccountsOnlyAndNeedsNoAdminConsent() {
        XCTAssertEqual(MicrosoftOAuthConfig.signIn(for: .teams)?.tenant, .organizations)
        XCTAssertEqual(MicrosoftOAuthConfig.signIn(for: .outlook)?.tenant, .common)
        XCTAssertNil(MicrosoftOAuthConfig.signIn(for: .slack))
        for kind: ConnectorKind in [.outlook, .teams] {
            let scopes = MicrosoftOAuthConfig.signIn(for: kind)?.scopes ?? []
            XCTAssertTrue(scopes.contains("offline_access"), "\(kind)")
            XCTAssertFalse(scopes.contains { $0.hasSuffix(".Read.All") || $0.hasSuffix(".ReadWrite.All") },
                           "\(kind) must not ask for an admin-consent scope")
        }
    }

    /// The browser hands the code back on this scheme; if the plist doesn't declare
    /// it, the sign-in window hangs on the redirect with no error to read.
    func testInfoPlistDeclaresTheMicrosoftRedirectScheme() throws {
        let plistURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Info.plist")
        let plist = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: plistURL), format: nil) as? [String: Any]
        let schemes = (plist?["CFBundleURLTypes"] as? [[String: Any]] ?? [])
            .flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        XCTAssertTrue(schemes.contains(MicrosoftOAuthConfig.redirectScheme))
    }

    /// A refresh goes back to the issuer that minted the grant. Every grant stored
    /// before Microsoft existed carries no issuer and must still read as Google.
    func testTheIssuerTravelsInTheCredential() {
        XCTAssertFalse(ConnectorCredential(["access_token": "a", "refresh_token": "r"]).isMicrosoftGrant)
        XCTAssertTrue(ConnectorCredential([
            "access_token": "a",
            MicrosoftOAuthConfig.CredentialKey.issuer: MicrosoftOAuthConfig.CredentialKey.microsoftIssuer,
        ]).isMicrosoftGrant)
    }

    // MARK: - Instances

    private let eventKitOutlook = ConnectorInstance(
        kind: .outlook, label: "Exchange", identity: "Exchange",
        config: .calendars(identifiers: ["x"], sourceTitle: "Exchange"))
    private let graphOutlook = ConnectorInstance(
        kind: .outlook, label: "Work", identity: "sam@acme.com", config: .microsoftOAuth)

    func testAnEventKitOutlookReadsTheCalendarOnly() {
        XCTAssertTrue(eventKitOutlook.provides(.events))
        XCTAssertFalse(eventKitOutlook.provides(.mail),
                       "list_mail would be offered with a label no provider can answer")
        XCTAssertEqual(eventKitOutlook.authKind, .none)
        XCTAssertTrue(eventKitOutlook.isSystemBacked)
    }

    func testASignedInOutlookReadsMailAndCalendarAsARefreshableGrant() {
        XCTAssertTrue(graphOutlook.provides(.events))
        XCTAssertTrue(graphOutlook.provides(.mail))
        XCTAssertEqual(graphOutlook.authKind, .refreshableGrant)
        XCTAssertFalse(graphOutlook.isSystemBacked)
        XCTAssertTrue(graphOutlook.config.isNetworkBacked)
    }

    func testListMailIsPublishedForTheSignedInOutlookOnly() {
        let store = ConnectorInstanceStore(load: false)
        store.persistenceEnabled = false
        store.add(eventKitOutlook)
        XCTAssertFalse(ToolRegistry.available(store: store, includeWrites: false).map(\.name).contains("list_mail"))
        store.add(graphOutlook)
        let mail = ToolRegistry.available(store: store, includeWrites: false).first { $0.name == "list_mail" }
        XCTAssertEqual(mail?.parameters.first?.allowedValues, ["Work"])
    }

    /// A Microsoft grant can only be refreshed with the client id that minted it, so a
    /// build without one serves the connection as a visible failure, not empty reads.
    func testWithoutAClientIDASignedInConnectionHasNoProvider() throws {
        try XCTSkipIf(MicrosoftOAuthConfig.isConfigured, "a Microsoft client id is set in this environment")
        XCTAssertNil(ProviderRegistry.provider(for: graphOutlook))
        XCTAssertTrue(ProviderRegistry.provider(for: eventKitOutlook) is EventKitCalendarProvider)
    }

    func testTeamsIsOfferedOnlyWhenTheSignInIsInTheBuild() {
        XCTAssertTrue(ProviderRegistry.isConnectable(.teams, microsoftConfigured: true))
        XCTAssertFalse(ProviderRegistry.isConnectable(.teams, microsoftConfigured: false),
                       "Teams has no paste form, so without sign-in its card would have no working button")
        // Outlook always has the macOS Calendar route.
        XCTAssertTrue(ProviderRegistry.isConnectable(.outlook, microsoftConfigured: false))
        XCTAssertTrue(ProviderRegistry.provider(for: .teams) is TeamsProvider)
    }

    func testASignedInConnectionRepairsBySigningInAgain() {
        let teams = ConnectorInstance(kind: .teams, label: "Acme", identity: "sam@acme.com", config: .microsoftOAuth)
        for instance in [graphOutlook, teams] {
            XCTAssertEqual(ConnectorsSettingsView.repairRoute(
                for: instance, oauthConfigured: true, microsoftConfigured: true), .signInAgain)
            XCTAssertEqual(ConnectorsSettingsView.repairRoute(
                for: instance, oauthConfigured: true, microsoftConfigured: false), .addSheet)
        }
        XCTAssertEqual(ConnectorsSettingsView.repairRoute(
            for: eventKitOutlook, oauthConfigured: true, microsoftConfigured: true), .addSheet)
    }

    func testTheSameAccountTwiceForOneKindIsADuplicate() {
        let instances = [graphOutlook, eventKitOutlook]
        XCTAssertTrue(MicrosoftSignInStep.isAlreadyConnected("SAM@acme.com", kind: .outlook, in: instances))
        XCTAssertFalse(MicrosoftSignInStep.isAlreadyConnected("sam@acme.com", kind: .teams, in: instances),
                       "one account as Outlook and as Teams is two connections")
        XCTAssertFalse(MicrosoftSignInStep.isAlreadyConnected("Exchange", kind: .outlook, in: instances),
                       "an EventKit Outlook is not a Microsoft grant")
    }

    // MARK: - Graph shapes

    func testIdentityPrefersMailThenSignInName() {
        XCTAssertEqual(MicrosoftGraph.parseMe(["id": "1", "mail": "sam@acme.com", "userPrincipalName": "sam@acme.onmicrosoft.com"])?.identity,
                       "sam@acme.com")
        XCTAssertEqual(MicrosoftGraph.parseMe(["id": "1", "mail": NSNull(), "userPrincipalName": "sam@acme.com"])?.identity,
                       "sam@acme.com")
        XCTAssertNil(MicrosoftGraph.parseMe(["id": "1", "displayName": "Sam"]))
    }

    /// Graph writes seven fractional digits and no offset, which ISO8601DateFormatter
    /// refuses outright.
    func testGraphTimesParseAsUTCAndAllDayEventsAsALocalDay() {
        let timed = MicrosoftGraph.date(["dateTime": "2026-10-04T09:30:00.0000000", "timeZone": "UTC"], isAllDay: false)
        XCTAssertEqual(timed, ISO8601DateFormatter().date(from: "2026-10-04T09:30:00Z"))

        let kolkata = TimeZone(identifier: "Asia/Kolkata")!
        let allDay = MicrosoftGraph.date(["dateTime": "2026-10-04T00:00:00.0000000"], isAllDay: true, timeZone: kolkata)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = kolkata
        XCTAssertEqual(allDay.map { calendar.dateComponents([.year, .month, .day, .hour], from: $0) },
                       DateComponents(year: 2026, month: 10, day: 4, hour: 0))

        XCTAssertEqual(MicrosoftGraph.dateTimeString(ISO8601DateFormatter().date(from: "2026-10-04T15:00:00Z")!),
                       "2026-10-04T15:00:00")
    }

    func testCalendarViewDropsCancelledEventsAndKeepsTheJoinLink() {
        let json: [String: Any] = ["value": [
            ["id": "b", "subject": "Standup", "isAllDay": false, "isCancelled": false,
             "start": ["dateTime": "2026-10-04T10:00:00.0000000"],
             "end": ["dateTime": "2026-10-04T10:15:00.0000000"],
             "onlineMeeting": ["joinUrl": "https://teams.microsoft.com/l/meetup-join/19%3ameeting_x/0"]],
            ["id": "a", "subject": "Moved", "isCancelled": true,
             "start": ["dateTime": "2026-10-04T08:00:00.0000000"],
             "end": ["dateTime": "2026-10-04T09:00:00.0000000"]],
            ["id": "c", "subject": "Review", "isAllDay": false,
             "start": ["dateTime": "2026-10-04T09:00:00.0000000"],
             "end": ["dateTime": "2026-10-04T09:30:00.0000000"]],
        ]]
        let events = OutlookGraphProvider.parseEvents(json, instanceLabel: "Work")
        XCTAssertEqual(events.map(\.title), ["Review", "Standup"])
        XCTAssertEqual(events.last?.joinURL?.host, "teams.microsoft.com")
        XCTAssertNil(events.first?.joinURL)
        XCTAssertEqual(events.first?.sourceTitle, "Outlook")
        XCTAssertEqual(events.first?.instanceLabel, "Work")
    }

    func testMailListNamesTheSenderAndMarksUnread() {
        let json: [String: Any] = ["value": [
            ["id": "1", "subject": "Invoice", "isRead": false, "bodyPreview": "Hi",
             "from": ["emailAddress": ["name": "Ana", "address": "ana@x.com"]],
             "receivedDateTime": "2026-10-04T08:00:00Z", "webLink": "https://outlook.office.com/x"],
            ["id": "2", "subject": "", "isRead": true, "bodyPreview": "Lunch?",
             "from": ["emailAddress": ["name": "", "address": "bo@x.com"]]],
        ]]
        let items = OutlookGraphProvider.parseMessages(json, instanceLabel: "Work")
        XCTAssertEqual(items.map(\.title), ["Invoice", "Lunch?"])
        XCTAssertEqual(items.map(\.detail), ["unread · Ana", "bo@x.com"])
        XCTAssertNotNil(items.first?.timestamp)
    }

    func testTeamsBodiesAreReadAsPlainText() {
        XCTAssertEqual(
            MicrosoftGraph.plainText(fromHTML: "<p>Ship it<br/>today &amp; <at id=\"0\">Sam</at>&nbsp;:)</p>"),
            "Ship it today & Sam :)")
    }

    func testChatMembersLeaveOutTheSignedInUser() {
        let json: [String: Any] = ["value": [
            ["userId": "me", "displayName": "Sam"],
            ["userId": "u2", "displayName": "Alex Kim"],
        ]]
        XCTAssertEqual(TeamsProvider.parseMemberNames(json, excludingUserID: "me"), ["Alex Kim"])
    }

    // MARK: - Addressing a Teams chat

    private let chats: [(id: String, name: String, members: [String])] = [
        ("c1", "Launch crew", []),
        ("c2", "Alex Kim", ["Alex Kim"]),
        ("c3", "Alex Rivera", ["Alex Rivera"]),
        ("c4", "Priya Shah", ["Priya Shah"]),
    ]

    func testAChatIsFoundByTopicOrPerson() {
        XCTAssertEqual(TeamsProvider.resolveChat("#launch crew", in: chats), .found(id: "c1", name: "Launch crew"))
        XCTAssertEqual(TeamsProvider.resolveChat("alex rivera", in: chats), .found(id: "c3", name: "Alex Rivera"))
        XCTAssertEqual(TeamsProvider.resolveChat("Priya", in: chats), .found(id: "c4", name: "Priya Shah"))
    }

    /// Posting to the wrong person is worse than not posting.
    func testAFirstNameThatFitsTwoChatsIsRefused() {
        XCTAssertEqual(TeamsProvider.resolveChat("Alex", in: chats), .ambiguous(["Alex Kim", "Alex Rivera"]))
        XCTAssertEqual(TeamsProvider.resolveChat("Jordan", in: chats), .notFound)
        XCTAssertEqual(TeamsProvider.resolveChat("  ", in: chats), .notFound)
    }
}
