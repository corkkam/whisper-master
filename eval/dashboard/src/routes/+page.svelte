<script lang="ts">
  import { createQuery, keepPreviousData } from '@tanstack/svelte-query';
  import { fetchRuns, runsKey, RUNS_PAGE_SIZE } from '$lib/api';
  import type { RunSummary } from '$lib/types';
  import HeroDemo from '$lib/components/HeroDemo.svelte';
  import Pipeline from '$lib/components/Pipeline.svelte';
  import TrendChart from '$lib/components/TrendChart.svelte';
  import RunRow from '$lib/components/RunRow.svelte';
  import Pagination from '$lib/components/Pagination.svelte';
  import Term from '$lib/components/Term.svelte';
  import type { PageData } from './$types';

  let { data }: { data: PageData } = $props();
  let page = $state(1);

  const query = createQuery(() => ({
    queryKey: runsKey(page),
    queryFn: () => fetchRuns(page),
    initialData: page === 1 ? (data.initial ?? undefined) : undefined,
    placeholderData: keepPreviousData
  }));

  // Hero + trend read the SSR'd first page (always the newest runs), so they
  // stay stable while the list below paginates.
  const heroRuns = $derived(data.initial?.runs ?? []);
  const latest = $derived<RunSummary | undefined>(heroRuns[0]);

  function overallPass(r: RunSummary): number | null {
    const t = r.aggregate?.byTarget ?? {};
    let pass = 0;
    let total = 0;
    for (const k of Object.keys(t)) {
      pass += t[k].pass;
      total += t[k].total;
    }
    return total ? Math.round((pass / total) * 100) : null;
  }

  // Each headline number comes from the most relevant recent run: cleanup
  // accuracy + speed from the latest text-only run (so mishearing on audio
  // doesn't drag the cleanup figure down), transcription from the latest run
  // that has real-speech WER. Fall back to the latest run if needed.
  const textRun = $derived<RunSummary | undefined>(
    heroRuns.find((r) => r.audioCases === 0) ?? latest
  );
  const cleanupPct = $derived(textRun ? overallPass(textRun) : null);
  const wer = $derived.by(() => {
    const r = heroRuns.find((x) => x.aggregate?.werBySource?.LibriSpeech);
    const ls = r?.aggregate?.werBySource?.LibriSpeech;
    return ls ? (ls.mean * 100).toFixed(1) : null;
  });
  const speedMs = $derived.by(() => {
    const l = textRun?.aggregate?.byTarget?.light?.latency?.llm?.median;
    return typeof l === 'number' ? String(l) : null;
  });

  // Trend: the recent runs (page 1), oldest -> newest.
  const trendRuns = $derived([...heroRuns].reverse());
</script>

<svelte:head>
  <title>Whisper Master · how we test dictation cleanup</title>
  <meta
    name="description"
    content="How well Whisper Master cleans up your dictation, graded on the real shipped pipeline: transcription accuracy, cleanup quality, and faithfulness."
  />
</svelte:head>

{#if data.dbError}
  <div class="notice card">
    <b>Database not connected.</b>
    <p class="muted">
      Set <code>DATABASE_URL</code> to your MongoDB Atlas cluster, then run
      <code>npm run db:push</code>. Runs appear here once ingested.
    </p>
    <p class="err mono">{data.dbError}</p>
  </div>
{:else}
  <!-- A: show it working -->
  <section class="hero">
    <p class="eyebrow">Whisper Master · evaluation</p>
    <h1>How well does it clean up your dictation?</h1>
    <p class="lead">
      Watch the <b>real, shipped</b> pipeline turn messy speech into clean text. Then see exactly how
      we prove it, on every change.
    </p>

    <HeroDemo />

    <div class="strip">
      <div class="s">
        <b>{cleanupPct !== null ? cleanupPct + '%' : 'n/a'}</b><span>cleanup accuracy</span>
      </div>
      <div class="s"><b>{wer ? wer + '%' : 'n/a'}</b><span>word error, real speech</span></div>
      <div class="s"><b>{speedMs ? speedMs + 'ms' : 'n/a'}</b><span>typical cleanup</span></div>
      <div class="s"><b>100%</b><span>on device, always</span></div>
    </div>
  </section>

  <!-- B: credibility -->
  <Pipeline />

  {#if trendRuns.length >= 2}
    <section class="trend">
      <h2>Is it getting better?</h2>
      <p class="muted cap">
        Share of test cases that pass, across recent runs. <Term
          title="The default, conservative cleanup mode that ships on by default.">Light</Term
        >
        is what ships;
        <Term title="An experimental mode that also rewrites grammar; off by default.">polish</Term
        > is experimental.
      </p>
      <TrendChart runs={trendRuns} />
    </section>
  {/if}

  <!-- C entry point: the runs -->
  <section class="list">
    <h2>Every run</h2>
    <p class="muted cap">Each row is one full evaluation. Open it to see every case, marked up.</p>

    {#if query.isError}
      <p class="err">Couldn't load runs. {query.error?.message}</p>
    {:else if (query.data?.runs?.length ?? 0) === 0}
      <p class="muted">No runs yet. Ingest one with <code class="mono">npm run push-run</code>.</p>
    {:else}
      <div class="rows" class:dim={query.isPlaceholderData}>
        {#each query.data?.runs ?? [] as run (run.id)}
          <RunRow {run} />
        {/each}
      </div>
      <Pagination
        {page}
        total={query.data?.total ?? 0}
        pageSize={RUNS_PAGE_SIZE}
        loading={query.isPlaceholderData}
        onchange={(p) => (page = p)}
      />
    {/if}
  </section>
{/if}

<style>
  .hero {
    margin-bottom: 10px;
  }
  .lead {
    max-width: 56ch;
    font-size: 17px;
    line-height: 1.55;
    margin: 16px 0 28px;
  }
  .strip {
    display: flex;
    flex-wrap: wrap;
    gap: 14px 38px;
    margin-top: 26px;
    padding-left: 2px;
  }
  .strip .s {
    display: flex;
    flex-direction: column;
  }
  .strip .s b {
    font-family: var(--display);
    font-size: 27px;
    font-weight: 600;
    color: var(--pen);
    line-height: 1;
    letter-spacing: -0.01em;
  }
  .strip .s span {
    font-size: 12.5px;
    color: var(--muted);
    margin-top: 5px;
  }
  h2 {
    margin-bottom: 4px;
  }
  .cap {
    font-size: 14px;
    margin: 0 0 16px;
    max-width: 62ch;
  }
  .trend {
    margin: 44px 0;
  }
  .list {
    margin-top: 44px;
  }
  .rows {
    display: flex;
    flex-direction: column;
    gap: 10px;
    transition: opacity 0.15s;
  }
  .rows.dim {
    opacity: 0.55;
  }
  .notice {
    padding: 24px;
  }
  .notice code,
  code {
    font-family: var(--mono);
    background: var(--rule-2);
    padding: 1px 6px;
    border-radius: 5px;
    font-size: 12.5px;
  }
  .err {
    color: var(--flag);
    font-size: 13px;
  }
  .notice .err {
    font-size: 11px;
    word-break: break-all;
    margin-top: 10px;
  }
  @media (max-width: 640px) {
    .strip {
      gap: 16px 28px;
    }
  }
</style>
