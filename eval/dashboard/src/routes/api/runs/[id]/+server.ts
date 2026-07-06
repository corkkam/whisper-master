import { json, error } from '@sveltejs/kit';
import { getRunSummary } from '$lib/server/runs';
import type { RequestHandler } from './$types';

// GET /api/runs/:id  → one run's metadata + aggregate (no result rows).
export const GET: RequestHandler = async ({ params }) => {
  const run = await getRunSummary(params.id);
  if (!run) throw error(404, 'run not found');
  return json(run);
};
