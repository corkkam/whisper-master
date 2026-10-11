# AGENTS.md — Whisper Master (macOS app)

The entry point for any AI agent working in this repository. It overrides the
machine-level `~/AGENTS.md` where the two disagree.

**This file is the contract. `CLAUDE.md` is the encyclopedia.** Read this first,
then read the one directory-level `CLAUDE.md` that governs the code you are about
to touch. Do not read all of them.

Last verified against the tree: **2026-08-14**, `dev` at `511b008`.

---

## 1. What this repository is

A shipping macOS menu-bar app for local-first streaming dictation, plus its
evaluation harness and public accuracy dashboard.

| Thing | Where | Stack |
|---|---|---|
| The app | `Sources/WhisperMaster/` | Swift 5 language mode, SwiftUI + AppKit, arm64, macOS 14+ |
| Unit tests and benches | `Tests/WhisperMasterTests/` | SwiftPM test target (`swift test`) |
| Cleanup eval harness | `eval/text-cleanup/` | Swift scorer, shell glue, Claude as judge |
| Public eval page | landing repo, `app/eval/` | Next.js + Supabase. Fed by `eval/text-cleanup/push-run.mjs` |
| Release machinery | `Scripts/`, `.github/workflows/release.yml` | bash, notarization, Sparkle, Cloudflare R2 |

Speech recognition is NVIDIA Parakeet through FluidAudio; the optional deeper
cleanup is qwen2.5-3B through MLX. Both run on the user's own machine. Audio is
captured to memory, transcribed, and discarded — it is never written to a socket
and never written to disk on the normal dictation path. **That property is the
product**, not a feature of it. Any change that would send audio off-device is a
different product and has to be argued as one.

## 2. Where the truth lives

Read in this order, and stop as soon as you have what you need.

1. **This file** — the rules and the gates.
2. **`CLAUDE.md`** (repo root, ~42 KB) — architecture, process model, release
   safety, and a one-paragraph summary of every subsystem with a pointer onward.
3. **The directory `CLAUDE.md` for the code you are changing.** There are twelve,
   and each one holds the rules that only make sense next to that code:

   | Directory | What its file governs |
   |---|---|
   | `Analytics/` | the vendor seam, the content-free event taxonomy, crash capture |
   | `Audio/` | the capture graph, Bluetooth call mode, engine-rebuild recovery |
   | `Auth/` | the Clerk sign-in gate, the OAuth redirect allowlist per build |
   | `Diagnostics/` | the developer-only session tracer (`DIAGNOSTICS` builds only) |
   | `Input/` | push-to-talk gestures, the fn+control assistant chord, paste routing |
   | `Notes/` | voice notes and the hand-written `Codable` that must stay hand-written |
   | `Reminders/` | idle nudges and user reminders in the notch band |
   | `Speech/` | reading answers aloud, and why it must stay out of `Audio/` |
   | `Traces/` | the "why did it do that" surface that replaced History |
   | `Transcription/` | the ASR path, deterministic cleanup, ITN, model install |
   | `UI/` | the Organic design system, theme tokens, notch surface rules |
   | `Usage/` | per-account usage records and the opt-out cloud sync |

   Two subsystems have **no** directory `CLAUDE.md`; their doc lives in the
   file headers: `Server/RemoteTranscriptionServer.swift` (opt-in TLS-PSK remote
   dictation) and `Mesh/MeshCoordinator.swift` (peer discovery). See §9.

4. **Skills** — `.claude/skills/releasing/SKILL.md` before cutting anything,
   `.claude/skills/eval-pipeline/SKILL.md` before touching the cleanup pipeline
   or anything under `eval/`.
5. **Cross-project context** — `../docs/` (13 files: features, architecture,
   design system, launch checklist, monetization, GTM, regulated deployment).
   `../docs/07-design-system.md` is required reading before any UI work.

Design specs for finished features are in `docs/superpowers/specs/`. They record
the reasoning at the time; the code and the `CLAUDE.md` files are what is true now.

## 3. Build, test, and see it

```bash
xcodegen generate                 # after editing project.yml or adding files
swift build                       # fast headless compile check, no .app
swift test                        # pure unit tests, no models, no audio, no network
swift test --filter AudioReplayTests   # regression bench on real recordings
bash eval/text-cleanup/run-eval.sh     # grade the real cleanup pipeline
bash Scripts/install.sh           # build -> /Applications -> relaunch
WM_SNAPSHOT=<dir> .build/debug/WhisperMaster   # render every panel to PNG, then exit
```

**`project.yml` is the source of truth; `WhisperMaster.xcodeproj` is generated and
git-ignored.** Dependencies are declared in both `project.yml` and `Package.swift`
— keep the two in step.

**The gate for a change here is `swift build` and `swift test` green**, plus the
audio bench for anything on the transcription path and the eval harness for
anything on the cleanup path. There is **no CI test workflow** — the only GitHub
workflow is release automation, so the gate is you running it and pasting the
output.

**The tree is green.** As of 2026-08-14: `swift build` clean; `swift test` runs
833 tests, 2 skipped, **0 failures**. The one failure that stood here —
`ConnectorInstanceStoreTests.testOnlyGoogleClaimsManagedOAuth` expecting
`[.googleCalendar]` — was the committed test not moving with the uncommitted Gmail
work that made Gmail a second managed-OAuth kind. The expectation is now
`[.googleCalendar, .gmail]`.

**Verify UI visually.** `WM_SNAPSHOT` renders every settings panel and onboarding
step headlessly in seconds; use it instead of a build-sign-install cycle. It is
compiled out of Release.

## 4. Hard prohibitions

These hold even when the file that explains them is not loaded.

1. **Never republish a version number.** Each release needs a fresh
   `CFBundleShortVersionString`. Re-shipping a version overwrites the bytes an
   already-signed appcast entry was computed for, and Sparkle refuses the update.
   Bump forward; never re-upload.
2. **Bump `CFBundleShortVersionString` and `CFBundleVersion` together** in
   `Resources/Info.plist`, or Sparkle does not see the build as newer.
3. **Never commit directly to `main`.** It takes merges from `release/*` and
   `hotfix/*` only, and every production release is tagged `vX.Y.Z`. Branch from
   `dev`.
4. **The public R2 host is baked into shipped bundles in four places** —
   `Scripts/channel.sh` (`CH_SU_FEED_URL`), `Auth/BetaAccess.swift`
   (`UpdateChannel.feedURLString`), `ModelInstall/ModelInstaller.swift`
   (`mirrorBaseURL`), and `R2_PUBLIC_BASE_URL` in `.env`. Change hosts only by
   editing all four together, after copying `models/` to the new bucket.
5. **Do not programmatically juggle audio devices** to auto-fix Bluetooth or input
   routing. It was tried three times and every variant broke something, up to
   hanging Core Audio with the app unresponsive. Rebuilding our own
   `AVAudioEngine` on a configuration change is a different thing and is allowed.
6. **Do not re-enable `configureVocabularyBoosting`.** FluidAudio's streaming CTC
   vocabulary rescorer corrupts transcripts. Custom vocabulary is post-processing.
7. **Holding the push-to-talk key dictates and nothing else.** No code path may
   infer assistant intent from the words. The assistant path suppresses the paste,
   so a rule that guesses wrong eats the user's transcript. Everything else lives
   behind the fn+control chord.
8. **Do not run blanket `swiftformat`.** There is no `.swiftformat` config here,
   and the default `redundantType` rule strips a load-bearing annotation in
   `DictationViewModel.enqueueAudioBuffer` and breaks the build. Hand-match the
   surrounding style.
9. **Never weaken the Clerk sign-in gate.** An `authBypass`-style flag is a bug,
   in every channel including dev.
10. **A new field on a persisted model must survive an old payload that lacks
    it.** Swift's *synthesized* `init(from:)` calls `decode`, not
    `decodeIfPresent`, for any non-optional property — a default value is used by
    the memberwise init and nowhere else — so a bare non-optional field throws
    `keyNotFound` on every record already on disk. Two subsystems live under this
    and take opposite routes: `Note`'s `Codable` is **hand-written** and every new
    field uses `decodeIfPresent` with a default (a decode throw there silently
    empties the user's notes); `Trace`/`AssistantTrace`/`ToolCallTrace` keep the
    **synthesized** `Codable` behind a `try?` load, so every new persisted field is
    made **optional** instead (a default is not enough). See `Notes/CLAUDE.md` and
    `Traces/CLAUDE.md`. Adding a non-optional field to either is the same bug.
11. **Never commit a secret.** `.env` is git-ignored and stays that way; document
    a new variable in `.env.example` by name only.

## 5. Conventions

- `@MainActor` on anything that touches UI or AppKit. Never call it off the main
  actor.
- **The view model is the only thing that mutates `PrototypeAppState`.** Views
  read it, `AppDelegate`'s 0.5s timer polls it, nothing else writes it.
- **Every AppKit write on the tray refresh path is change-guarded.** That timer
  runs twice a second for the life of the process; an unguarded
  `button.image = ...` is a permanent background cost, not a one-off.
- New UI uses `Theme.swift` tokens and the `UI/Components/` ladder, never ad-hoc
  literals. Reach for the brand mark through `BrandLogo(size:)`, never by loading
  a logo PNG.
- One status item, one settings window. The AppDelegate's single-instance
  ownership is load-bearing.
- Tests pin real behaviour. Do not weaken a test to make a change pass, and do not
  pad coverage.
- Comments say how something is used and why it is that way, not what the line
  does. If you learn something non-obvious, write it in the nearest `CLAUDE.md`.

## 6. Branch, release, and territory

- **Branch `feature/<kebab-slug>` off `dev`** (a bug is `fix/<kebab-slug>`). One
  concern per branch. **No ticket id in the name** — this repo overrides the
  machine-wide `<feature|bug>/<COR-###>-<slug>` form in `~/AGENTS.md`, which
  belongs to the Linear-tracked repos. A repo's own `AGENTS.md` wins.
- Push the feature branch. No auto-merge, no force-push, no auto-publish.
- **A branch does not survive its own merge.** Merge and delete are one step:
  `git push origin --delete <branch>` in the same breath, or the PR merged with
  delete-branch on. Thirteen dead branches piled up here; two of them were
  `release/1.2.9` and `release/1.2.10`, numbers *above* the live 1.1.0 line
  because versioning restarted at 1.0.0, so `git branch -r` told the release
  history backwards. Both were deleted on 2026-08-14.
- **`release/<x.y.z>` is conditional, not routine.** Cut one only when work must
  keep landing on `dev` while a version stabilizes. Otherwise bump on `dev`,
  dogfood on the dev channel, then merge `dev` into `main`. A release branch that
  `dev` has overtaken holds no commits and only misinforms; finish it or delete
  it. Full flow: the **`releasing`** skill, section "Branching".
- **The GitHub default branch is `dev`, not `main`.** The repo is public (AGPL-3.0)
  since 2026-10. Since 2026-10-10, `dev` and `main` are protected: a PR with 1
  approval and resolved conversations, no force-push, no delete. `enforce_admins`
  is off, so only the `corkkam` owner account can bypass. `shobhit8797` cannot
  approve its own PRs. Secret-scanning push protection and Dependabot are on (set
  with `gh secure`). CodeQL runs from `.github/workflows/codeql.yml` (advanced
  setup, so Swift is scanned); the default setup must stay off or GitHub rejects
  its uploads. The `release` job runs in the `release` Environment, which waits
  for the `corkkam` owner to approve each run in the Actions tab.
- `[skip release]`, `[skip announce]`, and `[skip ci]` are three different
  switches — the whole release job, the Telegram step only, and the entire
  workflow. Do not confuse them.
- Non-stable channels must carry the marker in the version (`-beta.N`, `-dev.N`)
  or `release.sh` aborts.
- **Several agents work this repo at once.** Check `git status`, worktrees, and
  stashes before a broad refactor. There are currently ~50 uncommitted paths on
  `dev` — see §7. Never clobber work you did not write.

## 7. What is in flight right now

**⚠️ Release freeze, set 2026-08-14. No stable release.** Do not merge anything
into `main`, and do not bump `CFBundleShortVersionString` on `dev` — either one
makes CI build, sign, notarize, and ship. If a release run starts by accident,
cancel it (`gh run cancel`) instead of letting it finish. Only the owner lifts
this.

`dev` carries a large uncommitted change set. Treat these as **built but not
released**, and do not describe them as shipped:

- **Traces** (`Sources/WhisperMaster/Traces/`, `UI/Settings/TracesSettingsView.swift`)
  — replaces the History page. `UI/Settings/HistorySettingsView.swift` is deleted
  in the working tree.
- **`CleanupTarget`** and the eval-only Slack / email / code destination prompts.
  These are deliberately **not** wired into the shipping paste path.
- **Google account reuse** (`Connectors/Auth/GoogleAccounts.swift`) and a Gmail
  sign-in step.
- **`PointerScreen`** — pointer-aware placement for notch surfaces.
- A stronger `CleanupFaithfulnessGuard` verdict, with tests.
- **Removals, all on the owner's instruction — do not restore them.**
  - **Regulated Mode is gone** (`Compliance/RegulatedMode.swift` deleted, 2026-08-14),
    with its MDM/plist/local-opt-in keys and every egress gate. The user's own
    switches are now the only thing between the sinks and the network. The
    cross-repo note `../docs/12-regulated-deployment.md` still describes it and is
    **stale**; it was left alone because it lives outside this repo.
  - **The short-window ASR preview track**, which used to paint live words on the
    notch. See `Transcription/CLAUDE.md`.
  - **Seven of the eleven connectors are no longer offered** — the code stays, the
    offer is narrowed by `ProviderRegistry.shippedKinds`.
  - **Nearby Macs is closed** on every channel (`SettingsSection.isAvailable`).

Released and current: **`v1.1.0-beta.6`** on the beta channel (Gmail, Drive, and
Zoom connectors reading for real), **`v1.0.1`** on stable (the mic-crash hotfix).
`main` is at `0ad6611`; `dev` is 76 commits ahead of it and carries
`1.1.0-beta.6` in `Resources/Info.plist`. **1.1.0 has never reached `main`**, and
under the freeze above it is not going to yet.

**There is one version source: `Resources/Info.plist`.** `GENERATE_INFOPLIST_FILE:
NO` plus literal version keys mean nothing interpolates a build setting, and the
CI gate, `release.sh`, and the tag step all read the plist. `project.yml` used to
carry inert `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` copies "kept in step
so nobody reads the wrong number"; they drifted to `1.2.10` while the plist moved
to `1.1.0-beta.6`, so the stale copy was the *higher* number and read as the newer
one. **Both were deleted on 2026-08-14.** Do not put a version back in
`project.yml`.

## 8. Ask before you act

Confirm first, naming the exact command, for: any release or notarized build,
writing to `main` or `dev`, rewriting or discarding history, deleting anything
the task did not create, changing production configuration, anything a real
person receives, and any spend. Approval never carries to the next action.

Answer a question without editing. "How hard would it be", "why does", "should
we" are read-only.

## 9. Glossary

The words this repo uses, so an agent reads a prompt or a file the way the code
means it. Product copy calls the app **Whisper Master**; voice prompts often
arrive as "whisper mash" or "visible master".

### Surfaces (what the user sees)

- **Notch / band** — the primary surface: a band that drops below the camera
  notch for live text, questions, approvals, and reminders. Everything under
  `UI/` with `Notch` in the name draws on it.
- **Pill** — `DictationPillWindow`, the small floating dictation indicator.
- **Orb** — the dotted listening sphere (`ThinkingOrb`). One frozen frame of it
  is the brand mark; `Scripts/make-logo.swift` generates every logo asset.
- **Tray** — the `NSStatusItem` in the menu bar, polled by `AppDelegate`'s 0.5s
  timer. Every AppKit write on that path is change-guarded.
- **Glance** — the coding-agents panel opened by tapping the agent hotkey.
- **Traces** — the "why did it do that" page (Dictation + Assistant tabs). It
  replaced the History page; the tray submenu is all that remains of history.
- **Insights** — the per-account usage dashboard, computed from real records.

### Input and routing

- **Push-to-talk key** — one key (default Globe/fn): hold to dictate,
  double-tap to latch hands-free. Holding it dictates and does nothing else;
  no path may infer intent from the words (prohibition §4.7).
- **The chord** — held fn+control, the single entry point to the assistant.
  The assistant path suppresses the paste.
- **Tier** — which brain answers a chord capture inside `routeCommandCapture`:
  local MLX model, cloud model, or the deterministic fallback. "Answered
  without any tool having executed" counts as not acting and falls through.
- **Agent hotkey** — a second, user-chosen, off-by-default key: hold-and-talk
  sends the words to a coding agent (kunai); tap opens the glance.
- **Paste / injection** — `TextInjector` (actor) delivering the final text via
  CGEvent keystrokes or real ⌘V, chosen from what Accessibility reports.

### Transcription pipeline

- **Engine / Parakeet** — NVIDIA Parakeet running on-device through the
  FluidAudio package; `slidingWindow` is the one engine.
- **One window track** — long windows produce the text that is pasted. It says
  nothing for its first 13 s, so a short dictation shows no live words on the
  notch; that is intended. Never shorten the windows to change it (`finish()`
  reconstructs the pasted text from them). The short-window "preview" manager
  that used to fill the gap was removed on purpose.
- **Cleanup / polish** — deterministic passes (filler filter, ITN,
  self-correction collapsing, vocabulary) plus the opt-in deeper MLX cleanup.
- **ITN** — inverse text normalization, spoken forms to written ("five pm" →
  "5pm"). Never sum a run of bare unit words (prohibition around
  `SpokenNumber.value`).
- **Faithfulness guard** — `CleanupFaithfulnessGuard`, the verdict that
  polished text did not drift from what was said; its verdict shows in Traces.
- **Vocabulary** — custom terms applied as post-processing, never engine
  biasing (prohibition §4.6).
- **Audio bench** — `swift test --filter AudioReplayTests`: real recordings
  replayed through the real streaming path. Run it for any transcription or
  post-processing change.
- **Eval harness** — `eval/text-cleanup/run-eval.sh`, Claude-as-judge grading
  of the cleanup pipeline; history at whisper.corkkam.com/eval, published by
  `Scripts/release.sh` on every stable and beta release.

### Assistant and connectors

- **Assistant** — the chord-invoked capture that answers, acts, or files a
  note instead of pasting. Answers are spoken (`Speech/`) as well as shown.
- **Connector** — an external service the assistant can reach. Shape: catalog
  entry (`ConnectorCatalog`) → configured `ConnectorInstance` →
  `ConnectorProvider` → tools offered to the model (`AgentToolRunning`,
  `CommandAgentService`). **Only four are offered**
  (`ProviderRegistry.shippedKinds`: Apple Calendar, Google Calendar, Gmail,
  Slack); the rest keep their code and read as "Coming soon" in the catalog.
  The gate governs new connections only — an instance already made still
  resolves its provider. The assistant may use a connected connector by
  default (`connectorAgentEnabled`, on).
- **Approval card** — `NotchApprovalBanner`, the consent card a connector
  write raises on the band. It denies itself on timeout.
- **Undelivered banner** — where spoken words land when the agent path cannot
  deliver them; they are never pasted into the frontmost app instead.

### Coding agents (kunai)

- **kunai** — an external Go server that drives Claude Code sessions. This app
  is a client only: it never ships, starts, or supervises kunai. No server →
  the feature is absent, which is the normal state.
- **Fleet socket / app socket** — `/ws/fleet` pushes every session's state;
  `/ws/app/{id}` carries one conversation. Two sockets, never one per session.
- **Ask / choice card / nudge** — a permission question answerable on the band;
  a model-authored multi-option question (options are never truncated); a
  one-line, once-only pointer that another session blocked or finished.

### Infrastructure and modes

- **Clerk gate** — launch sign-in gate. It blocks every build; a bypass flag
  is a bug (prohibition §4.9).
- **Sparkle / appcast / channel** — auto-update. Channels are stable, beta
  (`-beta.N`), dev (`-dev.N`); the appcast and archives live on R2.
- **R2 mirror** — the Cloudflare bucket that also mirrors ASR models
  (`ModelInstaller.mirrorBaseURL`); an empty `models/` prefix silently
  degrades installs to the slow HuggingFace path.
- **Mesh** (`Mesh/`) — discovery of other Macs running Whisper Master
  (Bonjour + Tailscale addresses + Bluetooth proximity), with per-peer load
  and latency, written into `AppState` by `MeshCoordinator`. **On hold**: the
  Nearby Macs page is closed on every channel (`SettingsSection.isAvailable`)
  and reads "Coming soon". The code stays.
- **Remote dictation server** (`Server/`) — opt-in Bonjour service that
  transcribes for paired peers over TLS with a pre-shared key
  (`RemotePairing`); bounded sessions, anonymous advertisement.
- **`WM_SNAPSHOT`** — headless render of every settings panel and onboarding
  step to PNGs (Debug builds only). The fast way to see UI changes.
- **`DIAGNOSTICS` build** — developer-only session tracer, compiled out of
  every shipped build.
- **`PrototypeAppState`** — the single `@Observable` source of truth. The view
  model is the only writer; views read; the tray timer polls.
- **XcodeGen / `project.yml`** — `project.yml` is the source of truth; the
  `.xcodeproj` is generated and git-ignored. Dependencies are declared in both
  `project.yml` and `Package.swift`.
