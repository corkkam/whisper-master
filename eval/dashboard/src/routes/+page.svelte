<script lang="ts">
  import TrendChart from '$lib/components/TrendChart.svelte';
  import type { PageData } from './$types';
  import type { RunSummary } from '$lib/types';

  let { data }: { data: PageData } = $props();
  const runs = $derived(data.runs as RunSummary[]);
  const chrono = $derived([...runs].reverse()); // oldest -> newest for the trend

  function passRate(r: RunSummary, t: string): string {
    const a = r.aggregate?.byTarget?.[t];
    return a && a.total ? `${a.pass}/${a.total}` : '—';
  }
  function bestWer(r: RunSummary): string {
    const ls = r.aggregate?.werBySource?.LibriSpeech;
    return ls ? `${(ls.mean * 100).toFixed(1)}%` : '—';
  }
  function when(iso: string): string {
    return new Date(iso).toLocaleString([], { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });
  }
</script>

<svelte:head><title>Eval proof sheet · history</title></svelte:head>

<p class="eyebrow">History</p>
<h1 class="mono">Runs over time.</h1>
<p class="muted lead">Each stored run is the real pipeline graded end to end. Watch pass rate move as the prompts and guards change.</p>

{#if data.dbError}
  <div class="notice">
    <b>Database not connected.</b>
    <p class="muted">Set <code>DATABASE_URL</code> to your MongoDB Atlas cluster in <code>.env</code>, then run <code>npm run db:push</code>. Once runs are ingested they'll appear here.</p>
    <p class="err mono">{data.dbError}</p>
  </div>
{:else if runs.length === 0}
  <div class="notice">
    <b>No runs yet.</b>
    <p class="muted">Ingest one: <code>npm run push-run -- ../text-cleanup/.eval-scratch/results.json ../text-cleanup/cases.jsonl</code></p>
  </div>
{:else}
  <section class="trend">
    <h2 class="mono">Pass rate</h2>
    <TrendChart runs={chrono} />
  </section>

  <section class="list">
    {#each runs as r (r.id)}
      <a class="run" href="/runs/{r.id}">
        <div class="rmeta">
          <span class="rlabel mono">{r.label ?? 'run'}</span>
          <span class="tag">{r.branch ?? '—'}</span>
          {#if r.gitCommit}<span class="tag">{r.gitCommit.slice(0, 7)}</span>{/if}
          <span class="muted mono when">{when(r.createdAt)}</span>
        </div>
        <div class="stats mono">
          <span><b>{passRate(r, 'light')}</b> light</span>
          <span><b>{passRate(r, 'polish')}</b> polish</span>
          <span class="muted">{r.totalCases} cases · {r.audioCases} audio</span>
          <span class="muted">LibriSpeech WER {bestWer(r)}</span>
        </div>
      </a>
    {/each}
  </section>
{/if}

<style>
  h1 {
    font-size: clamp(28px, 5vw, 42px);
    margin: 0;
    letter-spacing: -0.01em;
  }
  .lead {
    max-width: 54ch;
    margin: 12px 0 28px;
  }
  .notice {
    background: var(--card);
    border: 1px solid var(--rule);
    border-radius: 14px;
    padding: 22px 24px;
  }
  .notice code {
    font-family: var(--mono);
    background: var(--rule-2);
    padding: 1px 6px;
    border-radius: 5px;
    font-size: 12.5px;
  }
  .err {
    font-size: 11px;
    color: var(--flag);
    margin: 10px 0 0;
    word-break: break-all;
  }
  .trend h2 {
    font-size: 11px;
    letter-spacing: 0.22em;
    text-transform: uppercase;
    color: var(--muted);
  }
  .trend {
    margin-bottom: 30px;
  }
  .run {
    display: block;
    padding: 16px 0;
    border-bottom: 1px solid var(--rule);
  }
  .run:hover .rlabel {
    color: var(--pen);
  }
  .rmeta {
    display: flex;
    align-items: baseline;
    gap: 10px;
    flex-wrap: wrap;
  }
  .rlabel {
    font-weight: 600;
    font-size: 14px;
  }
  .when {
    margin-left: auto;
    font-size: 12px;
  }
  .stats {
    display: flex;
    gap: 20px;
    margin-top: 8px;
    font-size: 13px;
    flex-wrap: wrap;
  }
</style>
