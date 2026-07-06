// Client-side data fetchers + query keys for TanStack Query. Each takes an
// optional `fetch` so a SvelteKit `load` can pass its own (for SSR); on the
// client the global fetch is used.
import type { CasesPage, RunSummary, RunsPage } from './types';

type Fetch = typeof fetch;

export const RUNS_PAGE_SIZE = 12;
export const CASES_PAGE_SIZE = 10;

export interface CaseQuery {
  page: number;
  outcome: 'all' | 'pass' | 'fail';
  source: string;
  q: string;
}

export const emptyCaseQuery = (): CaseQuery => ({ page: 1, outcome: 'all', source: 'all', q: '' });

export const runsKey = (page: number) => ['runs', page] as const;
export const runKey = (id: string) => ['run', id] as const;
export const casesKey = (id: string, q: CaseQuery) => ['run', id, 'cases', q] as const;

export async function fetchRuns(page: number, f: Fetch = fetch): Promise<RunsPage> {
  const r = await f(`/api/runs?page=${page}&pageSize=${RUNS_PAGE_SIZE}`);
  if (!r.ok) throw new Error(`Failed to load runs (${r.status})`);
  return r.json();
}

export async function fetchRun(id: string, f: Fetch = fetch): Promise<RunSummary> {
  const r = await f(`/api/runs/${id}`);
  if (!r.ok) throw new Error(`Failed to load run (${r.status})`);
  return r.json();
}

export async function fetchCases(id: string, q: CaseQuery, f: Fetch = fetch): Promise<CasesPage> {
  const params = new URLSearchParams({
    page: String(q.page),
    pageSize: String(CASES_PAGE_SIZE),
    outcome: q.outcome,
    source: q.source,
    q: q.q
  });
  const r = await f(`/api/runs/${id}/cases?${params}`);
  if (!r.ok) throw new Error(`Failed to load cases (${r.status})`);
  return r.json();
}
