import { fetchRuns } from '$lib/api';
import type { PageLoad } from './$types';

// SSR the first page of runs so first paint is server-rendered and shareable;
// TanStack Query takes over on the client (pagination, refetch). A DB outage is
// surfaced as a friendly notice rather than a 500 error page.
export const load: PageLoad = async ({ fetch }) => {
  try {
    const initial = await fetchRuns(1, fetch);
    return { initial, dbError: null as string | null };
  } catch (e) {
    return { initial: null, dbError: e instanceof Error ? e.message : 'Database not reachable' };
  }
};
