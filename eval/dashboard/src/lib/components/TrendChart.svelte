<script lang="ts">
  import type { RunSummary } from '$lib/types';

  // Runs oldest -> newest. Plots light & polish pass-rate over runs.
  let { runs }: { runs: RunSummary[] } = $props();

  const W = 640;
  const H = 170;
  const PAD = 26;

  function rate(r: RunSummary, target: string): number {
    const a = r.aggregate?.byTarget?.[target];
    return a && a.total ? a.pass / a.total : 0;
  }
  function xy(i: number, v: number): [number, number] {
    const x = PAD + (runs.length === 1 ? 0.5 : i / (runs.length - 1)) * (W - 2 * PAD);
    const y = H - PAD - v * (H - 2 * PAD);
    return [x, y];
  }
  function path(target: string): string {
    return runs
      .map((r, i) => {
        const [x, y] = xy(i, rate(r, target));
        return `${i === 0 ? 'M' : 'L'}${x.toFixed(1)} ${y.toFixed(1)}`;
      })
      .join(' ');
  }
  const light = $derived(path('light'));
  const polish = $derived(path('polish'));
</script>

{#if runs.length >= 2}
  <div class="chart">
    <svg viewBox="0 0 {W} {H}" role="img" aria-label="Cleanup pass rate over runs">
      {#each [0, 0.5, 1] as g (g)}
        {@const y = H - PAD - g * (H - 2 * PAD)}
        <line class="grid" x1={PAD} x2={W - PAD} y1={y} y2={y} />
        <text class="axis" x={PAD - 6} {y} dy="3" text-anchor="end">{g * 100}%</text>
      {/each}
      <path class="polish" d={polish} />
      <path class="light" d={light} />
      {#each runs as r, i (r.id)}
        {@const [x, y] = xy(i, rate(r, 'light'))}
        <circle class="pt" cx={x} cy={y} r="3" />
      {/each}
    </svg>
    <div class="legend">
      <span><i class="l"></i> light (default cleanup)</span>
      <span><i class="p"></i> polish (experimental)</span>
      <span class="muted">· {runs.length} runs, oldest → newest. Higher is better.</span>
    </div>
  </div>
{:else}
  <p class="muted" style="font-size:13.5px">A trend line appears once a second run is stored.</p>
{/if}

<style>
  .chart svg {
    width: 100%;
    height: 180px;
    display: block;
  }
  .grid {
    stroke: var(--rule);
    stroke-width: 1;
  }
  .axis {
    fill: var(--muted);
    font-family: var(--sans);
    font-size: 10px;
  }
  path {
    fill: none;
    stroke-width: 2.5;
    stroke-linejoin: round;
  }
  path.light {
    stroke: var(--pen);
  }
  path.polish {
    stroke: var(--muted);
    stroke-dasharray: 4 3;
  }
  .pt {
    fill: var(--pen);
  }
  .legend {
    display: flex;
    gap: 16px;
    font-size: 12.5px;
    margin-top: 8px;
    flex-wrap: wrap;
    align-items: center;
  }
  .legend i {
    display: inline-block;
    width: 14px;
    height: 2px;
    vertical-align: middle;
    margin-right: 5px;
  }
  .legend i.l {
    background: var(--pen);
  }
  .legend i.p {
    background: var(--muted);
  }
</style>
