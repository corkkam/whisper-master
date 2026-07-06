import type { Aggregate } from './scoring';

/** A serialized Result row (from the DB / API). */
export interface ResultDTO {
  caseId: string;
  category: string | null;
  source: string;
  target: string;
  inputKind: string;
  deterministic: string;
  llmOutput: string;
  guardAccepted: boolean;
  wer: number | null;
  latencyMs: Record<string, number>;
  asrText: string | null;
  asrReference: string | null;
  mechanicalPass: boolean;
  attribution: string | null;
  reasons: string[];
}

/** Results for one case, grouped by target, for the proof-sheet card. */
export interface CaseGroup {
  caseId: string;
  category: string | null;
  source: string;
  inputKind: string;
  deterministic: string;
  asrText: string | null;
  asrReference: string | null;
  wer: number | null;
  targets: Record<string, ResultDTO>;
  anyFail: boolean;
}

export interface RunSummary {
  id: string;
  createdAt: string;
  label: string | null;
  gitCommit: string | null;
  branch: string | null;
  totalRuns: number;
  totalCases: number;
  audioCases: number;
  aggregate: Aggregate;
}

export function groupByCase(results: ResultDTO[]): CaseGroup[] {
  const map = new Map<string, CaseGroup>();
  for (const r of results) {
    let g = map.get(r.caseId);
    if (!g) {
      g = {
        caseId: r.caseId,
        category: r.category,
        source: r.source,
        inputKind: r.inputKind,
        deterministic: r.deterministic,
        asrText: r.asrText,
        asrReference: r.asrReference,
        wer: r.wer,
        targets: {},
        anyFail: false
      };
      map.set(r.caseId, g);
    }
    g.targets[r.target] = r;
    if (!r.mechanicalPass) g.anyFail = true;
  }
  return [...map.values()];
}
