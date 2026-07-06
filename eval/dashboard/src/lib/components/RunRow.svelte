<script lang="ts">
  import type { RunSummary } from '$lib/types';

  let { run }: { run: RunSummary } = $props();

  const passRate = $derived.by(() => {
    const t = run.aggregate?.byTarget ?? {};
    let pass = 0;
    let total = 0;
    for (const k of Object.keys(t)) {
      pass += t[k].pass;
      total += t[k].total;
    }
    return total ? Math.round((pass / total) * 100) : null;
  });

  const wer = $derived.by(() => {
    const ls = run.aggregate?.werBySource?.LibriSpeech;
    return ls ? `${(ls.mean * 100).toFixed(1)}%` : null;
  });

  const when = $derived(
    new Date(run.createdAt).toLocaleString([], {
      month: 'short',
      day: 'numeric',
      hour: '2-digit',
      minute: '2-digit'
    })
  );
</script>

<a class="run card" href="/runs/{run.id}">
  <div class="top">
    <span class="label">{run.label ?? 'run'}</span>
    {#if run.branch}<span class="tag">{run.branch}</span>{/if}
    {#if run.gitCommit}<span class="tag mono">{run.gitCommit.slice(0, 7)}</span>{/if}
    <span class="when muted">{when}</span>
  </div>
  <div class="stats">
    <span class="big">{passRate ?? '—'}{#if passRate !== null}<small>%</small>{/if}</span>
    <span class="muted lbl">of cases passed</span>
    <span class="dot">·</span>
    <span class="muted">{run.totalCases} cases{#if run.audioCases > 0}, {run.audioCases} audio{/if}</span>
    {#if wer}
      <span class="dot">·</span>
      <span class="muted">hears real speech at <b>{wer}</b> error</span>
    {/if}
  </div>
</a>

<style>
  .run {
    display: block;
    padding: 16px 20px;
    transition: border-color 0.12s;
  }
  .run:hover {
    border-color: var(--pen);
  }
  .top {
    display: flex;
    align-items: baseline;
    gap: 9px;
    flex-wrap: wrap;
  }
  .label {
    font-weight: 600;
    font-size: 15px;
  }
  .when {
    margin-left: auto;
    font-size: 12.5px;
  }
  .stats {
    display: flex;
    align-items: baseline;
    gap: 8px;
    margin-top: 8px;
    font-size: 13.5px;
    flex-wrap: wrap;
  }
  .big {
    font-family: var(--display);
    font-size: 22px;
    font-weight: 600;
    color: var(--pen);
    line-height: 1;
  }
  .big small {
    font-size: 0.6em;
  }
  .lbl {
    font-size: 13px;
  }
  .dot {
    color: var(--rule);
  }
</style>
