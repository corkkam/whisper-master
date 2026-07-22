#!/usr/bin/env node
// One-time migration: copy per-user sync data (usage_daily, notes, reminders)
// from the old MongoDB collections into Supabase Postgres (Phase 5).
//
// Reads from Mongo via Prisma (DATABASE_URL) and upserts into Supabase with the
// service-role key. Idempotent — safe to re-run; upserts on the natural keys
// (user_id,day) / (user_id,item_id). Eval Run/Result are NOT touched.
//
// Usage:
//   node scripts/migrate-mongo-to-supabase.mjs           # migrate everything
//   node scripts/migrate-mongo-to-supabase.mjs --dry-run # count only, no writes
//
// Env (from the environment or the dashboard .env):
//   DATABASE_URL               Mongo (Prisma source)
//   SUPABASE_URL               Supabase project URL   (or NEXT_PUBLIC_SUPABASE_URL)
//   SUPABASE_SERVICE_ROLE_KEY  service-role key (server-only)
//   SUPABASE_DB_SCHEMA         public (default) | dev
import { readFileSync } from 'node:fs';
import { PrismaClient } from '@prisma/client';
import { createClient } from '@supabase/supabase-js';

const DRY = process.argv.includes('--dry-run');

// Node doesn't auto-load dotenv; pull any missing var from the dashboard .env.
function envFile() {
  try {
    return readFileSync(new URL('../.env', import.meta.url), 'utf8');
  } catch {
    return '';
  }
}
const ENV_TEXT = envFile();
function env(name) {
  if (process.env[name]) return process.env[name];
  const m = ENV_TEXT.match(new RegExp(`^${name}\\s*=\\s*"?([^"\\n]+)"?`, 'm'));
  return m ? m[1] : undefined;
}

const supabaseUrl = env('SUPABASE_URL') || env('NEXT_PUBLIC_SUPABASE_URL');
const serviceKey = env('SUPABASE_SERVICE_ROLE_KEY');
const schema = env('SUPABASE_DB_SCHEMA') || 'public';
if (!supabaseUrl || !serviceKey) {
  console.error('error: SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY must be set');
  process.exit(2);
}

const prisma = new PrismaClient();
const supabase = createClient(supabaseUrl, serviceKey, {
  db: { schema },
  auth: { autoRefreshToken: false, persistSession: false }
});

const iso = (d) => (d ? new Date(d).toISOString() : null);

async function upsertBatched(table, rows, onConflict) {
  if (DRY || rows.length === 0) return;
  const SIZE = 500;
  for (let i = 0; i < rows.length; i += SIZE) {
    const chunk = rows.slice(i, i + SIZE);
    const { error } = await supabase.from(table).upsert(chunk, { onConflict });
    if (error) throw new Error(`${table} upsert failed: ${error.message}`);
  }
}

async function main() {
  console.log(`Migrating Mongo → Supabase (schema "${schema}")${DRY ? ' [dry run]' : ''}`);

  // ── usage_daily ────────────────────────────────────────────────────────
  const usage = await prisma.usageDaily.findMany();
  await upsertBatched(
    'usage_daily',
    usage.map((u) => ({
      user_id: u.userId,
      day: u.day,
      words: u.words,
      dictations: u.dictations,
      duration_seconds: u.durationSeconds,
      fixes_words_corrected: u.fixesWordsCorrected,
      fixes_dictionary: u.fixesDictionary,
      per_app: u.perApp ?? {},
      updated_at: iso(u.updatedAt)
    })),
    'user_id,day'
  );
  console.log(`  usage_daily: ${usage.length} rows`);

  // ── notes ──────────────────────────────────────────────────────────────
  const notes = await prisma.note.findMany();
  await upsertBatched(
    'notes',
    notes.map((n) => ({
      user_id: n.userId,
      item_id: n.itemId,
      title: n.title,
      body: n.body,
      created_at: iso(n.createdAt),
      updated_at: iso(n.updatedAt),
      deleted_at: iso(n.deletedAt)
    })),
    'user_id,item_id'
  );
  console.log(`  notes: ${notes.length} rows`);

  // ── reminders ────────────────────────────────────────────────────────────
  const reminders = await prisma.reminderItem.findMany();
  await upsertBatched(
    'reminders',
    reminders.map((r) => ({
      user_id: r.userId,
      item_id: r.itemId,
      title: r.title,
      body: r.body,
      due_date: iso(r.dueDate),
      alert_style: r.alertStyle,
      sound_name: r.soundName,
      repeat_rule: r.repeatRule,
      is_completed: r.isCompleted,
      fired_at: iso(r.firedAt),
      created_at: iso(r.createdAt),
      updated_at: iso(r.updatedAt),
      deleted_at: iso(r.deletedAt)
    })),
    'user_id,item_id'
  );
  console.log(`  reminders: ${reminders.length} rows`);

  console.log(DRY ? 'Dry run complete (no writes).' : 'Migration complete.');
}

main()
  .catch((e) => {
    console.error(e);
    process.exit(1);
  })
  .finally(() => prisma.$disconnect());
