import XCTest

@testable import WhisperMaster

/// Pure store + catalog tests. `persistenceEnabled = false` throughout, so nothing
/// touches Application Support, the Keychain, or `UserDefaults`.
@MainActor
final class ConnectorInstanceStoreTests: XCTestCase {
    private func makeStore() -> ConnectorInstanceStore {
        let store = ConnectorInstanceStore(load: false)
        store.persistenceEnabled = false
        return store
    }

    private func calendar(_ label: String,
                          kind: ConnectorKind = .googleCalendar,
                          identity: String = "sam@acme.com",
                          identifiers: [String] = ["cal-1"]) -> ConnectorInstance {
        ConnectorInstance(
            kind: kind,
            label: label,
            identity: identity,
            config: .calendars(identifiers: identifiers, sourceTitle: "Google"))
    }

    // MARK: - Many instances per kind (the whole point)

    func testTwoInstancesOfTheSameKindCoexistWithTheirOwnCalendars() {
        let store = makeStore()
        store.add(calendar("Work", identifiers: ["work-a", "work-b"]))
        store.add(calendar("Personal", identity: "sam@gmail.com", identifiers: ["personal-a"]))

        XCTAssertEqual(store.instances(of: .googleCalendar).count, 2)
        let work = store.instances(of: .googleCalendar).first { $0.label == "Work" }
        let personal = store.instances(of: .googleCalendar).first { $0.label == "Personal" }
        XCTAssertEqual(work?.config.calendarIdentifiers, ["work-a", "work-b"])
        XCTAssertEqual(personal?.config.calendarIdentifiers, ["personal-a"])
    }

    // MARK: - Label uniqueness within a kind

    func testDuplicateLabelInSameKindGetsASuffix() {
        let store = makeStore()
        store.add(calendar("Work"))
        let second = store.add(calendar("Work"))
        XCTAssertEqual(second.label, "Work 2")
        let third = store.add(calendar("Work"))
        XCTAssertEqual(third.label, "Work 3")
    }

    func testDuplicateLabelIsCaseInsensitive() {
        let store = makeStore()
        store.add(calendar("Work"))
        let second = store.add(calendar("work"))
        XCTAssertEqual(second.label, "work 2")
    }

    /// The same label across *different* kinds is fine — "Work" Slack and "Work"
    /// calendar aren't ambiguous, because a request also implies a capability.
    func testSameLabelAcrossDifferentKindsIsAllowed() {
        let store = makeStore()
        store.add(calendar("Work", kind: .googleCalendar))
        let outlook = store.add(calendar("Work", kind: .outlook))
        XCTAssertEqual(outlook.label, "Work")
    }

    func testRenameEnforcesUniquenessAndReturnsTheStoredLabel() {
        let store = makeStore()
        store.add(calendar("Work"))
        let personal = store.add(calendar("Personal"))
        XCTAssertEqual(store.rename(personal.id, to: "Work"), "Work 2")
        XCTAssertNil(store.rename(personal.id, to: "   "), "a blank rename is rejected")
    }

    // MARK: - Default pointer

    func testFirstInstanceOfAKindBecomesItsDefault() {
        let store = makeStore()
        let work = store.add(calendar("Work"))
        XCTAssertTrue(store.isDefault(work.id))
        let personal = store.add(calendar("Personal"))
        XCTAssertTrue(store.isDefault(work.id), "adding a second must not steal the default")
        XCTAssertFalse(store.isDefault(personal.id))
    }

    func testRemovingTheDefaultReassignsItToTheNextInstanceOfThatKind() {
        let store = makeStore()
        let work = store.add(calendar("Work"))
        let personal = store.add(calendar("Personal"))
        store.remove(work.id)
        XCTAssertTrue(store.isDefault(personal.id))
    }

    func testRemovingTheLastInstanceOfAKindDropsThePointer() {
        let store = makeStore()
        let work = store.add(calendar("Work"))
        store.remove(work.id)
        XCTAssertNil(store.defaultInstance(of: .googleCalendar))
        XCTAssertTrue(store.instances.isEmpty)
    }

    func testSetDefaultMovesThePointer() {
        let store = makeStore()
        store.add(calendar("Work"))
        let personal = store.add(calendar("Personal"))
        store.setDefault(personal.id)
        XCTAssertTrue(store.isDefault(personal.id))
    }

    // MARK: - resolve()

    func testResolveFallsBackToTheDefaultWhenNoLabelIsNamed() {
        let store = makeStore()
        let work = store.add(calendar("Work"))
        store.add(calendar("Personal"))
        XCTAssertEqual(store.resolve(kind: .googleCalendar)?.id, work.id)
        XCTAssertEqual(store.resolve(kind: .googleCalendar, label: "")?.id, work.id)
    }

    func testResolveHonoursANamedLabel() {
        let store = makeStore()
        store.add(calendar("Work"))
        let personal = store.add(calendar("Personal"))
        XCTAssertEqual(store.resolve(kind: .googleCalendar, label: "personal")?.id, personal.id)
    }

    /// An unmatchable label falls back to the default rather than returning nil — the
    /// user asked for *this kind*, and refusing to answer is worse than answering from
    /// the default (writes name which one they used).
    func testResolveFallsBackWhenTheLabelMatchesNothing() {
        let store = makeStore()
        let work = store.add(calendar("Work"))
        XCTAssertEqual(store.resolve(kind: .googleCalendar, label: "nonsense")?.id, work.id)
    }

    // MARK: - Capability fan-out

    func testReadableExcludesDisabledAndErroredInstances() {
        let store = makeStore()
        let work = store.add(calendar("Work"))
        let paused = store.add(calendar("Paused"))
        let broken = store.add(calendar("Broken"))
        store.setEnabled(paused.id, false)
        store.setError(broken.id, .calendarMissing)

        let readable = store.readable(providing: .events).map(\.label)
        XCTAssertEqual(readable, ["Work"])
        XCTAssertTrue(store.hasReadableCalendar)
    }

    func testReadableIsEmptyForACapabilityNoInstanceProvides() {
        let store = makeStore()
        store.add(calendar("Work"))
        XCTAssertTrue(store.readable(providing: .messages).isEmpty)
        XCTAssertFalse(store.hasReadableCalendar == false)
    }

    func testClearErrorsOfKindOnlyClearsTheMatchingError() {
        let store = makeStore()
        let a = store.add(calendar("A"))
        let b = store.add(calendar("B"))
        store.setError(a.id, .needsCalendarAccess)
        store.setError(b.id, .calendarMissing)
        store.clearErrors(ofKind: .googleCalendar, matching: .needsCalendarAccess)
        XCTAssertNil(store.instance(id: a.id)?.lastError)
        XCTAssertEqual(store.instance(id: b.id)?.lastError, .calendarMissing)
    }

    // MARK: - Ordering

    func testOrderedGroupsByCatalogKindThenConnectionTime() {
        let store = makeStore()
        // appleCalendar sorts after googleCalendar in ConnectorKind.allCases.
        let apple = store.add(ConnectorInstance(
            kind: .appleCalendar, label: "iCloud", identity: "iCloud",
            config: .calendars(identifiers: ["a"], sourceTitle: "iCloud"),
            connectedAt: Date(timeIntervalSince1970: 0)))
        let googleOld = store.add(ConnectorInstance(
            kind: .googleCalendar, label: "Old", identity: "x",
            config: .calendars(identifiers: ["b"], sourceTitle: "Google"),
            connectedAt: Date(timeIntervalSince1970: 10)))
        let googleNew = store.add(ConnectorInstance(
            kind: .googleCalendar, label: "New", identity: "y",
            config: .calendars(identifiers: ["c"], sourceTitle: "Google"),
            connectedAt: Date(timeIntervalSince1970: 20)))

        XCTAssertEqual(store.ordered.map(\.id), [googleOld.id, googleNew.id, apple.id])
    }

    // MARK: - Legacy migration

    func testMigrationTurnsCalendarKindsIntoUnnarrowedInstances() {
        let migrated = ConnectorInstanceStore.legacyInstances(
            fromRawKinds: ["googleCalendar", "appleCalendar"])
        XCTAssertEqual(Set(migrated.map(\.kind)), [.googleCalendar, .appleCalendar])
        for instance in migrated {
            XCTAssertEqual(instance.config.calendarIdentifiers, [],
                           "empty identifiers = every calendar, preserving the old behaviour")
            XCTAssertEqual(instance.label, instance.kind.displayName)
        }
    }

    /// The OAuth kinds never worked — no flow, no token, no fetch — so materialising
    /// instances for them would tell the user they have connections they don't.
    func testMigrationDropsTheKindsThatNeverWorked() {
        let migrated = ConnectorInstanceStore.legacyInstances(
            fromRawKinds: ["gmail", "slack", "notion", "linear", "github", "zoom", "asana", "googleDrive"])
        XCTAssertTrue(migrated.isEmpty)
    }

    func testMigrationIgnoresUnknownRawValues() {
        let migrated = ConnectorInstanceStore.legacyInstances(
            fromRawKinds: ["googleCalendar", "notAThing", ""])
        XCTAssertEqual(migrated.count, 1)
    }

    // MARK: - activate() idempotency

    /// `AppDelegate.reconcileAuthGate()` calls `activate` on the 0.5 s tick, so a repeat
    /// call has to be free. It wasn't for the account that matters most — a user who
    /// hasn't added a connector yet, whose empty list used to read as "not loaded" and
    /// bought a disk read plus the legacy migration twice a second, forever.
    func testRepeatActivateWithNoConnectorsDoesNotReReadFromDisk() {
        let store = makeStore()
        store.activate(userID: "user_ABC123")
        let afterFirst = store.diskLoadCount
        XCTAssertTrue(store.instances.isEmpty)

        store.activate(userID: "user_ABC123")
        store.activate(userID: "  user_ABC123  ")
        XCTAssertEqual(store.diskLoadCount, afterFirst,
                       "the same account, already loaded, must not re-read")
    }

    func testActivateReloadsWhenTheAccountChangesAndAfterSigningOut() {
        let store = makeStore()
        store.activate(userID: "user_A")
        let afterFirst = store.diskLoadCount

        store.activate(userID: "user_B")
        XCTAssertEqual(store.diskLoadCount, afterFirst + 1, "a different account is a different file")

        store.activate(userID: nil)
        store.deactivate()
        store.activate(userID: nil)
        XCTAssertEqual(store.diskLoadCount, afterFirst + 3,
                       "signing out drops what was loaded, so the next activate reloads")
    }

    // MARK: - Per-account file paths

    func testPerUserFileURLsAreDistinctAndSanitized() {
        let a = ConnectorInstanceStore.fileURL(forUserID: "user_ABC123")
        let b = ConnectorInstanceStore.fileURL(forUserID: "user_XYZ789")
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a.lastPathComponent, "user_ABC123.json")
        XCTAssertEqual(ConnectorInstanceStore.fileURL(forUserID: nil).lastPathComponent, "device.json")
        let dirty = ConnectorInstanceStore.fileURL(forUserID: "../../etc/passwd")
        XCTAssertEqual(dirty.lastPathComponent, "______etc_passwd.json")
        XCTAssertFalse(dirty.path.contains(".."))
    }

    // MARK: - Round-tripping

    func testInstanceEncodesAndDecodesIncludingTheTypedConfig() throws {
        let original = calendar("Work", identifiers: ["a", "b"])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ConnectorInstance.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.config.calendarIdentifiers, ["a", "b"])
    }

    func testEveryConfigCaseRoundTrips() throws {
        let cases: [ConnectorConfig] = [
            .calendars(identifiers: ["x"], sourceTitle: "Google"),
            .workspace(teamID: "T123"),
            .account(accountID: "acct-1"),
            .empty,
        ]
        for config in cases {
            let data = try JSONEncoder().encode(config)
            XCTAssertEqual(try JSONDecoder().decode(ConnectorConfig.self, from: data), config)
        }
    }

    // MARK: - Catalog integrity

    func testEveryKindHasADescriptor() {
        for kind in ConnectorKind.allCases {
            let descriptor = ConnectorCatalog.descriptor(for: kind)
            XCTAssertEqual(descriptor.kind, kind)
            XCTAssertFalse(descriptor.capabilities.isEmpty, "\(kind.rawValue) declares no capability")
            XCTAssertFalse(descriptor.instructions.isEmpty, "\(kind.rawValue) has no setup copy")
        }
    }

    /// A credential-bearing connector with no fields would be unconnectable; a
    /// system-backed one with fields would be asking for a secret it never uses.
    func testDescriptorFieldsMatchTheirAuthKind() {
        for descriptor in ConnectorCatalog.all {
            if descriptor.authKind == .none {
                XCTAssertTrue(descriptor.fields.isEmpty, "\(descriptor.kind.rawValue) needs no credential")
            } else {
                XCTAssertFalse(descriptor.fields.isEmpty, "\(descriptor.kind.rawValue) has no way to connect")
            }
        }
    }

    /// Managed OAuth is only claimable where a secret-free public PKCE client actually
    /// exists. Every other provider here requires a `client_secret` at token exchange, so
    /// a one-click button would dead-end unless we shipped the secret or ran a broker —
    /// both rejected. Google is the only kind that qualifies.
    func testOnlyGoogleClaimsManagedOAuth() {
        let managed = ConnectorCatalog.all.filter(\.supportsManagedOAuth).map(\.kind)
        XCTAssertEqual(managed, [.googleCalendar])
    }

    /// Google Calendar deliberately has two auth paths — EventKit (no credential) and a
    /// signed-in API grant — so its `authKind` describes the credential-free route while
    /// `supportsManagedOAuth` advertises the other. This pins that intent, since a future
    /// edit "fixing" the apparent inconsistency would break one of the two flows.
    func testGoogleCalendarCarriesBothAuthPaths() {
        let descriptor = ConnectorCatalog.descriptor(for: .googleCalendar)
        XCTAssertEqual(descriptor.authKind, .none, "the EventKit route needs no credential")
        XCTAssertTrue(descriptor.supportsManagedOAuth, "the API route is one-click")
        XCTAssertTrue(descriptor.isSystemBacked)
    }

    /// The descriptor's `.none` is right for the EventKit route and wrong for the API
    /// one, so the *instance* has to decide. Resolving a signed-in Google instance as
    /// `.none` hands the provider an empty token, the request goes out with no
    /// `Authorization` header at all, and Google's 403 for an anonymous caller shows
    /// on the row as "the saved credential was rejected" — a credential that was
    /// never sent.
    func testSignedInGoogleInstanceResolvesAsARefreshableGrant() {
        let api = ConnectorInstance(
            kind: .googleCalendar, label: "Personal", identity: "a@b.com",
            config: .googleAPI(calendarIDs: ["a@b.com"]))
        XCTAssertEqual(api.authKind, .refreshableGrant)

        let eventKit = ConnectorInstance(
            kind: .googleCalendar, label: "Work", identity: "Google",
            config: .calendars(identifiers: ["x"], sourceTitle: "Google"))
        XCTAssertEqual(eventKit.authKind, .none, "the EventKit route still needs no credential")
    }

    /// A kind that declares real auth keeps it whatever its config looks like — the
    /// override only ever fills in for a descriptor that says `.none`.
    func testInstanceAuthKindNeverOverridesADeclaredAuthKind() {
        let slack = ConnectorInstance(
            kind: .slack, label: "Team", identity: "team", config: .empty)
        XCTAssertEqual(slack.authKind, .staticSecret)
    }

    func testSearchMatchesAliasesAndNotJustTitles() {
        XCTAssertTrue(ConnectorCatalog.search("exchange").contains { $0.kind == .outlook })
        XCTAssertTrue(ConnectorCatalog.search("tickets").contains { $0.kind == .linear })
        XCTAssertTrue(ConnectorCatalog.search("gcal").contains { $0.kind == .googleCalendar })
        XCTAssertEqual(ConnectorCatalog.search("").count, ConnectorCatalog.all.count)
        XCTAssertTrue(ConnectorCatalog.search("zzzznope").isEmpty)
    }

    func testEventCapableKindsAreExactlyTheCalendarsAndZoom() {
        XCTAssertEqual(
            Set(ConnectorCatalog.kinds(providing: .events)),
            [.appleCalendar, .googleCalendar, .outlook, .zoom])
    }
}
