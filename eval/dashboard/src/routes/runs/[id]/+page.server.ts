import { error } from '@sveltejs/kit';
import { getRun } from '$lib/server/runs';
import { groupByCase, type ResultDTO, type RunSummary } from '$lib/types';
import type { Aggregate } from '$lib/scoring';
import type { PageServerLoad } from './$types';

export const load: PageServerLoad = async ({ params }) => {
  let run;
  try {
    run = await getRun(params.id);
  } catch (e) {
    throw error(500, e instanceof Error ? e.message : 'Database error');
  }
  if (!run) throw error(404, 'Run not found');

  const results: ResultDTO[] = run.results.map((r) => ({
    caseId: r.caseId,
    category: r.category,
    source: r.source,
    target: r.target,
    inputKind: r.inputKind,
    deterministic: r.deterministic,
    llmOutput: r.llmOutput,
    guardAccepted: r.guardAccepted,
    wer: r.wer,
    latencyMs: r.latencyMs as unknown as Record<string, number>,
    asrText: r.asrText,
    asrReference: r.asrReference,
    mechanicalPass: r.mechanicalPass,
    attribution: r.attribution,
    reasons: r.reasons
  }));

  const summary: RunSummary = {
    id: run.id,
    createdAt: run.createdAt.toISOString(),
    label: run.label,
    gitCommit: run.gitCommit,
    branch: run.branch,
    totalRuns: run.totalRuns,
    totalCases: run.totalCases,
    audioCases: run.audioCases,
    aggregate: run.aggregate as unknown as Aggregate
  };

  return { run: summary, cases: groupByCase(results) };
};
