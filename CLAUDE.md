# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A standalone macOS menu-bar app prototype for local-first streaming dictation, built on `FluidAudio` + NVIDIA Parakeet. **Intentionally separate** from the sibling project `/Users/ninja/coding/lyzr-exprmt/lyzr-whisper` — do not cross-modify; this is the sandbox for evaluating on-device streaming ASR on Apple Silicon.

## Commands

This is an **Xcode project**, generated from `project.yml` by [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `project.yml` is the source of truth; the `.xcodeproj` is git-ignored and regenerated. `Package.swift` is kept so `swift build` still works for quick CLI compile checks, but the shippable `.app` is produced by Xcode.

```bash
# First time / after editing project.yml or adding source files
brew install xcodegen        # one-time
xcodegen generate            # (re)creates WhisperMaster.xcodeproj
open WhisperMaster.xcodeproj # work in Xcode normally

# Quick compile check (no .app bundle)
swift build

# Run the test suite (pure unit tests — fast, no models, no audio)
swift test

# Replay recorded audio through the real streaming pipeline (regression bench)
swift test --filter AudioReplayTests

# Build + sign the distributable .app (xcodegen → xcodebuild → stage)
bash Scripts/bundle.sh                       # → build/Whisper Master.app (Release, signed "whisper master")
CONFIG=Debug bash Scripts/bundle.sh          # debug-config variant
SIGN_IDENTITY=- bash Scripts/bundle.sh       # ad-hoc instead of the keychain cert

# DMG (chains through bundle.sh)
bash Scripts/make-dmg.sh                # full rebuild + DMG
REBUILD=0 bash Scripts/make-dmg.sh      # repackage existing .app only

# One-shot install: build → quit running instance → replace /Applications/Whisper Master.app → relaunch
bash Scripts/install.sh
REBUILD=0 bash Scripts/install.sh       # skip rebuild
RELAUNCH=0 bash Scripts/install.sh      # install without launching

# Ship a Sparkle auto-update — bump CFBundleShortVersionString AND
# CFBundleVersion in Resources/Info.plist first, then:
bash Scripts/release.sh                 # build → sign → appcast → upload to R2
REBUILD=0 bash Scripts/release.sh       # re-upload without rebuilding
```

### Tests

`Tests/WhisperMasterTests/` (SwiftPM test target, declared in `Package.swift`
only — the Xcode app target is untouched). Run with `swift test`.

- **Pure unit tests** — fast, deterministic, no models/network/audio. Cover the
  text-processing pipeline: `FillerWordFilter`, `VocabularyTermParser`,
  `VocabularyPostProcessor`, `CorrectionDetector`, `TranscriptMerger.bestEffort`.
  These run everywhere (CI, fresh clone) and should stay green.
- **`AudioReplayTests`** — a regression *bench*, not a pure unit test. It replays
  real recordings through the actual `FluidAudioStreamingTranscriber` streaming
  path (feeding a file reproduces live streaming exactly — windowing keys off
  absolute sample position) and writes results to `.context/test-audio/results.md`
  (git-ignored scratch). The reference recordings live in
  `Tests/WhisperMasterTests/Fixtures/audio/` (committed: `paragraph-N.m4a` +
  `paragraphs.md`, ~1.2 MB), so the bench runs in any clone / CI. The harness
  **also** scans `.context/test-audio/` so you can drop ad-hoc local recordings
  there without committing them (same-named file: the committed fixture wins). It
  **skips** (never fails) when no recordings are found. Run with
  `swift test --filter AudioReplayTests`. This bench is how the FluidAudio
  streaming-vocabulary corruption bug was found and verified — use it to validate
  any change to the transcription/post-processing pipeline before shipping.

**Custom vocabulary is post-processing, not engine biasing.** FluidAudio's
streaming CTC vocabulary rescorer corrupts transcripts (empties vocab-dense
utterances, truncates others — proven by `AudioReplayTests`), so it is **not
used**. `VocabularyPostProcessor` applies the glossary as a safe whole-word
text replacement on the finished transcript instead. Do not re-enable
`configureVocabularyBoosting` to "improve accuracy" — it regresses correctness.

**Deterministic ITN, and why it must not sum digit sequences.** The finished
transcript runs through `DeterministicTextFormatter` → `DeterministicITN.normalize`
(the default `TextFormatting`; the Apple on-device LLM formatter is opt-in only).
This is a pure, rule-based inverse-text-normalization engine — spoken numbers →
digits, currency, %, times, emails — written in Swift (no model, instant,
deterministic). `SpokenNumber.value` combines number words **additively**, which
is only valid for a tens word (20–90) + a ones word (1–9) ("twenty five" → 25) or
across a scale word ("one hundred twenty three" → 123). A run of bare unit words
like "one two three" is a spoken *sequence*, not a cardinal, so it must return
`nil` and stay as words — **do not** let it fall through to the additive sum,
which produced the "mic testing one two three" → "mic testing 6" bug (1+2+3).
When a run isn't a well-formed cardinal, `convertNumbers` emits the *whole* run as
words rather than digitizing a trailing token. **Room/suite numbers** spoken as
digit-chunks ("room two oh five" → "room 205", "room two fourteen" → 214) are
read by a room-keyword-gated pass (`matchRoomNumber`) as a concatenated digit
sequence, **not** a clock time — without the gate `matchTime` greedily turned
them into "2:05"/"2:14". Cover any ITN change with
`DeterministicITNTests` (fast, pure). A heavier long-term alternative — swapping
this hand-rolled engine for FluidInference's `text-processing-rs` (a Rust/NeMo
ITN port with Swift xcframework bindings, same vendor as FluidAudio) — was
evaluated but not adopted: it adds a native binary + build/signing complexity for
coverage we don't yet need.

**Spoken number self-corrections collapse deterministically, before ITN.**
`SelfCorrectionCollapser` (pure, `SelfCorrectionCollapserTests`) rewrites
"twenty five no forty dollars" → "forty dollars", "three no four thirty" →
"four thirty", and chains "twenty no thirty no forty units" → "forty units"
(keep-last). It fires **only** when a number run flanks a correction marker
(`no` / `no wait` / `no actually` / `actually` / `i mean` / `scratch that` /
`or rather`) on both sides, so ordinary "no"/"actually" in running speech is
never touched. It runs in the shipped pipeline (`DictationViewModel`, right after
`TranscriptSpacingRepair`, before `DeterministicITN`) **and** the eval runner, in
the same order — keep them in sync. Name-correction chains ("call john no jane no
actually mike") can't be number-gated safely, so they stay with the LLM (a chain
example in `CleanupPrompt`); a 3B model still misses some — a known limitation.

### Evaluation engine (`eval/text-cleanup/`)

A quality-first eval for the cleanup pipeline, split by the nature of the code:
**durable logic is Swift, disposable glue is shell, Claude Code is the judge.**
Spec + plan: `docs/superpowers/specs/2026-07-06-eval-engine-design.md`,
`docs/superpowers/plans/2026-07-06-eval-engine.md`.

- **Grade the real pipeline, never a proxy.** `Sources/WhisperMaster/Eval/EvalRunner.swift`
  is a dev-only in-app runner: set `WM_EVAL_CASES=<cases.jsonl>` (+ optional
  `WM_EVAL_OUT`), launch the built app **via LaunchServices (`open`), not the raw
  binary**, and after the MLX model loads it runs every text case through the
  shipped deterministic passes (`TranscriptSpacingRepair` → `SelfCorrectionCollapser`
  → `DeterministicITN` → `FillerWordFilter` → `VocabularyPostProcessor`) + both LLM modes (`light`,
  `polish`) with the **real** `CleanupFaithfulnessGuard`, grouped by target so the
  KV cache stays primed, and writes `results.json` (per-stage outputs, guard
  verdict, per-stage latency). **Directly exec'ing the bundle's Mach-O crashes**
  (TCC can't find the Info.plist usage strings → the mesh CoreBluetooth scan hard-
  crashes); pass env vars to `open` via `launchctl setenv`.
- **`eval-score`** — a dependency-free SwiftPM library (`EvalScoreKit`: `EvalCase`
  schema loader, `WER`, `Scorer`) + CLI (`swift run eval-score <results.json>
  <cases.jsonl>`). Objective scoring only: keyword `must_contain`/`must_not_contain`
  + WER threshold, with failures attributed to **ASR vs cleanup**. The **guard
  verdict is diagnostic, not a pass/fail criterion** (Swift `Scorer` + the
  dashboard `scoring.ts` port, kept in sync): a guard *rejection* means the safe
  deterministic fallback was used, and for a faithfulness case that fallback is
  the correct result that satisfies the keyword rules — so it must not be marked
  failed; an unfaithful *acceptance* is still caught by `must_not_contain`. Unit
  tests: `swift test --filter EvalScoreKitTests`.
- **Claude Code is the judge.** After a run, Claude reads `results.json` and writes
  `judgment.md` (faithfulness + quality per target, light-vs-polish, latency,
  recommendations) — the subjective call keyword rules can't make. No API key, no
  sub-agents.
- **Cases** (`cases.jsonl`, generalized schema: `input:{text|audio}`, `targets`,
  `reference`, `asr_reference`, keyword rules). `targets` is the extension hinge:
  `light`+`polish` today, `slack`/`email`/`code` later with no engine change.
  Audio cases are generated into git-ignored `.eval-scratch/` by two scripts:
  `make_audio.sh` (TTS every text case via `say`; ffmpeg-gated Bluetooth-HFP +
  pink-noise augmentation for the realistic/disfluency subset) and
  `fetch_librispeech.sh` (a slice of **LibriSpeech dev-clean**, openslr.org
  CC BY 4.0, the real-human WER anchor — the tarball is fetched, sliced, and
  deleted). `ffmpeg` (Homebrew) is required only for augmentation + LibriSpeech
  flac→m4a.
- **Findings so far** (`judgment.md`): Parakeet is near-perfect on real clean
  speech (**3.4% mean WER** on LibriSpeech); the ASR bottleneck is **noise
  (23.5%) and Bluetooth-HFP (16.3%)**, not clean-condition hearing. The
  experimental `polish` mode originally **answered questions** ("capital of
  france" → "…Paris") — fixed by an anti-answer rule in the guard (reject a
  mid-sentence capitalized entity the input never had); `polish` stays
  off-by-default/experimental regardless.
- **Run history + public dashboard (`eval/dashboard/`):** a SvelteKit + Prisma 6 +
  MongoDB Atlas app that stores runs over time and renders them for a **public**
  audience. `src/lib/scoring.ts` is a TS port of `EvalScoreKit` so runs score
  identically (guard verdict diagnostic, as above).
  - **Deployed on Vercel** (`@sveltejs/adapter-vercel`, nodejs20.x) at
    **https://whisper-eval-dashboard.vercel.app**; the GitHub integration
    **auto-deploys from `dev`** (Vercel project **Root Directory = `eval/dashboard`**
    + an ignored-build-step `git diff --quiet HEAD^ HEAD -- .` so it only rebuilds
    when the dashboard changes). Manual redeploy: `vercel --prod` from
    `eval/dashboard`. **`dev` must carry the `adapter-vercel` + auth commits** or a
    deploy builds wrong/unsecured.
  - **Prisma on Vercel:** `binaryTargets = ["native","rhel-openssl-3.0.x"]` in
    `schema.prisma`, and `build` runs `prisma generate` first (Vercel caches deps
    and can skip postinstall).
  - **Env** (Vercel prod+preview *and* local `.env`): `DATABASE_URL` — any Atlas
    cluster is a replica set, but **the SRV string must include a db name in the
    path** (`…mongodb.net/evaldash?…`) or Prisma rejects it P1013 — and
    `INGEST_TOKEN`.
  - **Reads are public; writes are not.** `POST /api/ingest` requires an
    `x-ingest-token` header equal to `INGEST_TOKEN` (else 401); `push-run` sends it
    (from the env or the dashboard `.env`).
  - **Data:** SSR-hybrid **`@tanstack/svelte-query` v6** (runes) — `load` SSRs page 1
    as `initialData`, the client paginates with `keepPreviousData` against
    `GET /api/runs?page=` and `GET /api/runs/[id]/cases?page=` (Prisma stays behind
    those endpoints). UI matches the app's **light-only Daylight** theme (white
    canvas, brick `#c0381a`; Fraunces/Inter, mono for transcripts only); the home
    hero is a rotating real before/after "watch it work" demo + a pipeline flow.
  - **Ingest is not automatic:** after an eval writes `results.json` it must be
    pushed — one-shot `eval/text-cleanup/run-eval.sh [cases.jsonl] [label]`
    (launches the app via `launchctl setenv` + `open`, waits for `results.json`,
    pushes; `DASHBOARD_URL` retargets to prod, `NO_PUSH=1` skips). `push-run` is the
    manual equivalent. Local dev: `npm run db:push` then `npm run dev`.

### Toolchain & prerequisites

- **Apple Silicon, macOS 14+.** Build is **arm64-only**; deployment target macOS 14.0. Developed on macOS 26 / **Xcode 26.5**; Swift language mode **5.0** (`SWIFT_VERSION` in `project.yml`).
- **Full Xcode is required** (not just Command Line Tools — the macro plugins / app target need it). Point the toolchain at it and verify:
  ```bash
  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
  xcodebuild -version              # must show Xcode, not CommandLineTools
  sudo xcodebuild -license accept
  ```
- **CLI tools (Homebrew):** `brew install xcodegen rclone` — XcodeGen generates the project; rclone uploads to R2.

### Dependencies (SPM)

Declared in **both** `project.yml` (source of truth for the app target) and `Package.swift` (so `swift build` + the editor resolve) — keep the two in sync when adding/bumping:
- **FluidAudio** ≥ 0.14.7 — on-device ASR (NVIDIA Parakeet) + the CTC keyword model used for vocabulary biasing.
- **Sparkle** ≥ 2.6 (resolves 2.9.x) — auto-update. Xcode embeds/signs the framework automatically; replicating that by hand is the main reason the project moved off the old SwiftPM-only bundle onto an Xcode app target.

Product: `WhisperMaster.app`, bundle id `app.whispermaster.mac`, executable `WhisperMaster`; distributed as `Whisper Master.app` / `.dmg`.

### How we build

`project.yml` → `xcodegen generate` → `WhisperMaster.xcodeproj` (git-ignored) → `xcodebuild`. Day-to-day: open the `.xcodeproj` in Xcode, or `swift build` for a fast headless compile check (no `.app`). Shippable `.app`: `Scripts/bundle.sh` (xcodegen → `xcodebuild -configuration Release` → stage to `build/Whisper Master.app`).

### Signing & keys (Developer ID + notarization)

- **Code signing:** a **Developer ID Application** cert (Team ID `7MFYAGK3VV`, "subrahmanya s hegde"), created in Xcode → Settings → Accounts → Manage Certificates → + → *Developer ID Application*. `bundle.sh` & `release.sh` default `SIGN_IDENTITY="Developer ID Application"`; pass `SIGN_IDENTITY=-` for an ad-hoc local build. The build enables the **hardened runtime** (`ENABLE_HARDENED_RUNTIME: YES` in `project.yml`) with `Resources/WhisperMaster.entitlements` (only `com.apple.security.device.audio-input` — non-sandboxed; text injection uses Accessibility/TCC, Bonjour needs no entitlement). `bundle.sh` also passes `--timestamp` (secure timestamp, required by notarization) and `CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO` (so the debug-only `get-task-allow` is never injected — the notary service rejects it). The old self-signed **`whisper master`** cert is retired.
- **Notarization:** `Scripts/notarize.sh <path-to-.app-or-.dmg>` submits to Apple's notary service (`xcrun notarytool submit --wait`) and staples the ticket (`xcrun stapler staple`). `release.sh` notarizes+staples the `.app` *before* zipping (the ticket travels in the Sparkle zip); `make-dmg.sh` staples the `.app` then the `.dmg`. **Credentials** (first match wins, read from env / `.env`): `NOTARY_KEY_P8`+`NOTARY_KEY_ID`+`NOTARY_ISSUER` (App Store Connect API key), or `NOTARY_PROFILE` (a name saved once via `xcrun notarytool store-credentials`), or `NOTARY_APPLE_ID`+`NOTARY_PASSWORD`+`NOTARY_TEAM_ID`. If none are set, notarization is **skipped** (build still produced, just not notarized). Notarized + stapled means **no more first-launch `xattr -dr com.apple.quarantine`** — installs and DMG mounts are warning-free.
- **Update signing:** a Sparkle **EdDSA** keypair (Sparkle's `bin/generate_keys`; private key lives in the login keychain, public key is `SUPublicEDKey` in `Info.plist`). Export for CI with `generate_keys -x <file>`. This is independent of the code-signing cert, so the self-signed→Developer ID switch is seamless for already-installed testers (Sparkle validates the unchanged EdDSA key).

### Distribution & auto-update (Sparkle + Cloudflare R2)

- **Hosting:** R2 bucket `whisper-master`, served via the **custom domain `https://model.scoopscore.in`** (Cloudflare CDN — edge-cached, no rate limit). The old `https://pub-033f6365404f4b37ac6c630d4feb0dcd.r2.dev` dev URL is the same bucket and is kept enabled so already-installed apps (with the old `SUFeedURL`) keep polling; new builds use the custom domain. S3 (upload) endpoint `https://db4d52dbca4f08ab7bd161955d66ed6a.r2.cloudflarestorage.com`. Credentials in `.env` (git-ignored; template `.env.example`): `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_ENDPOINT`, `R2_BUCKET`, `R2_PUBLIC_BASE_URL`.
- **Layout on R2:** `appcast.xml` + `WhisperMaster-<version>.zip` at the bucket root; model archives under `models/`.
- **`release.sh`** = build+sign (`bundle.sh`) → zip → Sparkle `generate_appcast` (EdDSA-signs, sets the enclosure URL via `--download-url-prefix`) → `rclone` upload of the staged dir. It reads `.env` locally; in CI it reads the same vars from the environment and the EdDSA key from `SPARKLE_ED_PRIVATE_KEY` instead of the keychain.
- **Versioning:** bump **both** `CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist` before a manual release, or Sparkle won't treat it as newer.
- **⚠️ Never republish a version number.** Each release must use a *new* `CFBundleShortVersionString`, because the archive filename is `WhisperMaster-<version>.zip`. Re-shipping the same version overwrites that file with different bytes while testers/CDN may still hold the old ones — the appcast's `sparkle:edSignature` is computed for the *new* bytes, so Sparkle downloads (possibly Cloudflare-edge-cached) mismatched bytes and fails with **"The update is improperly signed and could not be validated."** This bites silently after a **`git revert`**: the revert changes the code but leaves `CFBundleShortVersionString` unchanged, so the next CI run rebuilds the *same* version with different content. **Fix when it happens:** bump to a fresh version (new filename Cloudflare has never cached) and ship that — do **not** try to re-upload the broken version. The signing certs/EdDSA keys are almost never the actual cause; verify by comparing the served zip's `sign_update` signature against the appcast before blaming signing.

### CI/CD (GitHub Actions)

- Repo is **private** (`HEGADE/whisper-master`); default branch `main`, active work on `dev`.
- **`.github/workflows/release.yml`** has two jobs. A cheap **`gate`** job (Ubuntu, 1× billing) checks whether `CFBundleShortVersionString` changed versus `github.event.before`; only if it did (or on manual `workflow_dispatch`) does the **`release`** job run on `macos-15`: checkout → `brew install xcodegen rclone` → import the **Developer ID** cert from secrets into a temporary keychain → set `CFBundleVersion` to **epoch seconds** (`date +%s`) so it always strictly increases and can't be undercut by an earlier manual build → decode the notary `.p8` → run `release.sh` (which build+sign+**notarize+staple**s). Add **`[skip release]`** to the commit message to skip even a version-bump push.
- **Required repo secrets:** `DEVELOPER_ID_CERT_P12_BASE64` (base64 of the Developer ID `.p12`), `DEVELOPER_ID_CERT_PASSWORD`, `NOTARY_KEY_P8_BASE64` (base64 of the App Store Connect `AuthKey_*.p8`), `NOTARY_KEY_ID`, `NOTARY_ISSUER`, `SPARKLE_ED_PRIVATE_KEY`, plus the five `R2_*` values above. (The CI workflow decodes the `.p8` to `$RUNNER_TEMP` and exports `NOTARY_KEY_P8` for `notarize.sh`.)
- macOS runner minutes bill **~10×** and the Apple notary wait keeps the runner allocated for the whole submission (often 5–30 min today), so each release run is expensive (~hundreds of billed minutes). The **version-bump `gate`** is the primary cost guard — a normal `dev` push that doesn't change `CFBundleShortVersionString` only burns a few Ubuntu seconds; `[skip release]` remains a manual override.
- **Two independent skip switches (don't confuse them):** `[skip release]` skips the *whole* macOS `release` job (no build/sign/notarize/upload — nothing ships). `[skip announce]` still runs the full release (builds, signs, notarizes, uploads to R2 — testers **do** get the Sparkle update) but skips **only** the final Telegram announcement step (`if: !contains(head_commit.message, '[skip announce]')`). So to ship a build without posting to the group, bump the version **and** add `[skip announce]`.

### Release flow, end to end (two ways)

A "release" = put a newer, EdDSA-signed `.zip` + an updated `appcast.xml` on R2; installed apps then self-update via Sparkle. There are two ways to trigger it:

**A. Manual (from your Mac):**
1. Bump **both** `CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist` (e.g. `PlistBuddy -c "Set :CFBundleShortVersionString 0.1.9" -c "Set :CFBundleVersion 11" Resources/Info.plist`).
2. `bash Scripts/release.sh` → `xcodegen generate` → `xcodebuild -configuration Release` (signed `whisper master`) → `ditto` zip → Sparkle `generate_appcast` (signs the zip with the keychain EdDSA key, writes `appcast.xml` pointing at the R2 public URL) → `rclone` uploads `appcast.xml` + `WhisperMaster-<ver>.zip` to the bucket root.
3. Verify: `curl -s "$R2_PUBLIC_BASE_URL/appcast.xml"` shows the new `sparkle:version`.

**B. CI (push to `dev`):** `git push origin dev` (commit message without `[skip release]`) → the workflow does the same as (A) on a macOS runner, but sets `CFBundleVersion` = **epoch seconds** automatically (always strictly increasing; you still bump `CFBundleShortVersionString` in commits when you want a new human version). Secrets supply the cert + EdDSA key + R2 creds.

**What a tester sees:** their installed app's Sparkle polls `SUFeedURL`, sees a higher `CFBundleVersion`, downloads the signed zip, swaps the app in place, and relaunches — no reinstall. Builds are now **Developer ID-signed and notarized**, so first-ever installs open without any Gatekeeper warning — the `xattr -dr com.apple.quarantine` step is no longer needed.

### Release announcements (Telegram) — the commit message IS the post

After a successful CI release, `Scripts/notify-telegram.py` (final step in `release.yml`) posts to the Telegram group `Corkkam.com` (chat id stored in the `TELEGRAM_CHAT_ID` secret; bot token in `TELEGRAM_BOT_TOKEN`) **and attaches the built app zip** (`build/sparkle/WhisperMaster-<version>.zip` — the Sparkle archive, i.e. the actual `.app`, not a DMG) so people download it straight from the group. **No LLM is involved** — the announcement text is taken verbatim from the release commit message, so write that message as finished, post-ready copy:

- The **body** of the release commit (everything after the subject line) is posted verbatim as the announcement, then reused for X/Twitter. **Write it like a human tweeting, not like release notes.** This is the part to get right — the default tone tends to read AI-generated; actively avoid that:
  - Sound like a person: casual, first-person-ish, contractions, plain words. Lowercase-y is fine. Short punchy lines.
  - Lead with the single thing a user actually cares about. Don't open with a tidy headline like "Fresh X and smoother Y."
  - **Banned AI tells:** the "This release redesigns/introduces/brings…" framing, balanced tricolons (three things joined by em-dashes), "now with X" parentheticals, "seamless/effortless/powerful/robust," marketing CTAs ("Download right here"), and more than one emoji.
  - **No dashes.** Don't use em dashes (—) or hyphens as sentence punctuation in the announcement. Break the thought into separate sentences with periods or commas instead. (Dashes read as an AI tell.)
  - Keep it short enough to paste into X (a few lines, well under 280 chars). No hashtags, no markdown. Don't claim features that aren't in the release.
  - **Bad (AI slop, don't do this):** "Fresh onboarding and smoother updates. This release redesigns the first-run setup (now with a notifications step), makes update alerts actually show up, and adds a gentle nudge when a Bluetooth mic is hurting audio quality — one tap switches you to the built-in mic. Download the app right here. 🎙️"
  - **Good (human, tweetable):** "new build's up 🎙️ setup's way cleaner, update alerts actually fire now, and if a bluetooth mic is wrecking your audio it'll nudge you to switch to the built-in one (one tap). file's attached, give it a spin."
- If the release commit has **no body**, the script falls back to a `🚀 Whisper Master <version>` heading plus a bullet list of the commit subjects since the last `v*` tag — so even subjects should read as user-facing release-note lines (`Merge`, `release:`, `bump`, and `[skip release]` commits are filtered out).
- The version header and download link are NOT auto-added when a body is present — put whatever headline/version mention you want in the body itself. A `[skip release]` trailer is stripped from the posted text.
- The step is `continue-on-error` and no-ops without the Telegram secrets, so a notification hiccup never fails a release.
- **To release without announcing:** put `[skip announce]` in the commit message. The release job still builds/signs/notarizes/uploads (the Sparkle update ships to testers) — only this Telegram step is skipped. This is distinct from `[skip release]`, which skips the entire release.

**Publishing a model to R2** (separate from app releases): from `~/Library/Application Support/FluidAudio/Models`, `ditto -c -k --keepParent <dir> <dir>.zip`, then `rclone` it to `whisper-master/models/` (creds from `.env`). Done for the engine (`parakeet-tdt-0.6b-v3`) and CTC (`parakeet-ctc-110m-coreml`) models; the app installs them mirror-first via `ModelInstaller`.

## Architecture

### Process / window model

- **Regular Dock app** — `LSUIElement = false` (Info.plist) + `setActivationPolicy(.regular)` (AppMain) → shows a Dock icon and an app menu (`AppDelegate.setupMainMenu`). The menu-bar `NSStatusItem` is still the primary surface, but macOS hides it when the menu bar is crowded (notch), so the Dock icon is the reliable way back in. (Was previously an `.accessory`/`LSUIElement=true` agent with no Dock icon.)
- `AppDelegate` is the single owner of all top-level objects: the status item, settings window, dictation pill window, hotkey manager, permissions manager, and a dedicated `MicrophoneCaptureService` instance for the onboarding mic test (separate from the one inside `PrototypeViewModel`, since both create their own `AVAudioEngine`).
- `applicationShouldTerminateAfterLastWindowClosed → false`: closing the settings window must NOT quit the app — the tray is the persistent surface. The `NSStatusItem` uses `autosaveName` so users can drag its position and it sticks across launches.
- A 0.5s `Timer` in `AppDelegate.startStatusRefreshLoop` polls `PrototypeAppState` and rebuilds the tray icon symbol, tooltip, header line, and history submenu. There's no `@Observable` bridge to AppKit — the timer is the bridge.

### State (`PrototypeAppState`)

Single `@Observable` source of truth, `@MainActor`-bound. The view model mutates it; SwiftUI views observe it; AppDelegate's tray refresher polls it. Includes:

- `phase: PrototypePhase` (idle/preparingModels/recording/stopping/failed)
- Engine selection state — `selectedEngine`, `preparedEngine`, `preparingEngine` are three distinct slots (do not collapse them; the UI distinguishes "user has chosen X" from "X is currently being downloaded" from "X is ready to use").
- `history: [TranscriptHistoryEntry]` — persisted in `UserDefaults` under `WhisperMaster.transcriptHistory.v1`, capped at 50 entries (newest first). `appendHistory` is the only entry point; bypassing it skips persistence.

### Transcription engine

`TranscriberEngine` has a **single case**, `slidingWindow` ("Heavy", NVIDIA Parakeet `parakeet-tdt-0.6b-v3`), implemented by `FluidAudioStreamingTranscriber` (conforms to `LocalStreamingTranscriber`, `Sendable`). An earlier "Light"/EOU streaming engine **and** an Apple Foundation Models transcript-cleanup pass were both removed — the LLM added latency without gains since Parakeet already emits punctuation/capitalization. The enum is kept (one case) for metadata + future engines. `PrototypeViewModel.transcriber` is now a single stored property. Models download on demand into `~/Library/Application Support/FluidAudio/Models/<cacheDirectoryName>`; `TranscriberEngine.isInstalled` is a filesystem check, so callers must not cache it. (The removed cleanup pass above was the *Apple Foundation Models* one; a separate **opt-in MLX qwen cleanup** was later added — see below.)

### On-device Smart cleanup (MLX qwen — opt-in, off by default)

Optional post-ASR cleanup by **qwen2.5-3B-Instruct-4bit via MLX** (`mlx-swift-examples`). Two Settings toggles: **Smart cleanup** (`llmCleanupEnabled` — light: fix self-corrections/false starts) and **Polish my English** (`llmGrammarPolishEnabled` — heavier rephrase to grammatical English). Dictation **never waits** on it: the deterministic text pastes instantly and, on the **native** path, the qwen polish refines it *in place* a beat later (`scheduleRefinement`); on the **web/Electron** path (no safe in-place edit) polish is computed *before* the ⌘V. Pieces:
- **`MlxCleanupService`** (`actor`) — loads the model once and reuses a persistent system-prompt **KV cache** (feeds only the per-call delta). `clean()` returns `nil` on any problem so the caller keeps the deterministic text — cleanup can only ever help, never block. The load is **timeout-bounded (`loadTimeoutSeconds` 60 s) and retried** by the manager: a stalled MLX/Metal init (seen under launch-time GPU contention) used to wedge the state `.loading` forever, so Settings showed "Preparing…" indefinitely while polish silently no-op'd. Load/prime timing is logged.
- **`CleanupModelManager`** (`@MainActor`, owned by `DictationViewModel`) — reconciles the toggle each refresh tick, drives the **mirror-first background download** (`ModelInstaller`, R2 archive `Qwen2.5-3B-Instruct-4bit`, HF fallback), retries the load up to 3×, and surfaces status to `AppState`: `cleanupModelReady` / `cleanupModelFailed` (→ Settings shows **"Couldn't load — Retry"**, `cleanupRetryRequested` re-attempts) / `cleanupModelReadyAt` (one notch banner). Progress shows **only in Settings**.
- **`CleanupFaithfulnessGuard`** (pure, `CleanupFaithfulnessGuardTests`) — rejects the LLM output (→ keep deterministic) when it **invents** content (answers/translates/codes/injects), balloons, or grossly truncates; `allowRephrase` loosens it for polish mode. **Known limitation, do not "fix":** it catches *added* content but not a *dropped* content word ("meant to be born" → "meant to be"). A deterministic word-counter can't tell that from a legitimate self-correction ("john i mean jane" → "Jane") or compression ("gonna go" → "going") — a content-retention rule was tried and **reverted** because it rejected those. So polish occasionally drops a word; that's why "Polish my English" is **experimental/off-by-default**. Verify any cleanup change against the real pipeline via `eval/text-cleanup/run-eval.sh` (it grades the shipped passes + both LLM modes + the real guard).

**Model install is mirror-first.** `ModelInstaller` (in `ModelInstall/`, with `BackgroundFileDownloader` + `DownloadResumeStore` + `Archive`) is archive-based — `installIfNeeded(archiveName:destinationRoot:label:maxAttempts:isInstalled:onProgress:)` downloads `<archiveName>.zip` from the public R2 bucket and unpacks it into `destinationRoot`, with an accurate % (R2 returns a real `Content-Length`). It **retries** the download+unpack (`maxAttempts`, default 2). The download is **resumable**: `BackgroundFileDownloader` uses a **background `URLSession`** (owned by `nsurlsessiond`, keyed by a fixed identifier) writing to a *stable* path `<destinationRoot>/.downloads/<archiveName>.zip`, so an interrupted 1.5 GB transfer resumes instead of restarting from zero — it reattaches to a transfer the daemon kept running across an app quit, else resumes from persisted `NSURLSessionDownloadTaskResumeData`, else starts fresh. `DownloadResumeStore` persists the URL→destination map (so a transfer the daemon finishes while the app is quit is moved into place on the next launch) and the resume token, both under `.downloads/`; `AppDelegate` touches `BackgroundFileDownloader.shared` at launch so replayed completion events drain before any new download decision. Timeouts are **bounded** (120 s stall / 24 h resource, not the 7-day URLSession default). Only after retries are exhausted does it fall back to FluidAudio's HuggingFace download — and that fallback is **loud, not silent**: logged at `.error` via `Log.modelPrep` (subsystem `app.whispermaster.mac`, persisted to the unified log) and surfaced in the UI (`AppState.usingFallbackModelSource` → "downloading from backup source (slower)"). Note `TranscriberEngine.isInstalled` validates the **actual compiled files** (each required `.mlmodelc`'s `coremldata.bin`), not just that the folder exists — a half-deleted/partial install correctly re-fetches from the mirror instead of masquerading as ready (which used to drop it to the slow HF path). This whole chain was the cause of the intermittent "model loading stuck" bug: a bare-folder `isInstalled` + silent HF fallback + no download timeout. A `TranscriberEngine` convenience overload covers the main engine (`DictationViewModel.installModelsFromMirror`, before `prepareModels`); the CTC vocabulary model uses the generic form. **Both the engine model and the CTC model are hosted on R2.** To publish/refresh an archive: from the models root (`~/Library/Application Support/FluidAudio/Models`), `ditto -c -k --keepParent <dir> <dir>.zip`, then upload to `whisper-master/models/` on R2 (same creds as `release.sh`).

**Custom vocabulary (biasing).** Users maintain a glossary — `PrototypeAppState.customVocabulary` (persisted under `WhisperMaster.customVocabulary.v1`), edited in the Voice-engine **"Words to get right"** field (a raw `@State` draft parsed one-way to `[String]`; don't reintroduce a normalizing two-way binding or Enter/multiline breaks). `FluidAudioStreamingTranscriber.setVocabulary` stores terms (cheap); `loadVocabularyResources` loads FluidAudio's CTC keyword model (R2-first, ~89 MB, guarded against duplicate loads) in the **background** and calls `configureVocabularyBoosting`, biasing decoding toward those terms (e.g. "RAG" not "rack"). It's warmed right after the main engine is ready (`refreshCustomVocabulary`) and re-applied after each session's manager recreation in `stop()`/`cancel()`, so it never blocks recording and is best-effort. Biasing is CTC acoustic rescoring with thresholds — short acronyms are the hard case; tune via `CustomVocabularyTerm` weight/aliases if needed.

### Recording lifecycle (PrototypeViewModel)

`startRecording` → `prepareSelectedEngineIfNeeded` (model download with progress callbacks updating `state.download`) → `transcriber.start(updateHandler:)` → `microphoneCapture.start(...)`. Audio buffers from the mic tap are funneled through `enqueueAudioBuffer` which spawns a per-buffer `Task` so the tap callback never blocks; `drainPendingAudioBuffers` awaits them all on stop. There's an intentional `releaseTailNanoseconds` sleep on stop to let the last audio frames flush before tearing down — don't remove it.

**Microphone capture + the Bluetooth "call mode" issue (`MicrophoneCaptureService`).** A Bluetooth headset can't do hi-fi A2DP playback and mic input at once — the moment any app records from its mic, macOS forces it into the low-quality **HFP "call" profile** (mono, ~8 kHz), degrading both playback *and* the signal we transcribe. This is a **hard Bluetooth limitation, not something an app can tune around.** The reliable fix is for the **user** to set their input to the built-in mic (System Settings → Sound → Input); then the earphones stay in hi-fi and dictation captures a cleaner wideband signal. **⚠️ Do NOT add code that programmatically juggles audio devices to "auto-fix" this — it was tried three times (0.3.5–0.3.6) and every variant broke something:** (1) forcing an input-only device onto `AVAudioEngine` via `kAudioOutputUnitProperty_CurrentDevice` → engine can't start when the output device differs (broke recording); (2) swapping the system default input to built-in for the recording and restoring it on stop → re-routes every recording, races ("works once then stuck"); (3) switching the default input via `kAudioHardwarePropertyDefaultInputDevice` then immediately creating an `AVAudioEngine` and reading `inputNode` HW format → **hung in Core Audio** (`GetHWFormat` blocked on `coreaudiod`, app unresponsive, couldn't even quit). The capture service is intentionally back to the simple known-good form: reuse one `AVAudioEngine`, capture from the system default input, **no device manipulation in the recording path** — leave it that way. The **safe** way to help (shipped): `BluetoothInputMonitor` (read-only poll, off-main) detects a Bluetooth default input and sets `AppState.bluetoothInputActive`; the notch then shows `NotchBluetoothBanner` ("Bluetooth mic lowers quality → Use built-in") and, only when the *user taps it*, `AudioInputDevices.switchToBuiltInMic()` does **one** `kAudioHardwarePropertyDefaultInputDevice` set off the main thread (the same op as Sound settings), while idle and nowhere near the engine. That decoupling — user-initiated, off-main, not in the capture flow — is what makes it safe vs. the auto-switch that hung. The pill panel is click-through except while the banner is up (`DictationPillWindow.setInteractive`, driven by `AppState.shouldShowBluetoothBanner` from the refresh loop).

**Mic warm-start (safe, shipped).** A cold `AVAudioEngine.start()` pays a Core Audio HAL negotiation (**~300–500 ms**, measured via the DIAGNOSTICS traces) that clipped the first words of a push-to-talk and read as a "loader → wave" lag in the notch. `MicrophoneCaptureService.prewarm()` — called once at launch after mic permission — does a brief **tap-less** `start()`/`stop()` to bring the input driver into residency, cutting the first real `start()` to **~70 ms**; `startAutoRewarm()` re-warms on a read-only `kAudioHardwarePropertyDevices` listener so a topology change (AirPods connect/disconnect) can't leave the warm stale. This warms **our own engine only — no device manipulation** — so it stays clear of the hazards above. **AirPods-connected is an irreducible exception:** while AirPods are connected macOS re-arbitrates the Bluetooth route on *every* mic-input `start()` (~350 ms) and that cost isn't cacheable across `stop()`; the only way to kill it is a permanently-hot mic, which we don't do.

Transcript merging (`mergedConfirmedTranscript`, `partialRemainder`, `longestSuffixPrefixOverlap`) handles streaming overlap between successive partial/confirmed updates from the engine — partial transcripts can re-emit text the confirmed stream has already locked in.

### Gentle reminders (`Reminders/`)

Because the app lives in the notch with no window to return to, a user can forget it exists. The fix is a **gentle nudge reused through the existing notch surface** — not a native `UNUserNotification`: when the app has been idle a while, the black notch band drops down with a short friendly line (`NotchReminderBanner`) for ~5s, silent and click-through, then retracts. Four small pieces: `ReminderPolicy` (pure, deterministic — takes `now`, holds all tunable timing: 3h baseline → 6h → 12h backoff, daily cap, display duration), `ReminderBookkeeping` (Codable cadence state persisted under `WhisperMaster.reminders.v1`), `ReminderCopy` (the rotating lines), and `ReminderScheduler` (`@MainActor` driver, owned by `DictationViewModel` — the sole `AppState` writer — that consults the policy and sets `AppState.activeReminder`). The **AppDelegate 0.5s refresh loop** calls `viewModel.evaluateReminders()` each tick (idle-gated, cheap). A completed dictation calls `reminderScheduler.noteUsed()`, resetting backoff to the friendly baseline; `startRecording` calls `clear()` so the live indicator never collides with a reminder. Safety rests on three independent layers, not on context detection (which was deliberately dropped — no DND/Focus, meeting, or screen-share detection): the artifact is intrinsically gentle, a Settings **"Gentle reminders"** toggle (`AppState.remindersEnabled`, **off by default — opt-in**; while off the scheduler is dormant and resets its cadence so a later opt-in starts a fresh idle gap) is a hard off-switch, and the conservative cadence means few firings. Spec: `docs/superpowers/specs/2026-06-30-gentle-notch-reminders-design.md`.

### UI

- `OnboardingWindow` — 5-step wizard (Welcome → Microphone → Accessibility → Mic test → Done). The mic test uses the AppDelegate-owned `onboardingMic` (not the view model's), runs while the test page is on screen, and stops on `onDisappear`. Step indicator dots, auto-advance on permission grant.
- `PrototypeView` — settings window. `NavigationSplitView` + `Form(.grouped)` for the macOS System-Settings look. Sidebar sections: Recording / Voice engine / History / Permissions / About. When the model isn't installed at launch, `autoFocusSetupIfNeeded` jumps the user to the Engine panel; `setupBanner` is rendered at the top of every panel while preparation is in flight.
- `DictationPillWindow` / `PrototypePillView` — floating pill showing audio level + transcription state. `state.hidePillWhenIdle` controls visibility between recordings.
- `DesignTokens.swift` defines `Palette`, `Typography`, and a `card()` modifier. Kept around but the current `PrototypeView` mostly uses native system colors / form styling; new UI should prefer native materials over the custom palette unless there's a specific reason.

### Text injection

`TextInjector` (actor) synthesizes keystrokes via `CGEvent` in 20-UTF16-unit chunks. Requires Accessibility permission; the view model gates injection on `permissionsManager.accessibilityGranted()` and surfaces a "copied to clipboard, enable Accessibility" message on miss rather than failing silently.

**Paste routing (`pasteFinal` + `FocusedElementInspector`).** Auto-paste picks a mechanism from what Accessibility reports at the focused element: a settable / text-role field → instant per-char keystroke inject + in-place refine (**native**); an element with **no caret** (`kAXSelectedTextRange` absent), not settable, not a text role → **nowhere to type** → clipboard + the `NotchUndeliveredBanner` "press ⌘V" hint (`focusHasNoTextTarget`); anything else ambiguous (a web/Electron field exposes a caret even when AX won't label it a text field) → a real **⌘V** (`TextInjector.pressCommandV` via `pasteViaClipboard`), which web content honors where per-char `keyboardSetUnicodeString` is dropped. `pasteFinal` returns the text it *actually* pasted (polished on the web path) so the diagnostics trace records reality, not the pre-polish string. **Chrome hides its AX tree by default** (focused element reports `role=none` whether or not a text box is focused), so the nowhere-to-type banner can't fire there without risking the working paste — a known gap; the text still lands in history (tray → paste last).

### Diagnostics (local-only, `DIAGNOSTICS` build)

A developer-only session tracer, **compiled out of every shipped build**. Gated behind the `DIAGNOSTICS` compile flag: **`DIAGNOSTICS=1 bash Scripts/install.sh`** builds a **Release-optimized** app (so latency/RTF numbers are real) with the tracer on; CI never sets the flag, so `Diagnostics.shared` is a `NoopDiagnostics` and no session data or audio is ever written on a tester's machine. Spec: `docs/superpowers/specs/2026-07-09-diagnostics-session-tracing-design.md`. Each dictation writes a `SessionTrace` to `~/Library/Application Support/WhisperMaster/Diagnostics/` (pretty JSON + a mono WAV of the captured audio + an `index.ndjson` summary; newest 100 kept): a latency **timeline** (key-down → notch → engine → mic warmup → first partial/confirmed → each deterministic stage → paste), **audio** stats (device, is-Bluetooth, sample rate, RMS/peak/clip), the **raw-ASR → per-stage → final** text chain, the **target app** + focus AX snapshot + paste outcome, and the live **LLM verdict** (`llmReady`/`llmRaw`/`llmAccepted`/`llmMs`, captured on the beforePaste path — distinguishes "model no-op" vs "guard rejected" vs "not ready"). This is the instrument for diagnosing field reports ("it misses words / mic feels bad / it's slow") from real recordings instead of guesses; `Scripts/diag-to-cases.swift` turns saved sessions into an audio `cases.jsonl` for the eval/replay harness. Modular under `Diagnostics/` (`SessionTrace`, `AudioSignalStats`, `SessionAudioWriter`, `DiagnosticsStore`, `DiagnosticsRecorder`, `Diagnostics` facade; pure units unit-tested in `DiagnosticsTests`). The facade no-ops without the flag, so call sites in `DictationViewModel`/capture carry no `#if`.

### Hotkey

`HotkeyManager` watches `NSEvent.flagsChanged` (both local + global monitors) to detect modifier-key press/release for push-to-talk. Each `HotkeyOption` carries its own `keyCode` and `modifierBit`. Hold-to-talk vs toggle is decided by `state.holdToTalkEnabled` inside the view model's `handleHotkeyPressed/Released`.

## Conventions to keep

- `@MainActor` annotation on classes that touch UI/AppKit; never call them off the main actor.
- `Sendable` on the transcriber protocol — buffer/update closures cross actor boundaries.
- The view model is the ONLY thing that mutates `PrototypeAppState`. Views read; AppDelegate polls; nothing else writes.
- Don't introduce a second status item or second settings window; the AppDelegate's single-instance ownership is load-bearing.
