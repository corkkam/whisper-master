import {
  aggregate,
  rowMetrics,
  scoreRow,
  sourceOf,
  wer,
  type Aggregate,
  type ResultRow,
  type Rule,
  type ScoredRow
} from '$lib/scoring';

export interface IngestMeta {
  label?: string | null;
  gitCommit?: string | null;
  branch?: string | null;
}

export interface PreparedResult {
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

export interface PreparedRun {
  label: string | null;
  gitCommit: string | null;
  branch: string | null;
  totalRuns: number;
  totalCases: number;
  audioCases: number;
  aggregate: Aggregate;
  results: PreparedResult[];
}

/**
 * Parse a cases.jsonl string into id -> keyword rules.
 *
 * `category` and `reference` come from here rather than from results.json:
 * the runner has only recently started writing `category`, and no version of it
 * writes `reference`. The cases file is the authority for both, so a run
 * ingested without one still rolls up per category correctly.
 */
export function parseCases(jsonl?: string | null): Map<string, Rule> {
  const map = new Map<string, Rule>();
  if (!jsonl) return map;
  for (const line of jsonl.split('\n')) {
    const t = line.trim();
    if (!t) continue;
    try {
      const c = JSON.parse(t);
      map.set(c.id, {
        mustContain: c.must_contain ?? [],
        mustNotContain: c.must_not_contain ?? [],
        reference: c.reference ?? null,
        category: c.category ?? null
      });
    } catch {
      /* skip malformed line */
    }
  }
  return map;
}

/** Score a results.json array (+ optional cases rules) into a storable run. */
export function prepareRun(rows: ResultRow[], rules: Map<string, Rule>, meta: IngestMeta): PreparedRun {
  const prepared: PreparedResult[] = [];
  const scored: ScoredRow[] = [];

  for (const row of rows) {
    const src = sourceOf(row.id);
    const werValue =
      row.input_kind === 'audio' && row.asr_reference != null && row.asr_text != null
        ? wer(row.asr_reference, row.asr_text)
        : (row.wer ?? null);
    const rule = rules.get(row.id);
    const s = scoreRow(row, rule, werValue);
    const latency = row.latency_ms ?? {};
    const category = row.category ?? rule?.category ?? null;
    const metrics = rowMetrics(row, rule);
    prepared.push({
      caseId: row.id,
      category,
      source: src,
      target: row.target,
      inputKind: row.input_kind ?? 'text',
      deterministic: row.deterministic ?? '',
      llmOutput: row.llm_output ?? '',
      guardAccepted: row.guard?.accepted ?? true,
      wer: werValue,
      latencyMs: latency,
      asrText: row.asr_text ?? null,
      asrReference: row.asr_reference ?? null,
      mechanicalPass: s.pass,
      attribution: s.attribution,
      reasons: s.reasons
    });
    scored.push({
      target: row.target, source: src, wer: werValue, latency, score: s,
      category, guardAccepted: row.guard?.accepted ?? true, metrics
    });
  }

  const caseIds = new Set(rows.map((r) => r.id));
  return {
    label: meta.label ?? null,
    gitCommit: meta.gitCommit ?? null,
    branch: meta.branch ?? null,
    totalRuns: rows.length,
    totalCases: caseIds.size,
    audioCases: prepared.filter((r) => r.inputKind === 'audio' && r.target === 'light').length,
    aggregate: aggregate(scored),
    results: prepared
  };
}
