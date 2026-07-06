// Pure scoring logic, ported from the Swift EvalScoreKit so the dashboard scores
// a run the same way `eval-score` does. No dependencies — safe on client or server.

export interface ResultRow {
  id: string;
  target: string;
  input_kind?: string;
  deterministic?: string;
  llm_output?: string;
  guard?: { accepted?: boolean };
  wer?: number | null;
  latency_ms?: Record<string, number>;
  asr_text?: string | null;
  asr_reference?: string | null;
  category?: string;
}

export interface Rule {
  mustContain: string[];
  mustNotContain: string[];
}

export interface Scored {
  pass: boolean;
  reasons: string[];
  attribution: 'asr' | 'cleanup' | null;
}

export const WER_FAIL_THRESHOLD = 0.15;

export function normWords(s: string | null | undefined): string[] {
  return (s ?? '').toLowerCase().match(/[a-z0-9']+/g) ?? [];
}

/** Word error rate: word-level Levenshtein over the reference length. */
export function wer(reference: string, hypothesis: string): number {
  const r = normWords(reference);
  const h = normWords(hypothesis);
  if (r.length === 0) return h.length ? 1 : 0;
  let prev = Array.from({ length: h.length + 1 }, (_, j) => j);
  for (let i = 1; i <= r.length; i++) {
    const cur = [i];
    for (let j = 1; j <= h.length; j++) {
      const cost = r[i - 1] === h[j - 1] ? 0 : 1;
      cur.push(Math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost));
    }
    prev = cur;
  }
  return prev[h.length] / r.length;
}

export type Source = 'Text' | 'TTS' | 'LibriSpeech' | 'Bluetooth' | 'Noise';

export function sourceOf(id: string): Source {
  if (id.startsWith('ls-')) return 'LibriSpeech';
  if (id.startsWith('hfp-')) return 'Bluetooth';
  if (id.startsWith('noisy-')) return 'Noise';
  if (id.startsWith('tts-')) return 'TTS';
  return 'Text';
}

/** Mechanical score: keyword rules + guard verdict + WER threshold, attributed. */
export function scoreRow(row: ResultRow, rule: Rule | undefined, werValue: number | null): Scored {
  const reasons: string[] = [];
  const low = (row.llm_output ?? '').toLowerCase();
  for (const t of rule?.mustContain ?? []) {
    if (!low.includes(t.toLowerCase())) reasons.push(`missing '${t}'`);
  }
  for (const t of rule?.mustNotContain ?? []) {
    if (low.includes(t.toLowerCase())) reasons.push(`forbidden '${t}'`);
  }
  if (row.guard?.accepted === false) reasons.push('guard rejected');

  let attribution: 'asr' | 'cleanup' | null = null;
  if (werValue != null && werValue > WER_FAIL_THRESHOLD) {
    attribution = 'asr';
    reasons.push(`asr wer ${Math.round(werValue * 100)}%`);
  } else if (reasons.length) {
    attribution = 'cleanup';
  }
  return { pass: reasons.length === 0, reasons, attribution };
}

// --- aggregate --------------------------------------------------------------

export interface StageLatency {
  median: number;
  p90: number;
}
export interface TargetAggregate {
  pass: number;
  total: number;
  latency: Record<string, StageLatency>;
}
export interface SourceWer {
  median: number;
  mean: number;
  count: number;
}
export interface Aggregate {
  byTarget: Record<string, TargetAggregate>;
  werBySource: Partial<Record<Source, SourceWer>>;
  attribution: { asr: number; cleanup: number };
}

function median(a: number[]): number {
  if (!a.length) return 0;
  const s = [...a].sort((x, y) => x - y);
  return s[Math.floor(s.length / 2)];
}
function p90(a: number[]): number {
  if (!a.length) return 0;
  const s = [...a].sort((x, y) => x - y);
  return s[Math.min(s.length - 1, Math.floor(0.9 * (s.length - 1)))];
}

export interface ScoredRow {
  target: string;
  source: Source;
  wer: number | null;
  latency: Record<string, number>;
  score: Scored;
}

export function aggregate(rows: ScoredRow[]): Aggregate {
  const byTarget: Record<string, TargetAggregate> = {};
  const targets = [...new Set(rows.map((r) => r.target))];
  for (const t of targets) {
    const rs = rows.filter((r) => r.target === t);
    const stageVals: Record<string, number[]> = {};
    for (const r of rs) {
      for (const [stage, ms] of Object.entries(r.latency ?? {})) {
        (stageVals[stage] ??= []).push(ms);
      }
    }
    const latency: Record<string, StageLatency> = {};
    for (const [stage, vals] of Object.entries(stageVals)) {
      latency[stage] = { median: median(vals), p90: p90(vals) };
    }
    byTarget[t] = { pass: rs.filter((r) => r.score.pass).length, total: rs.length, latency };
  }

  const werBySource: Partial<Record<Source, SourceWer>> = {};
  const sources: Source[] = ['Text', 'TTS', 'LibriSpeech', 'Bluetooth', 'Noise'];
  for (const s of sources) {
    const ws = rows.filter((r) => r.target === 'light' && r.source === s && r.wer != null).map((r) => r.wer as number);
    if (ws.length) {
      werBySource[s] = { median: median(ws), mean: ws.reduce((a, b) => a + b, 0) / ws.length, count: ws.length };
    }
  }

  const fails = rows.filter((r) => !r.score.pass);
  const attribution = {
    asr: fails.filter((r) => r.score.attribution === 'asr').length,
    cleanup: fails.filter((r) => r.score.attribution === 'cleanup').length
  };
  return { byTarget, werBySource, attribution };
}
