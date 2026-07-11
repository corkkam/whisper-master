import { json, error } from '@sveltejs/kit';
import { env } from '$env/dynamic/private';
import { prisma } from '$lib/server/db';
import type { RequestHandler } from './$types';

// POST { userId: string, days: DayEntry[] } — upsert a user's per-day usage rollups.
//
// AUTH — two modes, picked at runtime so a missing optional env never 500s:
//
//   1. Clerk (preferred, trusted): the macOS app sends its Clerk *session token*
//      as `Authorization: Bearer <jwt>`. When CLERK_SECRET_KEY (or a JWKS/issuer
//      env) is configured we verify the JWT and derive the trusted userId from
//      its `sub` claim, IGNORING body.userId. This is the only spoof-proof path.
//
//      TODO(clerk): wire real verification once `@clerk/backend` is a dependency:
//        import { verifyToken } from '@clerk/backend';
//        const { sub } = await verifyToken(jwt, { secretKey: env.CLERK_SECRET_KEY });
//      Install hint: `npm i @clerk/backend` in eval/dashboard, then set
//      CLERK_SECRET_KEY (and optionally CLERK_JWT_ISSUER) in the Vercel + local
//      env. Until then the Bearer token is NOT verified and we fall through to (2).
//
//   2. Shared token (MVP fallback, SAME pattern as /api/ingest): when
//      INGEST_TOKEN is set, require `x-ingest-token` to match; then trust the
//      body's userId. MVP: spoofable without Clerk verification — a caller with
//      the shared token can write usage for any userId. Acceptable for the
//      current single-tenant/internal deploy; replace with (1) before multi-user.

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
  const clerkSecret = env.CLERK_SECRET_KEY;
  if (clerkSecret) {
    // Clerk configured — REQUIRE a verified Bearer token; never fall back to the
    // spoofable body userId once we're in trusted mode.
    const authz = request.headers.get('authorization') ?? '';
    const jwt = authz.toLowerCase().startsWith('bearer ') ? authz.slice(7).trim() : '';
    if (!jwt) throw error(401, 'unauthorized: missing Bearer token');
    // TODO(clerk): replace with real verifyToken() once @clerk/backend is added.
    // Verification is not implemented yet, so a configured CLERK_SECRET_KEY
    // cannot be honored securely — refuse rather than trust an unverified token.
    throw error(
      401,
      'Clerk verification is configured but not yet implemented (add @clerk/backend)'
    );
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

  try {
    await Promise.all(
      (days as DayEntry[]).map((d) => {
        const data = {
          words: d.words,
          dictations: d.dictations,
          durationSeconds: d.durationSeconds,
          fixesWordsCorrected: d.fixesWordsCorrected ?? 0,
          fixesDictionary: d.fixesDictionary ?? 0,
          // Store perApp as-is (defaults to {}); Prisma Json accepts any JSON value.
          perApp: (d.perApp ?? {}) as object
        };
        return prisma.usageDaily.upsert({
          where: { userId_day: { userId, day: d.day } },
          update: data,
          create: { userId, day: d.day, ...data }
        });
      })
    );
  } catch (e) {
    throw error(500, e instanceof Error ? e.message : 'database error. Is DATABASE_URL set?');
  }

  return json({ ok: true, upserted: days.length });
};
