import { json, error } from '@sveltejs/kit';
import { env } from '$env/dynamic/private';
import { verifyToken } from '@clerk/backend';
import { supabaseAdmin } from '$lib/server/supabase';
import type { RequestHandler } from './$types';

// POST { userId: string, days: DayEntry[] } — upsert a user's per-day usage rollups.
//
// AUTH — two modes, picked at runtime so a missing optional env never 500s:
//
//   1. Clerk (preferred, trusted): the macOS app sends its Clerk *session token*
//      as `Authorization: Bearer <jwt>`. When CLERK_SECRET_KEY (or CLERK_JWT_KEY)
//      is configured we cryptographically verify the JWT and derive the trusted
//      userId from its `sub` claim, IGNORING body.userId. This is the only
//      spoof-proof path — once configured, an unverifiable token is rejected and
//      we never fall through to (2). Verification uses `@clerk/backend`'s
//      `verifyToken`: networkless when CLERK_JWT_KEY (the instance's PEM public
//      key) is set, else a cached JWKS fetch keyed off CLERK_SECRET_KEY.
//      Optional CLERK_AUTHORIZED_PARTIES (comma-separated) pins the `azp` claim.
//
//   2. Shared token (MVP fallback, SAME pattern as /api/ingest): when Clerk is
//      NOT configured and INGEST_TOKEN is set, require `x-ingest-token` to match;
//      then trust the body's userId. Spoofable — a caller with the shared token
//      can write usage for any userId. Acceptable only for the internal deploy;
//      set CLERK_SECRET_KEY to switch to (1) before opening writes to untrusted
//      multi-tenant clients.

interface DayEntry {
  day: string;
  words: number;
  dictations: number;
  durationSeconds: number;
  fixesWordsCorrected?: number;
  fixesDictionary?: number;
  perApp?: unknown;
}

/**
 * Resolve the trusted userId for this request.
 * Returns the Clerk-verified id when Clerk is configured, otherwise (shared-token
 * mode) validates x-ingest-token and returns the body-supplied id.
 * Throws error(401) when auth fails.
 */
async function resolveUserId(request: Request, bodyUserId: string | undefined): Promise<string> {
  // Normalize unset / blank ("" from .env.example) to undefined so a placeholder
  // never trips Clerk mode or gets passed as an empty option to verifyToken.
  const clerkSecret = env.CLERK_SECRET_KEY?.trim() || undefined;
  const clerkJwtKey = env.CLERK_JWT_KEY?.trim() || undefined;
  if (clerkSecret || clerkJwtKey) {
    // Clerk configured — REQUIRE a verified Bearer token; never fall back to the
    // spoofable body userId once we're in trusted mode.
    const authz = request.headers.get('authorization') ?? '';
    const jwt = authz.toLowerCase().startsWith('bearer ') ? authz.slice(7).trim() : '';
    if (!jwt) throw error(401, 'unauthorized: missing Bearer token');

    const authorizedParties = (env.CLERK_AUTHORIZED_PARTIES ?? '')
      .split(',')
      .map((s) => s.trim())
      .filter(Boolean);

    // `verifyToken` (legacy-return export) resolves to the JWT payload and THROWS
    // on any failure (bad signature, expired, wrong azp, unreachable JWKS).
    let payload: { sub?: string };
    try {
      payload = await verifyToken(jwt, {
        secretKey: clerkSecret,
        jwtKey: clerkJwtKey,
        ...(authorizedParties.length ? { authorizedParties } : {})
      });
    } catch (e) {
      throw error(401, `unauthorized: ${e instanceof Error ? e.message : 'token verification failed'}`);
    }

    const sub = typeof payload.sub === 'string' ? payload.sub : '';
    if (!sub) throw error(401, 'unauthorized: verified token has no subject (sub) claim');
    // Trust the cryptographically-verified subject; ignore any body.userId.
    return sub;
  }

  // Shared-token fallback (MVP). Mirrors /api/ingest exactly.
  const token = env.INGEST_TOKEN;
  if (token && request.headers.get('x-ingest-token') !== token) {
    throw error(401, 'unauthorized: missing or invalid x-ingest-token');
  }
  if (!bodyUserId || typeof bodyUserId !== 'string') {
    throw error(400, 'body.userId (string) is required in shared-token mode');
  }
  return bodyUserId;
}

function isValidDay(d: unknown): d is DayEntry {
  if (typeof d !== 'object' || d === null) return false;
  const e = d as Record<string, unknown>;
  return (
    typeof e.day === 'string' &&
    /^\d{4}-\d{2}-\d{2}$/.test(e.day) &&
    typeof e.words === 'number' &&
    typeof e.dictations === 'number' &&
    typeof e.durationSeconds === 'number'
  );
}

export const POST: RequestHandler = async ({ request }) => {
  let body: Record<string, unknown>;
  try {
    body = await request.json();
  } catch {
    throw error(400, 'invalid JSON body');
  }

  const userId = await resolveUserId(request, body.userId as string | undefined);

  const days = body.days;
  if (!Array.isArray(days)) {
    throw error(400, 'body.days must be an array of day rollups');
  }
  if (!days.every(isValidDay)) {
    throw error(
      400,
      'each day needs { day: "yyyy-MM-dd", words: number, dictations: number, durationSeconds: number }'
    );
  }

  // Upsert into Supabase Postgres (snake_case columns) on the (user_id, day)
  // unique key. A full daily rollup is idempotent, so a plain upsert is correct
  // — no need for the row-level LWW guard the notes route uses.
  const rows = (days as DayEntry[]).map((d) => ({
    user_id: userId,
    day: d.day,
    words: d.words,
    dictations: d.dictations,
    duration_seconds: d.durationSeconds,
    fixes_words_corrected: d.fixesWordsCorrected ?? 0,
    fixes_dictionary: d.fixesDictionary ?? 0,
    per_app: d.perApp ?? {},
    updated_at: new Date().toISOString()
  }));

  const { error: upErr } = await supabaseAdmin()
    .from('usage_daily')
    .upsert(rows, { onConflict: 'user_id,day' });
  if (upErr) throw error(500, upErr.message);

  return json({ ok: true, upserted: days.length });
};
