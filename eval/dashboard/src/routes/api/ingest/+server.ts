import { json, error } from '@sveltejs/kit';
import { parseCases, prepareRun } from '$lib/server/ingest';
import { createRun } from '$lib/server/runs';
import type { RequestHandler } from './$types';

// POST { results: <results.json array>, cases?: <cases.jsonl string>, label?, gitCommit?, branch? }
export const POST: RequestHandler = async ({ request }) => {
  let body: Record<string, unknown>;
  try {
    body = await request.json();
  } catch {
    throw error(400, 'invalid JSON body');
  }

  const results = body.results;
  if (!Array.isArray(results)) {
    throw error(400, 'body.results must be an array (the results.json contents)');
  }

  const rules = parseCases(typeof body.cases === 'string' ? body.cases : null);
  const prepared = prepareRun(results, rules, {
    label: (body.label as string) ?? null,
    gitCommit: (body.gitCommit as string) ?? null,
    branch: (body.branch as string) ?? null
  });

  try {
    const id = await createRun(prepared);
    return json({ id, totalRuns: prepared.totalRuns, totalCases: prepared.totalCases });
  } catch (e) {
    throw error(500, e instanceof Error ? e.message : 'database error. Is DATABASE_URL set?');
  }
};
