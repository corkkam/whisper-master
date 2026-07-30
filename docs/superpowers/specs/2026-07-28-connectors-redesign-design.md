# Connectors redesign — named multi-instance connectors, tools, agent loop, automation

**Date:** 2026-07-28
**Status:** design approved; phases 1–5 implemented (Google one-click blocked on an external prerequisite — see below)
**Reference implementation studied:** [`andrewyng/openworker`](https://github.com/andrewyng/openworker) —
`coworker/connectors/{accounts,descriptors,config,tool_defs}.py`,
`coworker/automation/{models,scheduler,store}.py`,
`surfaces/gui/src/components/connectors/AccountsDetail.tsx`

## Why

Two problems, one root cause.

**The calendar connectors are cosmetic.** `CalendarConnector.todaysEvents()` calls
`predicateForEvents(withStart:end:calendars: nil)` — *all* calendars on the Mac. Toggling
"Google Calendar" versus "iCal" versus "Outlook" changes nothing: all three produce a
byte-identical event list, and `anyCalendarEnabled` is the only gate that has any effect. The
UI presents three independent sources over one undifferentiated query.

**The eight OAuth connectors do nothing at all.** There is no auth flow, no token storage, no
API client and no fetch. `OAuthConnectorConfig` reads a client id that is never set, so
`isConfigured` is permanently `false` and every OAuth tile is stuck on "Needs setup".

The root cause is that `ConnectorKind` is both the catalog entry *and* the unit of connection.
A fixed 11-case enum in a `Set<ConnectorKind>` cannot express "two Google Calendars", cannot
carry a credential, and cannot carry the per-connection configuration (which calendars? which
workspace?) that makes a connection mean anything.

## What we're building

A connector becomes an **instance**: a user-named, independently-credentialled connection to
one account, with many instances allowed per kind. "Google Calendar Personal" and "Google
Calendar Work" are two instances of the `googleCalendar` kind, each bound to different real
calendars, each addressable by name in speech.

On top of that: typed provider reads, tool descriptors, a local qwen tool-calling loop with a
consent model for writes, and a scheduler for automations.

## Decisions taken

| Question | Decision |
|---|---|
| Read surface | Typed providers **and** a real qwen tool-calling loop |
| Loop model | Local `qwen2.5-3B-Instruct-4bit` only; tight tool set, strict validation, deterministic fallback |
| Credentials | Native PKCE in-app where possible, Keychain per instance; **no backend** |
| Unqualified requests | **Merge** across instances for reads; **per-kind default** for writes, named in the response |
| Writes | Allowed, gated by openworker-style standing grants |
| Catalog | Manual-token paste for all 11 kinds; managed OAuth only where it's genuinely available |
| Automation | In-app timer with run-once-catch-up and skip-on-overlap; results in the notch |

### Where we diverge from openworker, and why

1. **Instances carry a user-editable `label`.** openworker derives the account name from the
   validator identity (`work@acme.com`) and displays that. The requirement here is human
   naming ("Work"), and because this is a dictation app the label is also the **spoken
   handle** — so it is a first-class mutable field, prefilled from the identity.

2. **Grants key on `(tool, instanceID, target)`, not `(tool, target)`.** openworker's
   two-part key is safe when accounts are addressed by unique email. With user-chosen labels
   and multiple instances per kind it leaks: "always allow `send_message #general`" granted on
   Personal Slack would silently authorise the same channel name on Work Slack. Multi-instance
   forces the three-part key.

3. **Native PKCE is Google-only.** Slack, Notion, Zoom, Asana and Linear all require a
   `client_secret` at token exchange and do not support public PKCE clients. There is no
   honest way to ship one-click OAuth for them without a broker, and a broker was rejected.
   This makes openworker's manual-token path load-bearing here rather than a fallback.

## Architecture

```
Connectors/
  Catalog/     ConnectorDescriptor, ConnectorCatalog, CredentialField
  Model/       ConnectorInstance, ConnectorInstanceStore, ConnectorCredentials, ConnectorError
  Auth/        OAuthPKCEFlow, CredentialStrategy, ManualCredentialValidator
  Providers/   ConnectorProvider, EventKitCalendarProvider, GoogleCalendarProvider, …
  Tools/       ToolDescriptor, ToolRegistry, ToolRouter
  Agent/       AgentLoop, ToolCallParser, AgentTranscript
  Consent/     Grant, GrantStore, ApprovalCoordinator
  Automation/  ScheduledTask, TaskRun, TaskStore, AutomationScheduler
  Summary/     DaySummaryService (kept; now fed by merged providers)
```

### The instance record

```swift
struct ConnectorInstance: Identifiable, Codable, Equatable, Sendable {
    let id: UUID                  // stable; also the Keychain key
    let kind: ConnectorKind       // catalog entry it instantiates
    var label: String             // user-editable — "Google Calendar Work"
    var identity: String          // derived at connect — "sam@acme.com"
    var isEnabled: Bool
    var config: ConnectorConfig   // typed, per-kind payload
    var connectedAt: Date
    var lastError: ConnectorError?
}
```

Secrets are **never** in this struct. They live in the Keychain under
`app.whispermaster.mac.connector.<uuid>`, reached only through `ConnectorCredentials`. The
record is therefore safe to log, diff, and render in the headless snapshot mode.

**Credentials come in three shapes**, declared by the descriptor's `authKind` and handled by a
matching `CredentialStrategy`:

- `none` — EventKit. No credential whatsoever; a first-class case, not an empty blob.
- `staticSecret` — PAT / bot token / integration token. Validated once, never refreshed.
- `refreshableGrant` — Google OAuth. Access token, refresh token, expiry, scopes.
- `mintedToken` — Zoom server-to-server: stores the *material* to mint a 1h token, not a token.

**`config` is typed, not `[String: String]`.** EventKit needs an array of calendar
identifiers, Slack a `team_id`, Zoom an `account_id`. A flat string map would force
JSON-encoded-inside-a-string, which rots. Each provider owns and decodes its own payload.

**Caches are separate and never authoritative.** Slack's channel-id → name directory lives at
`Connectors/Cache/<uuid>.json`, evictable at any time. It is not config and not credential.

### The store

`ConnectorInstanceStore` (`@MainActor @Observable`) replaces `ConnectorStore`, keeping
openworker's `accounts.py` shape:

- `instances: [ConnectorInstance]` plus a per-kind `default` pointer
- `resolve(kind:label:)` — the requested instance, else the kind's default, else `nil`
- `add` / `rename` / `remove` / `setDefault` / `instances(of:)` / `enabled(providing:)`
- Removing the default reassigns the pointer to the next instance of that kind; removing the
  last instance of a kind drops the pointer entirely (openworker's `disconnect_account`)

Persistence is **per-account** at
`Application Support/WhisperMaster/Connectors/<clerkUserId>.json`, activated by
`AppDelegate` exactly like `usageStore.activate(userID:)`. This is not a new invention —
`ConnectorStore.swift:12` already documents this as the intended path if multi-account
connector scoping were ever needed.

### Migration

Lazy and one-shot, following openworker's `migrate_legacy_default`. The existing
`WhisperMaster.connectors.enabled.v1` set converts as:

- each enabled **calendar** kind → one instance labelled with the kind's display name, bound
  to *all* calendars, preserving today's behaviour exactly
- each enabled **OAuth** kind → **dropped**. It never worked; materialising a broken instance
  would misrepresent the app's state to the user.

### Capabilities drive fan-out

Providers declare `Set<ConnectorCapability>` (`.events`, `.messages`, `.tasks`, `.files`).
`DaySummaryService` asks the store for every enabled instance providing `.events` and merges
the results, tagging each with its instance label. This is the "merge reads" decision made
concrete, and it is what finally makes two named calendars distinguishable in an answer.

### The calendar fix, concretely

`EventKitCalendarProvider`'s config holds `calendarIdentifiers: [String]`, passed to
`predicateForEvents(..., calendars:)` instead of `nil`. The add sheet is a checklist of the
Mac's calendars grouped by `EKSource`, pre-filtered by kind: Google → CalDAV sources, Outlook
→ Exchange, iCal → local / iCloud / subscribed. "Google Calendar Work" binds to real
`EKCalendar`s and genuinely filters.

Two EventKit-specific consequences:

- `EKCalendar.calendarIdentifier` is **not stable** across an account being removed and
  re-added, so a missing calendar becomes `lastError = .calendarMissing` with a repair action,
  never a silent empty result.
- All EventKit instances share **one** TCC grant. Per-instance `isEnabled` is a filter, never
  an access boundary.

### Tools

Tool descriptors are pure data per kind, expanded per instance by `ToolRegistry`:

```swift
struct ToolDescriptor {
    let name: String        // "calendar_list_events"
    let access: ToolAccess  // .read | .write
    let targetArg: String?  // required for .write — what a grant binds to
    let schema: JSONSchema
}
```

`ToolRouter` resolves a call's `instance:` argument via `resolve(kind:label:)` and stamps every
result with the instance that served it (openworker's `{"account": id, …}`), so a transcript
can never be ambiguous about which connection answered.

### The agent loop

`AgentLoop` runs the already-installed qwen with a flat tool list, one call per turn,
`maxIterations: 4` and a wall-clock budget. `ToolCallParser` validates each emitted call
against its schema *before* dispatch and rejects rather than coerces.

Any failure — malformed JSON, unknown tool, unresolvable instance, budget exhausted — falls
back to the deterministic `DaySummaryService`, so the notch always answers. The loop is
**opt-in and off by default**, matching `llmCleanupEnabled`.

The tool set is deliberately small (target ≤ 10 flat tools). A 4-bit 3B model is the
constraint the design is shaped around: the eval history already shows this model answering
questions it should have rewritten, which is why validation is hard-fail and the fallback is
deterministic rather than a retry.

### Consent

A write with no matching `(tool, instanceID, target)` grant **parks** and raises a notch
approval card naming instance, target and payload. The user picks once / always / never;
"always" writes a grant. Grants live on the instance record, so removing a connector takes its
grants with it, and Settings lists them for revocation. Reads are disclosure-only — rendered
on the card, never stored.

### Automation

`AutomationScheduler` is driven off the existing 0.5 s `AppDelegate` refresh tick, idle-gated.
It ports openworker's two policies verbatim:

- **run-once-catch-up** — anything missed while the app was quit fires once on the first tick
- **skip-on-overlap** — a running-id set prevents stacking
- **spawn, don't await** — a run parked on an approval must never stall the loop

`ScheduledTask` / `TaskRun` persist per-account. Results surface as a notch banner and a Runs
list on the Connectors page.

**Nothing runs while the app is quit.** This is stated plainly in the UI rather than papered
over; a LaunchAgent was considered and rejected (a background process the user didn't ask for,
a second permissions story, extra notarization plumbing).

### UI

The permanently-dead tile grid is replaced by:

1. **Connected** — one row per instance: label, identity, `Default` badge, status dot, and a
   ⋯ menu (rename / make default / remove).
2. **Add connector** — opens the catalog sheet. Pick a kind → the descriptor renders its
   credential form and instructions → `validate()` runs a real API call → the label is
   prefilled from the returned identity and is editable → save.

Unconnected kinds live in the catalog sheet, not on the main page, so the page stops
advertising capability the app doesn't have.

### Errors are states, not silence

`lastError` renders on the instance row with a repair action:
`.needsCalendarAccess`, `.calendarMissing`, `.credentialInvalid`, `.tokenExpired`,
`.rateLimited`. No instance ever silently returns empty.

## Phasing

One spec, five independently shippable phases. The riskiest work (a 4-bit 3B model driving
writes through a consent system) deliberately lands after the layers it rides on are proven.

| Phase | Contents |
|---|---|
| **1 — implemented** | Instance model, Keychain, descriptor catalog, EventKit providers bound to real calendars, rebuilt UI, label matcher, migration. **Fixes the reported bug; delivers named multi-instances.** |
| **2 — implemented** | Google PKCE via an iOS-type GCP client; Google Calendar / Gmail / Drive providers; typed read surface; tool descriptors as data; merged-read day summary |
| **3 — implemented** | The qwen loop, reads only, iteration cap, schema validation, deterministic fallback |
| **4 — implemented** | Writes, standing grants, approval cards |
| **5 — implemented** | Scheduler, catch-up + overlap guard, runs list |

### What is deliberately still out

The catalog describes all 11 kinds, but only a kind with an entry in `ProviderRegistry`
is connectable; the rest render as **Coming soon** with a reason. Offering a Connect
button for a kind that can't read anything is the exact failure mode being removed.

Connectable today: the three EventKit calendar kinds, Slack, Linear, GitHub, Notion,
Asana — all via manual token paste with a real `validate()`.

Not connectable: **Gmail** (restricted scope, CASA), **Google Drive** and **Zoom**
(no read implementation written). **Google Calendar via the REST API** is fully
implemented but withheld by `ProviderRegistry` until `GoogleOAuthConfig.isConfigured`
— so the one-click path is absent rather than present-and-broken.

Providers were written against the published API shapes but **have not been exercised
against a live account**, since that needs real credentials. The pure layers around them
— parser, registry, router, authorizer, scheduler — are unit-tested.

### Phase 2 prerequisite (external, blocking)

Phase 2 cannot start until an **iOS-type** OAuth client exists in GCP project
`whispr-500116` with bundle id `app.whispermaster.mac`. iOS-type clients are issued **no
client secret**, which is what makes secret-free PKCE possible; Desktop-type clients *are*
issued one and are therefore the wrong choice. The existing
`whisper_master_dev_client_secret_*.json` in the repo root is a **web** client wired to Clerk
sign-in and cannot serve this.

Scope reality for Google: `calendar.readonly` and `calendar.events` are **sensitive** scopes
(brand verification only). `gmail.readonly` is **restricted** and requires a CASA third-party
security assessment — costly and slow. openworker itself ships Google with
`managed_paused = True` for exactly this reason. Calendar therefore ships before Gmail.

## Testing

Pure unit tests, no network, no models — consistent with the existing fast suite:

- `ConnectorLabelMatcher` — spoken text → instance, including near-misses and no-match
- `ConnectorInstanceStore` — CRUD, label-uniqueness-within-kind, default-pointer reassignment
  on removal, last-instance-of-kind drops the pointer
- Migration — `v1` set → instances, calendar kinds preserved, OAuth kinds dropped, idempotent
- `ToolCallParser` — schema rejection of malformed and out-of-schema calls
- Grant matching — including the cross-instance leak case that motivated the three-part key
- `Schedule.next`, catch-up and overlap behaviour

`SnapshotMode` seeds two Google Calendar instances with different labels so the multi-instance
UI is visible in the headless renderer, with `persistenceEnabled = false` so it never touches
real state.

## Explicitly out of scope

- A token broker or any backend for connector credentials
- Cloud model escalation for the agent loop
- A LaunchAgent for while-quit automation runs
- Gmail one-click OAuth until CASA clears
- Any connector write in phase 1
