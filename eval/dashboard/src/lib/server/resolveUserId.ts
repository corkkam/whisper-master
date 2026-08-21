import { error } from '@sveltejs/kit';
import { env } from '$env/dynamic/private';
import { verifyToken } from '@clerk/backend';
import { tokensMatch } from '$lib/server/tokenAuth';

// Trusted per-user attribution, shared by /api/usage and /api/notes.
//
// Two modes, picked at runtime so a missing optional env never 500s:
//   1. Clerk (preferred): verify the `Authorization: Bearer <jwt>` session token
//      and derive userId from its `sub` claim, IGNORING the fallback id. Once
//      CLERK_SECRET_KEY (or CLERK_JWT_KEY) is set this is the ONLY accepted path
//      — an unverifiable/absent token is rejected (401).
//   2. Shared token (MVP fallback): when Clerk is NOT configured and INGEST_TOKEN
//      is set, require `x-ingest-token` to match, then trust the caller-supplied
//      id (spoofable — internal deploy only).
//
// `fallbackUserId` is the caller-supplied id used only in shared-token mode:
// `body.userId` for POST, the `userId` query param for GET.
export async function resolveUserId(
  request: Request,
  fallbackUserId: string | undefined
): Promise<string> {
  const clerkSecret = env.CLERK_SECRET_KEY?.trim() || undefined;
  const clerkJwtKey = env.CLERK_JWT_KEY?.trim() || undefined;
  if (clerkSecret || clerkJwtKey) {
    const authz = request.headers.get('authorization') ?? '';
    const jwt = authz.toLowerCase().startsWith('bearer ') ? authz.slice(7).trim() : '';
    if (!jwt) throw error(401, 'unauthorized: missing Bearer token');

    const authorizedParties = (env.CLERK_AUTHORIZED_PARTIES ?? '')
      .split(',')
      .map((s) => s.trim())
      .filter(Boolean);

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
    return sub;
  }

  // Fail CLOSED: with neither Clerk nor a non-empty shared token configured we
  // would otherwise trust the caller-supplied id. Treat "" (the .env.example
  // placeholder) as unset.
  const token = env.INGEST_TOKEN?.trim() || undefined;
  if (!token) {
    throw error(
      500,
      'server auth is not configured: set CLERK_SECRET_KEY/CLERK_JWT_KEY or a non-empty INGEST_TOKEN'
    );
  }
  if (!tokensMatch(request.headers.get('x-ingest-token') ?? '', token)) {
    throw error(401, 'unauthorized: missing or invalid x-ingest-token');
  }
  if (!fallbackUserId || typeof fallbackUserId !== 'string') {
    throw error(400, 'userId (string) is required in shared-token mode');
  }
  return fallbackUserId;
}
