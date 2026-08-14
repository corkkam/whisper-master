import { json, error } from '@sveltejs/kit';
import { supabaseAdmin } from '$lib/server/supabase';
import { resolveUserId } from '$lib/server/resolveUserId';
import type { RequestHandler } from './$types';

// GET /api/usage/<userId> → that user's daily usage rows, oldest→newest.
// The path `userId` is NOT trusted: the caller is resolved via `resolveUserId`,
// which in Clerk mode returns the verified token `sub` (ignoring the path param,
// so a caller can only ever read its OWN usage) and in shared-token mode still
// requires the x-ingest-token. This closes the IDOR — `supabaseAdmin()` bypasses
// RLS, so the query MUST filter on the resolved id, never the raw path param.
// Backed by Supabase Postgres (Phase 5); snake_case columns are mapped back to
// the camelCase wire shape callers already expect.
export const GET: RequestHandler = async ({ params, request }) => {
  const userId = await resolveUserId(request, params.userId);

  const { data, error: qErr } = await supabaseAdmin()
    .from('usage_daily')
    .select(
      'day, words, dictations, duration_seconds, fixes_words_corrected, fixes_dictionary, per_app, updated_at'
    )
    .eq('user_id', userId)
    .order('day', { ascending: true });

  if (qErr) throw error(500, qErr.message);

  const days = (data ?? []).map((r) => ({
    userId,
    day: r.day,
    words: r.words,
    dictations: r.dictations,
    durationSeconds: r.duration_seconds,
    fixesWordsCorrected: r.fixes_words_corrected,
    fixesDictionary: r.fixes_dictionary,
    perApp: r.per_app,
    updatedAt: r.updated_at
  }));

  return json({ userId, days });
};
