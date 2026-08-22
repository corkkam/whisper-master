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
  /** Optional ideal output. Diagnostic only — one acceptable answer, not the only one. */
  reference?: string | null;
  /** The case's category, for the per-category roll-up and the severity weight. */
  category?: string | null;
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

/**
 * Mechanical score: keyword rules + WER threshold, attributed.
 *
 * The guard verdict is diagnostic, not a pass/fail criterion (kept in sync with
 * the Swift `Scorer`): a guard rejection means the safe deterministic fallback
 * was used, which for a faithfulness case is the correct result and satisfies
 * the keyword rules; an unfaithful acceptance is still caught by mustNotContain.
 * So the final output's keyword compliance is the sole mechanical arbiter.
 */
/**
 * Case-insensitive keyword match, ported from the Swift `Scorer.matches`.
 *
 * A term made only of word characters matches on **word boundaries**; anything
 * else is a plain substring. This is the semantics every case was already
 * written as if it had. Plain `includes` was quietly failing them: seven cases
 * forbid the filler `"um"`, which `includes` also finds inside **n-um-ber**,
 * **s-um-mary** and **doc-um-entation**; `"uh"` is inside "though"; `"AM"` is
 * inside "same" and "campaign"; `"20"` is inside "2025".
 *
 * The punctuation carve-out keeps the rest working: `"\n- "`, `"1."`, `"Best,"`,
 * `"$25"` and `"github.com/corkkam"` all still mean exactly the characters they
 * name.
 */
export function matches(term: string, text: string): boolean {
  if (!term) return true;
  if (!/^[\p{L}\p{N}]+$/u.test(term)) return text.toLowerCase().includes(term.toLowerCase());
  const re = new RegExp(`(?<![\\p{L}\\p{N}])${term.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}(?![\\p{L}\\p{N}])`, 'iu');
  return re.test(text);
}

export function scoreRow(row: ResultRow, rule: Rule | undefined, werValue: number | null): Scored {
  const reasons: string[] = [];
  const out = row.llm_output ?? '';
  for (const t of rule?.mustContain ?? []) {
    if (!matches(t, out)) reasons.push(`missing '${t}'`);
  }
  for (const t of rule?.mustNotContain ?? []) {
    if (matches(t, out)) reasons.push(`forbidden '${t}'`);
  }

  let attribution: 'asr' | 'cleanup' | null = null;
  if (werValue != null && werValue > WER_FAIL_THRESHOLD) {
    attribution = 'asr';
    reasons.push(`asr wer ${Math.round(werValue * 100)}%`);
  } else if (reasons.length) {
    attribution = 'cleanup';
  }
  return { pass: reasons.length === 0, reasons, attribution };
}

// --- metrics ----------------------------------------------------------------
// Ported from EvalScoreKit's `Metrics` / `Scorer`. Keep the two in step: the
// dashboard must score a run the same way `eval-score` does.

/**
 * Closed-class words plus the contractions, excluded from the novel-word count.
 * A cleanup pass legitimately reshapes grammar; an invented *fact* is never a
 * function word, so excluding them costs no detection and removes almost all of
 * the false positives. The contractions are enumerated rather than derived
 * because the negatives are irregular ("won't" from "will not") — and because a
 * fuzzy substring test excluded "paris" for containing "is".
 */
export const FUNCTION_WORDS = new Set([
  'a','an','the','is','are','was','were','be','been','being','am',
  'do','does','did','not','no',"n't",'will','would','shall','should',
  'can','could','may','might','must','have','has','had','to','of',
  'in','on','at','for','with','by','from','as','and','or','but',
  'if','then','than','so','that','this','these','those','it','its',
  'i','you','he','she','they','we','us','me','him','her','them',
  'my','your','his','their','our','there','here','up','out','about',
  'into','over','just','going','get','got','s','t','re','ll','ve','d','m',
  "don't","doesn't","didn't","won't","can't",'cannot',"isn't","aren't",
  "wasn't","weren't","haven't","hasn't","hadn't","couldn't","shouldn't",
  "wouldn't","it's","that's","there's","here's","let's","who's","what's",
  "i'm","i'll","i've","i'd","you're","you'll","you've","you'd",
  "we're","we'll","we've","we'd","they're","they'll","they've","they'd",
  "he's","she's","he'll","she'll","he'd","she'd",'gonna','wanna'
]);

/**
 * Output word types absent from the input, minus the transformations the
 * pipeline is built to make: digit runs (inverse text normalization), joined
 * initialisms ("a p i" -> "api"), apostrophe variants, and function words.
 * What survives is content the model put there.
 */
export function novelWords(input: string[], output: string[]): string[] {
  const inSet = new Set(input);
  const bare = (w: string) => w.replace(/'/g, '');
  // Adjacent pairs run together, so a two-token join ("c est" -> "c'est") reads
  // as the same words rather than as new material.
  const inJoined = new Set(input.map(bare));
  for (let i = 0; i + 1 < input.length; i++) inJoined.add(bare(input[i]) + bare(input[i + 1]));
  const initialisms = new Set<string>();
  let run = '';
  for (const w of [...input, '']) {
    // Digits count: "apartment 6 b" -> "6b" is a join, not an invention.
    if (w.length === 1 && /[a-z0-9]/.test(w)) run += w;
    else {
      if (run.length > 1) initialisms.add(run);
      run = '';
    }
  }
  const seen = new Set<string>();
  const novel: string[] = [];
  for (const w of output) {
    if (inSet.has(w) || seen.has(w)) continue;
    seen.add(w);
    if (/^[0-9]+$/.test(w)) continue;
    if (initialisms.has(w)) continue;
    if (inJoined.has(bare(w))) continue;
    // "fifteenth" -> "15th": inverse text normalization wearing a suffix.
    if (/^[0-9]+(st|nd|rd|th)$/.test(w)) continue;
    if (FUNCTION_WORDS.has(w)) continue;
    novel.push(w);
  }
  return novel;
}

export interface RowMetrics {
  /** Output words / input words. Below 1 means content was dropped. */
  retention: number;
  /** Word edit distance from the deterministic input, over its length. 0 = the LLM changed nothing. */
  editRate: number;
  novelWordRate: number;
  novelWords: string[];
  referenceWer: number | null;
  msPerWord: number | null;
  inputWords: number;
}

function editDistance(a: string[], b: string[]): number {
  if (!a.length) return b.length;
  let prev = Array.from({ length: b.length + 1 }, (_, j) => j);
  for (let i = 1; i <= a.length; i++) {
    const cur = [i];
    for (let j = 1; j <= b.length; j++) {
      cur.push(Math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1)));
    }
    prev = cur;
  }
  return prev[b.length];
}

/** Measure one row. Ratios are against `deterministic` — the LLM's input — so the
 *  deterministic passes' own edits are not attributed to the model. */
export function rowMetrics(row: ResultRow, rule?: Rule): RowMetrics {
  const inW = normWords(row.deterministic);
  const outW = normWords(row.llm_output);
  const n = inW.length;
  const novel = novelWords(inW, outW);
  const llm = row.latency_ms?.llm;
  return {
    retention: n === 0 ? (outW.length ? Infinity : 1) : outW.length / n,
    editRate: n === 0 ? (outW.length ? 1 : 0) : editDistance(inW, outW) / n,
    novelWordRate: outW.length === 0 ? 0 : novel.length / new Set(outW).size,
    novelWords: novel,
    referenceWer: rule?.reference ? wer(rule.reference, row.llm_output ?? '') : null,
    msPerWord: llm != null && n > 0 ? llm / n : null,
    inputWords: n
  };
}

/**
 * Severity weight for a failing category. A normalizer that answers a dictated
 * question or leaks a spoken password has broken the promise the product is sold
 * on; one that misses an acronym has been mildly annoying. Reported beside the
 * raw count, not instead of it.
 */
export const CATEGORY_WEIGHT: Record<string, number> = {
  faithfulness: 3, sensitive: 3,
  'long-form': 2, realistic: 2, multilingual: 2, idempotency: 2,
  uri: 1.5, disfluency: 1.5
};
export function categoryWeight(category?: string | null): number {
  return (category && CATEGORY_WEIGHT[category]) || 1;
}

// --- aggregate --------------------------------------------------------------

export interface StageLatency {
  median: number;
  p90: number;
  p99?: number;
}
/** A metric's spread. `worst` is the end that indicates a defect — the *minimum*
 *  retention (a drop) but the *maximum* edit rate — so one column reads the same
 *  way down the whole table. */
export interface Distribution {
  median: number;
  p90: number;
  worst: number;
  mean: number;
  count: number;
}
export interface TargetAggregate {
  pass: number;
  total: number;
  latency: Record<string, StageLatency>;
  // Added 2026-08-22. Runs ingested before then do not carry these, so every
  // reader must treat them as optional rather than defaulting them to zero —
  // a missing measurement and a measurement of zero are different facts.
  weightedPass?: number;
  weightedTotal?: number;
  guardFallbackRate?: number;
  noOpRows?: number;
  retention?: Distribution;
  editRate?: Distribution;
  novelWordRate?: Distribution;
  msPerWord?: Distribution;
  referenceWer?: Distribution;
}
export interface CategoryAggregate {
  pass: number;
  total: number;
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
  /** Per-category pass rate. A suite total can stay green while one category
   *  goes fully red; this is where that shows. Optional for pre-2026-08-22 runs. */
  byCategory?: Record<string, CategoryAggregate>;
}

function median(a: number[]): number {
  if (!a.length) return 0;
  const s = [...a].sort((x, y) => x - y);
  return s[Math.floor(s.length / 2)];
}
/** Nearest-rank percentile, clamped. The old `Math.floor(0.9 * (n - 1))`
 *  truncated toward the median on small samples: for n = 2 it returned index 0,
 *  so a two-row target's "p90" latency was its *fastest* row. */
export function percentileIndex(count: number, q: number): number {
  if (count <= 0) return 0;
  return Math.min(count - 1, Math.max(0, Math.ceil(q * count) - 1));
}
function quantile(a: number[], q: number): number {
  if (!a.length) return 0;
  const s = [...a].sort((x, y) => x - y);
  return s[percentileIndex(s.length, q)];
}
function p90(a: number[]): number {
  return quantile(a, 0.9);
}
function distribution(values: number[], worstEnd: 'low' | 'high'): Distribution {
  const v = values.filter((x) => Number.isFinite(x)).sort((x, y) => x - y);
  if (!v.length) return { median: 0, p90: 0, worst: 0, mean: 0, count: 0 };
  return {
    median: v[Math.floor(v.length / 2)],
    p90: v[percentileIndex(v.length, 0.9)],
    worst: worstEnd === 'low' ? v[0] : v[v.length - 1],
    mean: v.reduce((a, b) => a + b, 0) / v.length,
    count: v.length
  };
}

export interface ScoredRow {
  target: string;
  source: Source;
  wer: number | null;
  latency: Record<string, number>;
  score: Scored;
  category?: string | null;
  guardAccepted?: boolean;
  metrics?: RowMetrics;
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
      latency[stage] = { median: median(vals), p90: p90(vals), p99: quantile(vals, 0.99) };
    }
    const withMetrics = rs.filter((r) => r.metrics);
    const num = (pick: (m: RowMetrics) => number | null) =>
      withMetrics.map((r) => pick(r.metrics as RowMetrics)).filter((x): x is number => x != null);
    byTarget[t] = {
      pass: rs.filter((r) => r.score.pass).length,
      total: rs.length,
      latency,
      weightedPass: rs.filter((r) => r.score.pass).reduce((a, r) => a + categoryWeight(r.category), 0),
      weightedTotal: rs.reduce((a, r) => a + categoryWeight(r.category), 0),
      guardFallbackRate: rs.length
        ? rs.filter((r) => r.guardAccepted === false).length / rs.length
        : 0,
      noOpRows: withMetrics.filter((r) => r.metrics!.editRate === 0).length,
      retention: distribution(num((m) => m.retention), 'low'),
      editRate: distribution(num((m) => m.editRate), 'high'),
      novelWordRate: distribution(num((m) => m.novelWordRate), 'high'),
      msPerWord: distribution(num((m) => m.msPerWord), 'high'),
      referenceWer: distribution(num((m) => m.referenceWer), 'high')
    };
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
  const byCategory: Record<string, CategoryAggregate> = {};
  for (const r of rows) {
    const c = r.category ?? 'uncategorized';
    const a = (byCategory[c] ??= { pass: 0, total: 0 });
    a.total += 1;
    if (r.score.pass) a.pass += 1;
  }

  return { byTarget, werBySource, attribution, byCategory };
}
