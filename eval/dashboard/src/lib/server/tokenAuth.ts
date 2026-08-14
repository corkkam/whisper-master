import { timingSafeEqual } from 'node:crypto';

// Constant-time comparison of two shared-secret strings. Length is guarded
// first because `timingSafeEqual` throws on unequal-length buffers — the length
// itself is not the secret, so leaking it via an early return is harmless.
export function tokensMatch(a: string, b: string): boolean {
  const bufA = Buffer.from(a, 'utf8');
  const bufB = Buffer.from(b, 'utf8');
  if (bufA.length !== bufB.length) return false;
  return timingSafeEqual(bufA, bufB);
}
