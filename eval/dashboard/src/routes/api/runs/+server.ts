import { json } from '@sveltejs/kit';
import { listRunsPaged } from '$lib/server/runs';
import type { RequestHandler } from './$types';

// GET /api/runs?page=&pageSize=  → paginated run history (newest first).
export const GET: RequestHandler = async ({ url }) => {
  const page = Math.max(1, Number(url.searchParams.get('page')) || 1);
  const pageSize = Math.min(50, Math.max(1, Number(url.searchParams.get('pageSize')) || 12));
  return json(await listRunsPaged(page, pageSize));
};
