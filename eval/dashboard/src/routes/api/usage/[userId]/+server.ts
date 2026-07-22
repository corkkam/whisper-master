import { json, error } from '@sveltejs/kit';
import { supabaseAdmin } from '$lib/server/supabase';
import type { RequestHandler } from './$types';

// GET /api/usage/<userId> → that user's daily usage rows, oldest→newest.
// Reads are public (same policy as the rest of the dashboard).
// Backed by Supabase Postgres (Phase 5); snake_case columns are mapped back to
// the camelCase wire shape callers already expect.
export const GET: RequestHandler = async ({ params }) => {
  const { data, error: qErr } = await supabaseAdmin()
    .from('usage_daily')
    .select(
      'day, words, dictations, duration_seconds, fixes_words_corrected, fixes_dictionary, per_app, updated_at'
    )
    .eq('user_id', params.userId)
    .order('day', { ascending: true });

  if (qErr) throw error(500, qErr.message);

  const days = (data ?? []).map((r) => ({
    userId: params.userId,
    day: r.day,
    words: r.words,
    dictations: r.dictations,
    durationSeconds: r.duration_seconds,
    fixesWordsCorrected: r.fixes_words_corrected,
    fixesDictionary: r.fixes_dictionary,
    perApp: r.per_app,
    updatedAt: r.updated_at
  }));

  return json({ userId: params.userId, days });
};
