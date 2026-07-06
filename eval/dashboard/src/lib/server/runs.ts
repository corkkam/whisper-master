import type { Prisma } from '@prisma/client';
import { prisma } from './db';
import type { PreparedRun } from './ingest';

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
