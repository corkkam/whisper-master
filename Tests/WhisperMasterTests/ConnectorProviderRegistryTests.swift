import XCTest

@testable import WhisperMaster

/// Honesty gates for the connector catalog.
///
/// The failure mode this suite exists to prevent is the one the redesign removed:
/// a kind that looks connectable in the catalog but has no provider (or a tool the
/// router claims to support with no way for the model to call it). Grok and Claude
/// both refuse to list a connector that can't actually run; so do we.
@MainActor
final class ConnectorProviderRegistryTests: XCTestCase {

    /// Every catalogued kind must have a provider. A kind in `ConnectorCatalog` with
    /// `ProviderRegistry` returning nil is a cosmetic tile — the exact bug that made
    /// Gmail/Drive/Zoom advertise "Coming soon" while their forms described a working
    /// paste path.
    func testEveryCataloguedKindHasAProvider() {
        for kind in ConnectorKind.allCases {
            XCTAssertTrue(
                ProviderRegistry.hasProvider(for: kind),
                "\(kind.rawValue) is in the catalog but has no provider")
            XCTAssertNotNil(
                ConnectorCatalog.descriptor(for: kind),
                "\(kind.rawValue) missing from ConnectorCatalog")
        }
    }

    /// The offer is narrowed, deliberately — see `ProviderRegistry.shippedKinds`.
    /// The rest keep their providers; they are just not offered yet. Teams is shipped
    /// but sign-in only, so it is offered only by a build carrying a Microsoft client.
    func testOnlyTheShippedKindsCanBeConnected() {
        XCTAssertEqual(
            Set(ConnectorKind.allCases.filter { ProviderRegistry.isConnectable($0, microsoftConfigured: true) }),
            [.appleCalendar, .googleCalendar, .gmail, .slack, .outlook, .teams])
        XCTAssertEqual(
            Set(ConnectorKind.allCases.filter { ProviderRegistry.isConnectable($0, microsoftConfigured: false) }),
            [.appleCalendar, .googleCalendar, .gmail, .slack, .outlook])
        for kind in ConnectorKind.allCases where !ProviderRegistry.shippedKinds.contains(kind) {
            XCTAssertFalse(
                ProviderRegistry.isConnectable(kind),
                "\(kind.rawValue) is not in the shipped set and must read as coming soon")
        }
    }

    /// Narrowing the offer must not break a connection a beta user already made:
    /// the instance path never consults `shippedKinds`.
    func testAnExistingInstanceOfAnUnofferedKindStillResolvesItsProvider() {
        let notion = ConnectorInstance(kind: .notion, label: "Team wiki", identity: "team")
        XCTAssertNotNil(ProviderRegistry.provider(for: notion))
    }

    /// Mail and files are first-class capabilities on Grok (Gmail / Drive built-ins).
    /// The router already fans them through `recentItems`; without a tool the model
    /// has nothing to call, so a connected Gmail would sit unused.
    func testMailAndFilesToolsExistAndBindToTheRightCapability() {
        let mail = ToolCatalog.descriptor(named: "list_mail")
        XCTAssertNotNil(mail)
        XCTAssertEqual(mail?.access, .read)
        XCTAssertEqual(mail?.capability, .mail)

        let files = ToolCatalog.descriptor(named: "list_files")
        XCTAssertNotNil(files)
        XCTAssertEqual(files?.access, .read)
        XCTAssertEqual(files?.capability, .files)
    }

    func testGmailDriveAndZoomAreWiredToRealProviders() {
        XCTAssertTrue(ProviderRegistry.provider(for: .gmail) is GmailProvider)
        XCTAssertTrue(ProviderRegistry.provider(for: .googleDrive) is GoogleDriveProvider)
        XCTAssertTrue(ProviderRegistry.provider(for: .zoom) is ZoomProvider)
    }

    func testZoomIsAnAsyncEventProvider() {
        let instance = ConnectorInstance(
            kind: .zoom,
            label: "Work Zoom",
            identity: "acct",
            config: .account(accountID: "acct"))
        XCTAssertNotNil(ProviderRegistry.asyncEventProvider(for: instance))
        XCTAssertTrue(instance.provides(.events))
    }

    func testGmailProvidesMailNotEvents() {
        let gmail = ConnectorCatalog.descriptor(for: .gmail)
        XCTAssertTrue(gmail.capabilities.contains(.mail))
        XCTAssertFalse(gmail.capabilities.contains(.events))
        XCTAssertEqual(gmail.authKind, .staticSecret)
    }

    func testAccountFieldsOnGoogleConnectorsAreOptional() {
        for kind: ConnectorKind in [.gmail, .googleDrive] {
            let account = ConnectorCatalog.descriptor(for: kind).fields
                .first { $0.key == "account" }
            XCTAssertNotNil(account, "\(kind) should declare an account field")
            XCTAssertEqual(account?.isRequired, false,
                           "\(kind) account is a label hint, not a gate")
        }
    }

    /// A Gmail-only store must surface `list_mail` and must not surface calendar tools.
    func testToolRegistryPublishesMailWhenGmailIsConnected() {
        let store = ConnectorInstanceStore(load: false)
        store.persistenceEnabled = false
        store.add(ConnectorInstance(
            kind: .gmail, label: "Personal", identity: "sam@gmail.com"))

        let names = Set(ToolRegistry.available(store: store, includeWrites: false).map(\.name))
        XCTAssertTrue(names.contains("list_mail"))
        XCTAssertFalse(names.contains("list_calendar_events"),
                       "no calendar connection → no calendar tool")
        XCTAssertTrue(names.contains("list_connectors"))
    }
}
