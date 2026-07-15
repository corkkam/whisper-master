import { json, error } from '@sveltejs/kit';
import { prisma } from '$lib/server/db';
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
const optDate = (v: unknown): Date | null => (isIso(v) ? new Date(v) : null);

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

  try {
    // Guarded upsert: skip a row whose stored copy is newer (last-writer-wins).
    await Promise.all([
      ...(notes as NotePayload[]).map(async (n) => {
        const existing = await prisma.note.findUnique({
          where: { userId_itemId: { userId, itemId: n.id } }
        });
        if (existing && existing.updatedAt >= new Date(n.updatedAt)) return;
        const data = {
          title: n.title ?? '',
          body: n.body ?? '',
          createdAt: new Date(n.createdAt),
          updatedAt: new Date(n.updatedAt),
          deletedAt: optDate(n.deletedAt)
        };
        return prisma.note.upsert({
          where: { userId_itemId: { userId, itemId: n.id } },
          update: data,
          create: { userId, itemId: n.id, ...data }
        });
      }),
      ...(reminders as ReminderPayload[]).map(async (r) => {
        const existing = await prisma.reminderItem.findUnique({
          where: { userId_itemId: { userId, itemId: r.id } }
        });
        if (existing && existing.updatedAt >= new Date(r.updatedAt)) return;
        const data = {
          title: r.title ?? '',
          body: r.body ?? '',
          dueDate: new Date(r.dueDate),
          alertStyle: r.alertStyle ?? 'notification',
          soundName: r.soundName ?? 'Glass',
          repeatRule: r.repeatRule ?? 'none',
          isCompleted: r.isCompleted ?? false,
          firedAt: optDate(r.firedAt),
          createdAt: new Date(r.createdAt),
          updatedAt: new Date(r.updatedAt),
          deletedAt: optDate(r.deletedAt)
        };
        return prisma.reminderItem.upsert({
          where: { userId_itemId: { userId, itemId: r.id } },
          update: data,
          create: { userId, itemId: r.id, ...data }
        });
      })
    ]);
  } catch (e) {
    throw error(500, e instanceof Error ? e.message : 'database error. Is DATABASE_URL set?');
  }

  return json({ ok: true, notes: notes.length, reminders: reminders.length });
};

export const GET: RequestHandler = async ({ request, url }) => {
  const userId = await resolveUserId(request, url.searchParams.get('userId') ?? undefined);

  const [noteRows, reminderRows] = await Promise.all([
    prisma.note.findMany({ where: { userId } }),
    prisma.reminderItem.findMany({ where: { userId } })
  ]);

  // Map back to the app's wire shape (its stable `id`, ISO dates, `deletedAt`
  // omitted when null so the Swift optional decodes cleanly).
  const iso = (d: Date | null) => (d ? d.toISOString() : undefined);
  return json({
    notes: noteRows.map((n) => ({
      id: n.itemId,
      title: n.title,
      body: n.body,
      createdAt: n.createdAt.toISOString(),
      updatedAt: n.updatedAt.toISOString(),
      deletedAt: iso(n.deletedAt)
    })),
    reminders: reminderRows.map((r) => ({
      id: r.itemId,
      title: r.title,
      body: r.body,
      dueDate: r.dueDate.toISOString(),
      alertStyle: r.alertStyle,
      soundName: r.soundName,
      repeatRule: r.repeatRule,
      isCompleted: r.isCompleted,
      firedAt: iso(r.firedAt),
      createdAt: r.createdAt.toISOString(),
      updatedAt: r.updatedAt.toISOString(),
      deletedAt: iso(r.deletedAt)
    }))
  });
};
