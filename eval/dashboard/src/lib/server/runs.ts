import type { Prisma } from '@prisma/client';
import { prisma } from './db';
import type { PreparedRun } from './ingest';
import type { Aggregate } from '$lib/scoring';
import {
  groupByCase,
  type CasesPage,
  type ResultDTO,
  type RunSummary,
  type RunsPage
} from '$lib/types';

const RUN_SUMMARY_SELECT = {
  id: true,
  createdAt: true,
  label: true,
  gitCommit: true,
  branch: true,
  totalRuns: true,
  totalCases: true,
  audioCases: true,
  aggregate: true
} as const;

type RunSummaryRow = Prisma.RunGetPayload<{ select: typeof RUN_SUMMARY_SELECT }>;

function toRunSummary(r: RunSummaryRow): RunSummary {
  return {
    id: r.id,
    createdAt: r.createdAt.toISOString(),
    label: r.label,
    gitCommit: r.gitCommit,
    branch: r.branch,
    totalRuns: r.totalRuns,
    totalCases: r.totalCases,
    audioCases: r.audioCases,
    aggregate: r.aggregate as unknown as Aggregate
  };
}

function toResultDTO(r: Prisma.ResultGetPayload<object>): ResultDTO {
  return {
    caseId: r.caseId,
    category: r.category,
    source: r.source,
    target: r.target,
    inputKind: r.inputKind,
    deterministic: r.deterministic,
    llmOutput: r.llmOutput,
    guardAccepted: r.guardAccepted,
    wer: r.wer,
    latencyMs: (r.latencyMs as Record<string, number>) ?? {},
    asrText: r.asrText,
    asrReference: r.asrReference,
    mechanicalPass: r.mechanicalPass,
    attribution: r.attribution,
    reasons: r.reasons
  };
}

/** Persist a scored run (metadata + all result rows) and return its id. */
export async function createRun(run: PreparedRun): Promise<string> {
  const created = await prisma.run.create({
    data: {
      label: run.label,
      gitCommit: run.gitCommit,
      branch: run.branch,
      totalRuns: run.totalRuns,
      totalCases: run.totalCases,
      audioCases: run.audioCases,
      aggregate: run.aggregate as unknown as Prisma.InputJsonValue,
      results: {
        create: run.results.map((r) => ({
          caseId: r.caseId,
          category: r.category,
          source: r.source,
          target: r.target,
          inputKind: r.inputKind,
          deterministic: r.deterministic,
          llmOutput: r.llmOutput,
          guardAccepted: r.guardAccepted,
          wer: r.wer,
          latencyMs: r.latencyMs as unknown as Prisma.InputJsonValue,
          asrText: r.asrText,
          asrReference: r.asrReference,
          mechanicalPass: r.mechanicalPass,
          attribution: r.attribution,
          reasons: r.reasons
        }))
      }
    },
    select: { id: true }
  });
  return created.id;
}

/** Run list for the history view — metadata + aggregate, no heavy result rows. */
export async function listRuns() {
  return prisma.run.findMany({
    orderBy: { createdAt: 'desc' },
    select: {
      id: true,
      createdAt: true,
      label: true,
      gitCommit: true,
      branch: true,
      totalRuns: true,
      totalCases: true,
      audioCases: true,
      aggregate: true
    }
  });
}

/** One run with all its result rows, for the proof-sheet detail view. */
export async function getRun(id: string) {
  return prisma.run.findUnique({
    where: { id },
    include: { results: { orderBy: [{ caseId: 'asc' }, { target: 'asc' }] } }
  });
}

export async function deleteRun(id: string): Promise<void> {
  await prisma.result.deleteMany({ where: { runId: id } });
  await prisma.run.delete({ where: { id } });
}

// --- paginated read API (backing the TanStack Query endpoints) --------------

/** Paginated run history (newest first), plus the total for page controls. */
export async function listRunsPaged(page: number, pageSize: number): Promise<RunsPage> {
  const [rows, total] = await Promise.all([
    prisma.run.findMany({
      orderBy: { createdAt: 'desc' },
      skip: (page - 1) * pageSize,
      take: pageSize,
      select: RUN_SUMMARY_SELECT
    }),
    prisma.run.count()
  ]);
  return { runs: rows.map(toRunSummary), total, page, pageSize };
}

/** One run's metadata + aggregate, without the heavy result rows. */
export async function getRunSummary(id: string): Promise<RunSummary | null> {
  const row = await prisma.run.findUnique({ where: { id }, select: RUN_SUMMARY_SELECT });
  return row ? toRunSummary(row) : null;
}

export interface CaseFilters {
  page: number;
  pageSize: number;
  outcome?: 'all' | 'pass' | 'fail';
  source?: string; // 'all' or a source label (Text/TTS/LibriSpeech/Bluetooth/Noise)
  q?: string;
}

/**
 * Cases for a run, grouped (light+polish per case), filtered, and paginated.
 *
 * A run holds ≤ ~260 rows, so we read them once and group/filter/slice in
 * memory — correct and cheap, and the *client* payload stays small (one page).
 * Returns `null` if the run doesn't exist.
 */
export async function getRunCases(id: string, f: CaseFilters): Promise<CasesPage | null> {
  const run = await prisma.run.findUnique({
    where: { id },
    include: { results: { orderBy: [{ caseId: 'asc' }, { target: 'asc' }] } }
  });
  if (!run) return null;

  let groups = groupByCase(run.results.map(toResultDTO));

  if (f.source && f.source !== 'all') groups = groups.filter((g) => g.source === f.source);
  if (f.outcome === 'pass') groups = groups.filter((g) => !g.anyFail);
  else if (f.outcome === 'fail') groups = groups.filter((g) => g.anyFail);
  if (f.q) {
    const q = f.q.toLowerCase();
    groups = groups.filter(
      (g) =>
        g.caseId.toLowerCase().includes(q) ||
        g.deterministic.toLowerCase().includes(q) ||
        Object.values(g.targets).some((t) => t.llmOutput.toLowerCase().includes(q))
    );
  }

  const total = groups.length;
  const start = (f.page - 1) * f.pageSize;
  return { cases: groups.slice(start, start + f.pageSize), total, page: f.page, pageSize: f.pageSize };
}
