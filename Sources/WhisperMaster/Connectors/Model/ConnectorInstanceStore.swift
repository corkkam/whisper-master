import Foundation
import Observation

/// The user's connector **instances** plus the per-kind default pointer.
///
/// Replaces the old `ConnectorStore`'s `Set<ConnectorKind>`, which couldn't express
/// two of anything. The shape is openworker's `accounts.py`: a list of per-account
/// profiles, and a separate pointer-only record naming the default for each kind, so
/// an unqualified request resolves to *something* deterministic.
///
/// **Per-account persistence.** Connectors belong to a person, not a Mac, and the
/// Clerk gate lets several people sign into one machine — so the file is
/// `Application Support/WhisperMaster/Connectors/<userId>.json` and `AppDelegate`
/// repoints it via `activate(userID:)` exactly like `UsageStore` and `NotesStore`.
/// The old store's own comment asked for this.
@MainActor
@Observable
final class ConnectorInstanceStore {
    /// Legacy device-wide key, read once by the migration then left alone.
    static let legacyEnabledDefaultsKey = "WhisperMaster.connectors.enabled.v1"
    /// Set once the legacy set has been folded into instances, so a user who then
    /// deletes every instance doesn't get them resurrected on next launch.
    static let migrationDoneDefaultsKey = "WhisperMaster.connectors.migratedToInstances.v2"

    private(set) var instances: [ConnectorInstance] = []

    /// Per-kind default instance. Consulted only when a request doesn't name one —
    /// reads fan out across all instances, writes use this (and say so).
    private(set) var defaultsByKind: [ConnectorKind: UUID] = [:]

    /// Standing write permissions, keyed `(tool, instanceID, target)`.
    ///
    /// Held here rather than in their own store so that removing a connection takes its
    /// grants with it — a revoked account must not leave live permissions behind, and a
    /// separate store would need a subscription to guarantee that.
    private(set) var grants: [Grant] = []

    /// Connections pinned to the notch, in the order their tabs appear.
    ///
    /// A pin is per **connection**, not per kind: "Gmail Work" and "Gmail Personal"
    /// pin apart, because each one gets its own tab and its own count. Capped at
    /// `notchPinLimit` — every pin is a tab in a band the width of the notch.
    /// Kept here rather than on `ConnectorInstance` so the order is one list, and
    /// so removing a connection takes its pin with it, same as its grants.
    private(set) var notchPins: [UUID] = []

    /// Most connections the notch band holds as tabs.
    static let notchPinLimit = 3

    /// Live EventKit authorization, refreshed by `CalendarConnector`. One TCC grant
    /// covers every calendar instance, so this is store-wide rather than per-instance.
    var calendarAccessGranted: Bool = false

    /// When false, mutations don't touch disk or the Keychain — used by the headless
    /// snapshot renderer so seeded mock instances never pollute real choices.
    var persistenceEnabled: Bool = true

    /// nil until a Clerk user resolves; no file is read or written before that.
    private var userID: String?

    /// Whether this account's file has been read yet. Tracked rather than inferred from
    /// `instances` being non-empty, which is the state of every user who hasn't added a
    /// connector: the guard in `activate` never fired for them, so a re-read plus the
    /// legacy migration ran on every 0.5 s refresh tick, forever.
    private var hasLoaded = false

    /// Disk reads so far. The only reader is the idempotency test — an empty list can't
    /// otherwise tell "not loaded" from "loaded, and there's nothing in it".
    private(set) var diskLoadCount = 0

    init(load: Bool = true) {
        if load { activate(userID: nil) }
    }

    // MARK: - Account scoping

    /// Point the store at one account's file and reload. Idempotent — repeat calls
    /// with the same id do nothing, so it's safe on the 0.5 s refresh tick.
    /// Passing nil loads the pre-sign-in (device) file, which is also where the
    /// legacy migration lands.
    func activate(userID: String?) {
        let normalized = userID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = (normalized?.isEmpty ?? true) ? nil : normalized
        if self.userID == resolved, hasLoaded { return }
        self.userID = resolved
        hasLoaded = true
        loadFromDisk()
        migrateLegacyEnabledSetIfNeeded()
    }

    /// Signed out: drop everything in memory. The file stays for the next sign-in.
    func deactivate() {
        userID = nil
        hasLoaded = false
        instances = []
        defaultsByKind = [:]
        grants = []
        notchPins = []
    }

    // MARK: - Reads

    func instances(of kind: ConnectorKind) -> [ConnectorInstance] {
        instances.filter { $0.kind == kind }
    }

    func instance(id: UUID) -> ConnectorInstance? {
        instances.first { $0.id == id }
    }

    /// Every readable instance that can serve a capability, in display order. This
    /// is the fan-out set for merged reads — capability, not kind, so a Google
    /// Calendar and an iCal instance answer the same "what's my day" together.
    func readable(providing capability: ConnectorCapability) -> [ConnectorInstance] {
        ordered.filter { $0.isReadable && $0.provides(capability) }
    }

    /// Any readable instance provides events — the gate for asking about the day at
    /// all.
    var hasReadableCalendar: Bool { !readable(providing: .events).isEmpty }

    /// Instances in a stable display order: catalog order by kind, then connection
    /// time within a kind, so the list never reshuffles under the user.
    var ordered: [ConnectorInstance] {
        let kindOrder = Dictionary(uniqueKeysWithValues: ConnectorKind.allCases.enumerated().map { ($1, $0) })
        return instances.sorted {
            let a = kindOrder[$0.kind] ?? .max, b = kindOrder[$1.kind] ?? .max
            if a != b { return a < b }
            return $0.connectedAt < $1.connectedAt
        }
    }

    /// The pinned connections that still exist, in tab order.
    var pinnedToNotch: [ConnectorInstance] {
        notchPins.compactMap { instance(id: $0) }
    }

    func isPinnedToNotch(_ id: UUID) -> Bool { notchPins.contains(id) }

    /// Whether another connection can be pinned right now.
    var canPinToNotch: Bool { notchPins.count < Self.notchPinLimit }

    func isDefault(_ id: UUID) -> Bool {
        guard let instance = instance(id: id) else { return false }
        return defaultInstance(of: instance.kind)?.id == id
    }

    /// The default instance for a kind: the stored pointer if it still exists, else
    /// the first instance of that kind, else nil. Mirrors openworker's
    /// `default_account` — a dangling pointer degrades rather than breaks.
    func defaultInstance(of kind: ConnectorKind) -> ConnectorInstance? {
        let candidates = instances(of: kind)
        if let pointer = defaultsByKind[kind], let hit = candidates.first(where: { $0.id == pointer }) {
            return hit
        }
        return candidates.first
    }

    /// openworker's `resolve`: the instance a request names, else the kind's
    /// default. `label` is matched leniently so a spoken "work" finds
    /// "Google Calendar Work".
    func resolve(kind: ConnectorKind, label: String? = nil) -> ConnectorInstance? {
        if let label, !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let hit = ConnectorLabelMatcher.match(label, in: instances(of: kind)) { return hit }
        }
        return defaultInstance(of: kind)
    }

    // MARK: - Mutations

    /// Add a connection. The first instance of a kind becomes that kind's default.
    /// The label is made unique within the kind, so two instances can never present
    /// the same spoken handle.
    @discardableResult
    func add(_ instance: ConnectorInstance) -> ConnectorInstance {
        var toAdd = instance
        toAdd.label = uniqueLabel(instance.displayLabel, kind: instance.kind, excluding: instance.id)
        instances.append(toAdd)
        if defaultsByKind[toAdd.kind] == nil { defaultsByKind[toAdd.kind] = toAdd.id }
        persist()
        return toAdd
    }

    /// Rename an instance. Returns the label actually stored, which may carry a
    /// uniqueness suffix.
    @discardableResult
    func rename(_ id: UUID, to newLabel: String) -> String? {
        guard let index = instances.firstIndex(where: { $0.id == id }) else { return nil }
        let trimmed = newLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let unique = uniqueLabel(trimmed, kind: instances[index].kind, excluding: id)
        instances[index].label = unique
        persist()
        return unique
    }

    func setEnabled(_ id: UUID, _ on: Bool) {
        guard let index = instances.firstIndex(where: { $0.id == id }) else { return }
        instances[index].isEnabled = on
        persist()
    }

    /// Pin a connection to the notch, or unpin it. Returns false (and changes
    /// nothing) for an unknown id or a pin past `notchPinLimit` — the caller dims the
    /// control at the cap, so this is the backstop, not the UX.
    @discardableResult
    func setPinnedToNotch(_ id: UUID, _ on: Bool) -> Bool {
        if !on {
            notchPins.removeAll { $0 == id }
            persist()
            return true
        }
        guard instance(id: id) != nil else { return false }
        if notchPins.contains(id) { return true }
        guard canPinToNotch else { return false }
        notchPins.append(id)
        persist()
        return true
    }

    func setDefault(_ id: UUID) {
        guard let instance = instance(id: id) else { return }
        defaultsByKind[instance.kind] = id
        persist()
    }

    func setConfig(_ id: UUID, _ config: ConnectorConfig) {
        guard let index = instances.firstIndex(where: { $0.id == id }) else { return }
        instances[index].config = config
        persist()
    }

    /// Record a fresh credential against an **existing** connection: the account the
    /// provider reported, whatever it discovered alongside it, and a cleared failure.
    ///
    /// Reconnecting has to keep the instance id, because that id is the Keychain
    /// account key, the grant key and the default pointer. Before this the only route
    /// out of `.credentialInvalid` was delete-and-re-add, which silently threw away
    /// the user's label, their per-kind default, and every standing write grant they
    /// had approved.
    func recordReconnection(_ id: UUID, identity: String, config: ConnectorConfig?) {
        guard let index = instances.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = identity.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { instances[index].identity = trimmed }
        if let config { instances[index].config = config }
        instances[index].lastError = nil
        persist()
    }

    func setError(_ id: UUID, _ error: ConnectorError?) {
        guard let index = instances.firstIndex(where: { $0.id == id }) else { return }
        guard instances[index].lastError != error else { return }
        instances[index].lastError = error
        persist()
    }

    /// Clear a failure state on every instance of a kind — used after a repair that
    /// is inherently kind-wide, like granting calendar access.
    func clearErrors(ofKind kind: ConnectorKind, matching error: ConnectorError) {
        var changed = false
        for index in instances.indices where instances[index].kind == kind && instances[index].lastError == error {
            instances[index].lastError = nil
            changed = true
        }
        if changed { persist() }
    }

    /// Remove an instance and its secret. The default pointer moves to the next
    /// instance of that kind; removing the last one drops the pointer entirely
    /// (openworker's `disconnect_account`).
    func remove(_ id: UUID) {
        guard let instance = instance(id: id) else { return }
        instances.removeAll { $0.id == id }
        if defaultsByKind[instance.kind] == id {
            if let next = instances(of: instance.kind).first {
                defaultsByKind[instance.kind] = next.id
            } else {
                defaultsByKind.removeValue(forKey: instance.kind)
            }
        }
        // A removed connection must not leave live write permissions behind.
        grants.removeAll { $0.instanceID == id }
        notchPins.removeAll { $0 == id }
        if persistenceEnabled { ConnectorCredentials.delete(for: id) }
        persist()
    }

    // MARK: - Standing grants

    /// Grants for one connection, newest first — the Settings revoke list.
    func grants(for instanceID: UUID) -> [Grant] {
        grants.filter { $0.instanceID == instanceID }.sorted { $0.grantedAt > $1.grantedAt }
    }

    /// Record an "always allow". Idempotent: re-granting the same three-part key is a
    /// no-op rather than a duplicate row in the revoke list.
    func addGrant(_ grant: Grant) {
        guard !grants.contains(where: { $0.id == grant.id }) else { return }
        grants.append(grant)
        persist()
    }

    func revokeGrant(id: String) {
        let before = grants.count
        grants.removeAll { $0.id == id }
        if grants.count != before { persist() }
    }

    // MARK: - Label uniqueness

    /// Labels must be unique **within a kind**, because the label is the spoken
    /// handle — two "Work" calendars would make "my work calendar" ambiguous with no
    /// way for the user to tell them apart. Collisions get " 2", " 3", …
    private func uniqueLabel(_ desired: String, kind: ConnectorKind, excluding: UUID?) -> String {
        let taken = Set(instances
            .filter { $0.kind == kind && $0.id != excluding }
            .map { $0.displayLabel.lowercased() })
        let base = desired.trimmingCharacters(in: .whitespacesAndNewlines)
        guard taken.contains(base.lowercased()) else { return base }
        var suffix = 2
        while taken.contains("\(base) \(suffix)".lowercased()) { suffix += 1 }
        return "\(base) \(suffix)"
    }

    // MARK: - Persistence

    /// What actually lands on disk. Kept separate from the in-memory shape so the
    /// default pointers persist as a plain `[String: String]` rather than relying on
    /// `ConnectorKind` being a dictionary key (which `JSONEncoder` refuses).
    private struct Payload: Codable {
        var instances: [ConnectorInstance]
        var defaults: [String: String]
        /// Optional so a file written before grants existed still decodes.
        var grants: [Grant]?
        /// Optional so a file written before notch pins existed still decodes.
        var notchPins: [String]?
    }

    nonisolated static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("WhisperMaster/Connectors", isDirectory: true)
    }

    /// Per-account file `…/WhisperMaster/Connectors/<userId>.json`. The id is
    /// sanitized so it's always a safe filename — never trust an id straight into a
    /// path, same rule as `NotesStore.fileURL(forUserID:)`. `nil` is the
    /// pre-sign-in device file.
    nonisolated static func fileURL(forUserID userID: String?) -> URL {
        guard let userID, !userID.isEmpty else {
            return directory.appendingPathComponent("device.json", isDirectory: false)
        }
        let safe = String(userID.map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" ? $0 : "_" })
        return directory.appendingPathComponent("\(safe).json", isDirectory: false)
    }

    private var fileURL: URL { Self.fileURL(forUserID: userID) }

    private func loadFromDisk() {
        diskLoadCount += 1
        instances = []
        defaultsByKind = [:]
        grants = []
        notchPins = []
        guard persistenceEnabled,
              let data = try? Data(contentsOf: fileURL),
              let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else { return }
        instances = payload.instances
        grants = payload.grants ?? []
        notchPins = (payload.notchPins ?? []).compactMap(UUID.init(uuidString:))
        defaultsByKind = Dictionary(uniqueKeysWithValues: payload.defaults.compactMap { key, value in
            guard let kind = ConnectorKind(rawValue: key), let id = UUID(uuidString: value) else { return nil }
            return (kind, id)
        })
    }

    private func persist() {
        guard persistenceEnabled else { return }
        let payload = Payload(
            instances: instances,
            defaults: Dictionary(uniqueKeysWithValues: defaultsByKind.map { ($0.key.rawValue, $0.value.uuidString) }),
            grants: grants,
            notchPins: notchPins.map(\.uuidString))
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: - Legacy migration

    /// Fold the old `Set<ConnectorKind>` into instances, once.
    ///
    /// Calendar kinds become one instance each, bound to **every** calendar (empty
    /// identifiers), which reproduces the old behaviour exactly — an upgrade must not
    /// silently narrow what a user's day summary reads.
    ///
    /// OAuth kinds are **dropped**. They never worked (no flow, no token, no fetch),
    /// so materialising instances for them would tell the user they have connections
    /// they don't. They reappear in the catalog sheet, connectable for real.
    private func migrateLegacyEnabledSetIfNeeded() {
        guard persistenceEnabled else { return }
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.migrationDoneDefaultsKey) else { return }
        defer { defaults.set(true, forKey: Self.migrationDoneDefaultsKey) }

        guard instances.isEmpty else { return }
        for instance in Self.legacyInstances(fromRawKinds: defaults.stringArray(forKey: Self.legacyEnabledDefaultsKey) ?? []) {
            add(instance)
        }
    }

    /// The pure half of the migration: legacy `rawValue` strings → the instances they
    /// become. Split out from the `UserDefaults`/disk plumbing so the *rules* — keep
    /// calendars unnarrowed, drop the OAuth kinds — are unit-testable without touching
    /// either.
    static func legacyInstances(fromRawKinds raw: [String]) -> [ConnectorInstance] {
        let legacy = Set(raw.compactMap(ConnectorKind.init(rawValue:)))
        return ConnectorKind.allCases
            .filter { legacy.contains($0) && ConnectorCatalog.descriptor(for: $0).isSystemBacked }
            .map { kind in
                ConnectorInstance(
                    kind: kind,
                    label: kind.displayName,
                    identity: "All calendars on this Mac",
                    // Empty identifiers = every calendar, i.e. exactly what the old
                    // `calendars: nil` query did. An upgrade must not silently narrow
                    // what someone's day summary reads.
                    config: .calendars(identifiers: [], sourceTitle: ""))
            }
    }
}
