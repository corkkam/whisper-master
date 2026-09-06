> **Superseded, 2026-08-21.** The sync routes described here as living on the
> eval dashboard now live in the landing-page repo (`app/api/usage`,
> `app/api/usage/[userId]`, `app/api/notes`, auth in `lib/sync/auth.ts`), and
> `eval/dashboard/` has been deleted. The Supabase schema, the Clerk
> verification model and the migration steps below are all still accurate; only
> the file paths and the deploy have moved. Kept as the record of how the
> migration was done.

# Supabase + Clerk integration — beta/stable channel, access gate, sync

Implements the macOS-app side of the handoff (Supabase Option A) plus the
gated landing-page download and the Phase-5 move of per-user sync data off
MongoDB. This doc lists **what changed** and the **manual steps** to make it live.

> **Update (2026-07-22): the app's access gate is now Clerk-native.** The
> Supabase `waitlist_entries` post-sign-in check was removed from the macOS app —
> access is gated purely by **Clerk sign-in** (Clerk waitlist sign-up mode
> enforces approval at account creation, so a signed-in user is by definition
> off the waitlist). The `Supabase/` access code (`SupabaseAccess`,
> `AccessManager`, `AccessState`, `SupabaseConfig`) and the `supabase-swift`
> dependency were deleted, and the Account panel no longer shows a waitlist
> status card. **Usage/notes sync is unchanged** — it still POSTs to the
> dashboard, which remains Supabase-backed. To go live: enable **Waitlist**
> sign-up mode in the Clerk dashboard (Configure → Restrictions → Sign-up mode)
> and approve people in the **Users → Waitlist** tab; existing users (incl.
> `corkkam.info@gmail.com`) keep access since waitlist mode only gates new
> sign-ups. `0004_app_client_rls.sql` is no longer used by the app (harmless if
> left applied).

## What changed (code)

**macOS app (`whisper-master`)**
- `Auth/BetaAccess.swift` — reads Clerk `publicMetadata.betaAccess`; maps to an
  `UpdateChannel` (stable → `appcast.xml`, beta → `appcast-beta.xml`).
- `AppDelegate` — the Sparkle `SPUStandardUpdaterController` now has an
  `SPUUpdaterDelegate` (`feedURLString(for:)`) that picks the feed per check from
  the live beta flag. Dictation entry points now go through `ensureCanDictate()`
  (signed in **and** waitlist `accepted`).
- `Auth/ClerkConfig.swift` + `App/BuildEnvironment.swift` — publishable key is
  chosen per **bundle id**: prod `…mac` and `…beta` → `pk_live_` (production Clerk
  instance); `…mac.dev` / CLI → `pk_test_` (dev instance). Env / Info.plist still
  override. Info.plist no longer hard-codes the dev key.
- `Supabase/` — `SupabaseConfig` (URL + publishable key + schema per build),
  `SupabaseAccess` (direct client, Clerk token as access token, reads the user's
  `waitlist_entries` row), `AccessState`, `AccessManager` (keeps
  `AppState.accessState` fresh from the auth reconcile).
- `UI/Settings/AccountSettingsView.swift` — shows waitlist status/position + a
  "Check again" button.
- `project.yml` / `Package.swift` — add `supabase-swift` (`Supabase` product).

**Landing page (`whisper-master-landing-page`)**
- `app/download/page.tsx` + `lib/config.ts` (`downloads`) + nav link — stable is a
  **public** download; beta is gated on signed-in + `betaAccess === true`.
- `supabase/migrations/0004_app_client_rls.sql` — RLS select policy so the app can
  read its own `waitlist_entries` row as the Clerk user.
- `supabase/migrations/0005_usage_sync_tables.sql` — new `usage_daily`, `notes`,
  `reminders` tables (+ service-role grants and own-row RLS).

**Eval dashboard (`whisper-master/eval/dashboard`)**
- `/api/usage` (POST + `[userId]` GET) and `/api/notes` (POST + GET) now read/write
  **Supabase** (`src/lib/server/supabase.ts`) instead of Prisma/Mongo. Auth
  (Clerk-verified `sub`) and wire shapes are unchanged, so the app's sync clients
  need no change. Eval `Run`/`Result` stay on Mongo.
- `scripts/migrate-mongo-to-supabase.mjs` — one-time copy of existing
  usage/notes/reminders from Mongo → Supabase (idempotent; `--dry-run`).

## Manual steps to go live

1. **Supabase → Authentication → Third-Party Auth → add Clerk**, pointing at the
   Clerk instance domain (prod: `whisper.corkkam.com`; dev instance for the `dev`
   schema). This makes Supabase trust Clerk JWTs so `auth.jwt() ->> 'sub'` = the
   Clerk user id. Ensure Clerk's Supabase integration is on so session tokens carry
   `role: "authenticated"`.

2. **Apply the SQL migrations** (Supabase SQL editor), to **`public`** and — if
   dev/beta builds use the `dev` schema — to **`dev`** (swap `public.` → `dev.`):
   `0004_app_client_rls.sql`, `0005_usage_sync_tables.sql`.

3. **Dashboard env** (Vercel prod+preview *and* local `.env`) — see
   `eval/dashboard/.env.example`: `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`,
   `SUPABASE_DB_SCHEMA` (`public`/`dev`). Keep `CLERK_SECRET_KEY` set so writes stay
   spoof-proof. `npm install` (adds `@supabase/supabase-js`).

4. **Migrate existing data**: from `eval/dashboard`,
   `node scripts/migrate-mongo-to-supabase.mjs --dry-run` then without the flag.
   Verify counts, then the legacy Prisma models + Mongo collections can be dropped.

5. **Regenerate the Xcode project** (picks up the new SPM package):
   `cd whisper-master && xcodegen generate`. `swift build` already resolves it.

6. **Cut the first beta release** (plumbing now built — `Scripts/channel.sh` +
   `CHANNEL=beta` in `bundle.sh`/`release.sh`/`make-dmg.sh`/`publish-dmg.sh`).
   Bump `CFBundleShortVersionString` to `X.Y.Z-beta.1` in `Resources/Info.plist`,
   then from the app repo (with `.env` R2 + notary creds):
   ```bash
   CHANNEL=beta bash Scripts/release.sh      # → appcast-beta.xml + WhisperMaster-<ver>.zip
   CHANNEL=beta bash Scripts/publish-dmg.sh  # → WhisperMaster-beta.dmg (+ versioned)
   ```
   This publishes `appcast-beta.xml` and `WhisperMaster-beta.dmg` to the R2 root
   (EdDSA-signed with the same key; stable's `appcast.xml`/`WhisperMaster.dmg` are
   never touched). **Until this runs once, the gated `/download` beta button 404s.**
   It's a manual flow — CI still ships only stable on a version-bump push to `dev`.

## Notes / decisions

- **Never embed** the Supabase service-role key, Clerk secret key, or DB password
  in the app. Only the client-safe publishable/anon keys are embedded.
- **Phase 5 transport unchanged on purpose.** The app still POSTs sync to the
  dashboard (now Supabase-backed) rather than writing Supabase directly — zero
  regression risk to the shipping app. The RLS in `0005` already supports a future
  direct-write switch with no schema change.
- **Beta uses the production Clerk instance.** Beta and stable users share one
  account and differ only by `betaAccess`; only the `…mac.dev` build uses the dev
  instance + `dev` schema.
