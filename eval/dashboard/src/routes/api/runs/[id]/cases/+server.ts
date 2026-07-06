import { json, error } from '@sveltejs/kit';
import { getRunCases, type CaseFilters } from '$lib/server/runs';
import type { RequestHandler } from './$types';

// GET /api/runs/:id/cases?page=&pageSize=&outcome=&source=&q=  → paginated,
// filtered cases (light+polish grouped per case).
export const GET: RequestHandler = async ({ params, url }) => {
  const f: CaseFilters = {
    page: Math.max(1, Number(url.searchParams.get('page')) || 1),
    pageSize: Math.min(50, Math.max(1, Number(url.searchParams.get('pageSize')) || 10)),
    outcome: (url.searchParams.get('outcome') as 'all' | 'pass' | 'fail') ?? 'all',
    source: url.searchParams.get('source') ?? 'all',
    q: url.searchParams.get('q') ?? ''
  };
  const res = await getRunCases(params.id, f);
  if (!res) throw error(404, 'run not found');
  return json(res);
};
