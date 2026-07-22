import { json, error } from '@sveltejs/kit';
import { supabaseAdmin } from '$lib/server/supabase';
import { resolveUserId } from '$lib/server/resolveUserId';
import type { RequestHandler } from './$types';

// Notes & reminders sync for the macOS app.
//
//   POST { userId, notes[], reminders[] } — upsert the caller's items,
//     last-writer-wins by `updatedAt` (a stale push never clobbers a newer row).
//   GET (?userId=… in shared-token mode) — return the caller's items.
//
// AUTH: same as /api/usage via the shared `resolveUserId`. Unlike usage, the GET
// is Bearer-authenticated (NOT public) and only ever returns the *authenticated*
// user's own items — notes are personal, so there is no public [userId] route.
//
// Storage: Supabase Postgres (Phase 5), snake_case columns. LWW is enforced in
// app code (fetch stored `updated_at`, skip older) rather than a DB trigger, so
// the semantics match the previous Prisma implementation exactly.

interface NotePayload {
  id: string;
  title?: string;
  body?: string;
  createdAt: string;
  updatedAt: string;
  deletedAt?: string | null;
}

interface ReminderPayload extends NotePayload {
  dueDate: string;
  alertStyle?: string;
  soundName?: string;
  repeatRule?: string;
  isCompleted?: boolean;
  firedAt?: string | null;
}

const isIso = (v: unknown): v is string => typeof v === 'string' && !Number.isNaN(Date.parse(v));

function isNote(v: unknown): v is NotePayload {
  if (typeof v !== 'object' || v === null) return false;
  const e = v as Record<string, unknown>;
  return typeof e.id === 'string' && e.id.length > 0 && isIso(e.createdAt) && isIso(e.updatedAt);
}
function isReminder(v: unknown): v is ReminderPayload {
  return isNote(v) && isIso((v as { dueDate?: unknown }).dueDate);
}
const optIso = (v: unknown): string | null => (isIso(v) ? new Date(v).toISOString() : null);

/** Stored `updated_at` per itemId, so we can skip a stale push (last-writer-wins). */
async function existingUpdatedAt(
  table: 'notes' | 'reminders',
  userId: string,
  ids: string[]
): Promise<Map<string, number>> {
  const map = new Map<string, number>();
  if (ids.length === 0) return map;
  const { data, error: qErr } = await supabaseAdmin()
    .from(table)
    .select('item_id, updated_at')
    .eq('user_id', userId)
    .in('item_id', ids);
  if (qErr) throw error(500, qErr.message);
  for (const row of data ?? []) map.set(row.item_id as string, Date.parse(row.updated_at as string));
  return map;
}

export const POST: RequestHandler = async ({ request }) => {
  let body: Record<string, unknown>;
  try {
    body = await request.json();
  } catch {
    throw error(400, 'invalid JSON body');
  }

  const userId = await resolveUserId(request, body.userId as string | undefined);

  const notes = Array.isArray(body.notes) ? body.notes : [];
  const reminders = Array.isArray(body.reminders) ? body.reminders : [];
  if (!notes.every(isNote)) throw error(400, 'each note needs { id, createdAt, updatedAt }');
  if (!reminders.every(isReminder)) throw error(400, 'each reminder needs { id, dueDate, createdAt, updatedAt }');

  const supabase = supabaseAdmin();

  // Notes: keep only rows newer than what's stored, then upsert on (user_id, item_id).
  const noteList = notes as NotePayload[];
  const noteSeen = await existingUpdatedAt('notes', userId, noteList.map((n) => n.id));
  const noteRows = noteList
    .filter((n) => {
      const prev = noteSeen.get(n.id);
      return prev === undefined || prev < Date.parse(n.updatedAt);
    })
    .map((n) => ({
      user_id: userId,
      item_id: n.id,
      title: n.title ?? '',
      body: n.body ?? '',
      created_at: new Date(n.createdAt).toISOString(),
      updated_at: new Date(n.updatedAt).toISOString(),
      deleted_at: optIso(n.deletedAt)
    }));

  // Reminders: same guard.
  const remList = reminders as ReminderPayload[];
  const remSeen = await existingUpdatedAt('reminders', userId, remList.map((r) => r.id));
  const remRows = remList
    .filter((r) => {
      const prev = remSeen.get(r.id);
      return prev === undefined || prev < Date.parse(r.updatedAt);
    })
    .map((r) => ({
      user_id: userId,
      item_id: r.id,
      title: r.title ?? '',
      body: r.body ?? '',
      due_date: new Date(r.dueDate).toISOString(),
      alert_style: r.alertStyle ?? 'notification',
      sound_name: r.soundName ?? 'Glass',
      repeat_rule: r.repeatRule ?? 'none',
      is_completed: r.isCompleted ?? false,
      fired_at: optIso(r.firedAt),
      created_at: new Date(r.createdAt).toISOString(),
      updated_at: new Date(r.updatedAt).toISOString(),
      deleted_at: optIso(r.deletedAt)
    }));

  if (noteRows.length) {
    const { error: e } = await supabase.from('notes').upsert(noteRows, { onConflict: 'user_id,item_id' });
    if (e) throw error(500, e.message);
  }
  if (remRows.length) {
    const { error: e } = await supabase.from('reminders').upsert(remRows, { onConflict: 'user_id,item_id' });
    if (e) throw error(500, e.message);
  }

  return json({ ok: true, notes: notes.length, reminders: reminders.length });
};

export const GET: RequestHandler = async ({ request, url }) => {
  const userId = await resolveUserId(request, url.searchParams.get('userId') ?? undefined);
  const supabase = supabaseAdmin();

  const [noteRes, remRes] = await Promise.all([
    supabase.from('notes').select('*').eq('user_id', userId),
    supabase.from('reminders').select('*').eq('user_id', userId)
  ]);
  if (noteRes.error) throw error(500, noteRes.error.message);
  if (remRes.error) throw error(500, remRes.error.message);

  // Map back to the app's wire shape (its stable `id`, ISO dates, `deletedAt`
  // omitted when null so the Swift optional decodes cleanly).
  const iso = (d: string | null) => d ?? undefined;
  return json({
    notes: (noteRes.data ?? []).map((n) => ({
      id: n.item_id,
      title: n.title,
      body: n.body,
      createdAt: new Date(n.created_at).toISOString(),
      updatedAt: new Date(n.updated_at).toISOString(),
      deletedAt: iso(n.deleted_at)
    })),
    reminders: (remRes.data ?? []).map((r) => ({
      id: r.item_id,
      title: r.title,
      body: r.body,
      dueDate: new Date(r.due_date).toISOString(),
      alertStyle: r.alert_style,
      soundName: r.sound_name,
      repeatRule: r.repeat_rule,
      isCompleted: r.is_completed,
      firedAt: iso(r.fired_at),
      createdAt: new Date(r.created_at).toISOString(),
      updatedAt: new Date(r.updated_at).toISOString(),
      deletedAt: iso(r.deleted_at)
    }))
  });
};
