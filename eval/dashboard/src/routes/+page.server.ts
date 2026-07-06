import { listRuns } from '$lib/server/runs';
import type { RunSummary } from '$lib/types';
import type { Aggregate } from '$lib/scoring';
import type { PageServerLoad } from './$types';

export const load: PageServerLoad = async () => {
  try {
    const rows = await listRuns();
    const runs: RunSummary[] = rows.map((r) => ({
      id: r.id,
      createdAt: r.createdAt.toISOString(),
      label: r.label,
      gitCommit: r.gitCommit,
      branch: r.branch,
      totalRuns: r.totalRuns,
      totalCases: r.totalCases,
      audioCases: r.audioCases,
      aggregate: r.aggregate as unknown as Aggregate
    }));
    return { runs, dbError: null as string | null };
  } catch (e) {
    // No DATABASE_URL / unreachable Atlas — render a setup hint instead of 500.
    return { runs: [] as RunSummary[], dbError: e instanceof Error ? e.message : String(e) };
  }
};
