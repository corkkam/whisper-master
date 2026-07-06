// Word-level LCS diff rendered as proofreading marks. Compares on an
// alphanumeric key so punctuation/case-only changes ("logs" -> "logs.") don't
// show as word swaps — only real word insertions/deletions/substitutions do.

export type DiffPart = { type: 'same' | 'del' | 'ins'; text: string };

const key = (w: string) => w.toLowerCase().replace(/[^a-z0-9']/g, '');

export function wordDiff(a: string, b: string): DiffPart[] {
  const A = (a ?? '').split(/\s+/).filter(Boolean);
  const B = (b ?? '').split(/\s+/).filter(Boolean);
  const m = A.length;
  const n = B.length;
  const dp: number[][] = Array.from({ length: m + 1 }, () => new Array(n + 1).fill(0));
  for (let i = m - 1; i >= 0; i--) {
    for (let j = n - 1; j >= 0; j--) {
      dp[i][j] = key(A[i]) === key(B[j]) ? dp[i + 1][j + 1] + 1 : Math.max(dp[i + 1][j], dp[i][j + 1]);
    }
  }
  const out: DiffPart[] = [];
  let i = 0;
  let j = 0;
  while (i < m && j < n) {
    if (key(A[i]) === key(B[j])) {
      out.push({ type: 'same', text: B[j] });
      i++;
      j++;
    } else if (dp[i + 1][j] >= dp[i][j + 1]) {
      out.push({ type: 'del', text: A[i] });
      i++;
    } else {
      out.push({ type: 'ins', text: B[j] });
      j++;
    }
  }
  while (i < m) out.push({ type: 'del', text: A[i++] });
  while (j < n) out.push({ type: 'ins', text: B[j++] });
  return out;
}
