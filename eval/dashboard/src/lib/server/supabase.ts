import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import { env } from '$env/dynamic/private';

// Server-only Supabase client using the **service-role** key. Bypasses RLS —
// per-user attribution comes from the Clerk-verified `sub` (see resolveUserId),
// NOT from the client, so this must never reach the browser.
//
// Phase 5: the app's per-user sync data (usage_daily, notes, reminders) moved
// off MongoDB into Supabase Postgres. Eval Run/Result still live in Mongo via
// Prisma — this client only backs the sync routes.
//
// Env (Vercel + local .env):
//   SUPABASE_URL                (or NEXT_PUBLIC_SUPABASE_URL — reused if present)
//   SUPABASE_SERVICE_ROLE_KEY
//   SUPABASE_DB_SCHEMA          public (prod) | dev — defaults to public
const SCHEMA = env.SUPABASE_DB_SCHEMA?.trim() || 'public';

let cached: SupabaseClient | undefined;

export function supabaseAdmin(): SupabaseClient {
  if (cached) return cached;
  const url = (env.SUPABASE_URL || env.NEXT_PUBLIC_SUPABASE_URL || '').trim();
  const key = (env.SUPABASE_SERVICE_ROLE_KEY || '').trim();
  if (!url || !key) {
    throw new Error('SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY must be set');
  }
  cached = createClient(url, key, {
    // Cast: no generated DB types here, so the client's schema generic defaults
    // to "public" (same shim the landing page's createAdminClient uses).
    db: { schema: SCHEMA as 'public' },
    auth: { autoRefreshToken: false, persistSession: false }
  });
  return cached;
}
