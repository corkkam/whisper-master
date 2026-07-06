import { fetchRun, fetchCases, emptyCaseQuery } from '$lib/api';
import type { PageLoad } from './$types';

// SSR the run summary + the first (default-filter) page of cases; TanStack Query
// takes over for filtering + pagination on the client.
export const load: PageLoad = async ({ params, fetch }) => {
  try {
    const [run, cases] = await Promise.all([
      fetchRun(params.id, fetch),
      fetchCases(params.id, emptyCaseQuery(), fetch)
    ]);
    return { id: params.id, run, cases, loadError: null as string | null };
  } catch (e) {
    return {
      id: params.id,
      run: null,
      cases: null,
      loadError: e instanceof Error ? e.message : 'Failed to load run'
    };
  }
};
