<script lang="ts">
  import type { RunSummary } from '$lib/types';

  // Runs oldest -> newest. Plots light & polish pass-rate over runs.
  let { runs }: { runs: RunSummary[] } = $props();

  const W = 640;
  const H = 150;
  const PAD = 20;

  function rate(r: RunSummary, target: string): number {
    const a = r.aggregate?.byTarget?.[target];
    return a && a.total ? a.pass / a.total : 0;
  }
  function path(target: string): string {
    if (runs.length < 2) return '';
    return runs
      .map((r, i) => {
        const x = PAD + (i / (runs.length - 1)) * (W - 2 * PAD);
        const y = H - PAD - rate(r, target) * (H - 2 * PAD);
        return `${i === 0 ? 'M' : 'L'}${x.toFixed(1)} ${y.toFixed(1)}`;
      })
      .join(' ');
  }
  const light = $derived(path('light'));
  const polish = $derived(path('polish'));
</script>

{#if runs.length >= 2}
  <div class="chart">
    <svg viewBox="0 0 {W} {H}" preserveAspectRatio="none" role="img" aria-label="Pass rate over runs">
      {#each [0, 0.5, 1] as g (g)}
        <line class="grid" x1={PAD} x2={W - PAD} y1={H - PAD - g * (H - 2 * PAD)} y2={H - PAD - g * (H - 2 * PAD)} />
      {/each}
      <path class="polish" d={polish} />
      <path class="light" d={light} />
    </svg>
    <div class="legend mono">
      <span><i class="l"></i> light pass rate</span>
      <span><i class="p"></i> polish pass rate</span>
      <span class="muted">· {runs.length} runs, oldest → newest</span>
    </div>
  </div>
{:else}
  <p class="muted" style="font-size:13px">Trends appear after a second run is stored.</p>
{/if}

<style>
  .chart svg {
    width: 100%;
    height: 150px;
    display: block;
  }
  .grid {
    stroke: var(--rule);
    stroke-width: 1;
  }
  path {
    fill: none;
    stroke-width: 2;
    vector-effect: non-scaling-stroke;
  }
  path.light {
    stroke: var(--pen);
  }
  path.polish {
    stroke: var(--muted);
    stroke-dasharray: 4 3;
  }
  .legend {
    display: flex;
    gap: 16px;
    font-size: 11px;
    margin-top: 6px;
    flex-wrap: wrap;
  }
  .legend i {
    display: inline-block;
    width: 14px;
    height: 2px;
    vertical-align: middle;
    margin-right: 4px;
  }
  .legend i.l {
    background: var(--pen);
  }
  .legend i.p {
    background: var(--muted);
  }
</style>
