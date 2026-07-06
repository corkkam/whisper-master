<script lang="ts">
  import { createQuery, keepPreviousData } from '@tanstack/svelte-query';
  import { fetchRun, fetchCases, runKey, casesKey, CASES_PAGE_SIZE } from '$lib/api';
  import type { RunSummary } from '$lib/types';
  import WerBars from '$lib/components/WerBars.svelte';
  import OutcomeTiles from '$lib/components/OutcomeTiles.svelte';
  import CaseCard from '$lib/components/CaseCard.svelte';
  import Pagination from '$lib/components/Pagination.svelte';
  import type { PageData } from './$types';

  let { data }: { data: PageData } = $props();

  const runQuery = createQuery(() => ({
    queryKey: runKey(data.id),
    queryFn: () => fetchRun(data.id),
    initialData: data.run ?? undefined
  }));
  const run = $derived<RunSummary | undefined>(runQuery.data);

  // Filters (server-side, via the cases query).
  let page = $state(1);
  let outcome = $state<'all' | 'pass' | 'fail'>('all');
  let source = $state('all');
  let rawSearch = $state('');
  let q = $state('');

  // Debounce the search box so we don't fire a query per keystroke.
  $effect(() => {
    const v = rawSearch;
    const t = setTimeout(() => {
      q = v;
      page = 1;
    }, 300);
    return () => clearTimeout(t);
  });

  const filters = $derived({ page, outcome, source, q });
  const isDefault = $derived(page === 1 && outcome === 'all' && source === 'all' && q === '');

  const casesQuery = createQuery(() => ({
    queryKey: casesKey(data.id, filters),
    queryFn: () => fetchCases(data.id, filters),
    initialData: isDefault ? (data.cases ?? undefined) : undefined,
    placeholderData: keepPreviousData
  }));

  function setOutcome(v: 'all' | 'pass' | 'fail') {
    outcome = outcome === v ? 'all' : v;
    page = 1;
  }
  function setSource(v: string) {
    source = source === v ? 'all' : v;
    page = 1;
  }

  const overallPass = $derived.by(() => {
    const t = run?.aggregate?.byTarget ?? {};
    let pass = 0;
    let total = 0;
    for (const k of Object.keys(t)) {
      pass += t[k].pass;
      total += t[k].total;
    }
    return total ? Math.round((pass / total) * 100) : null;
  });

  const SOURCE_LABEL: Record<string, string> = {
    LibriSpeech: 'Real speech',
    TTS: 'Synthetic',
    Bluetooth: 'Bluetooth',
    Noise: 'Noisy',
    Text: 'Typed'
  };
  const sources = $derived.by(() => {
    const out: string[] = [];
    const w = run?.aggregate?.werBySource ?? {};
    for (const k of ['LibriSpeech', 'TTS', 'Bluetooth', 'Noise'] as const) if (w[k]) out.push(k);
    if (run && run.totalCases > run.audioCases) out.push('Text');
    return out;
  });

  const when = $derived(run ? new Date(run.createdAt).toLocaleString() : '');
</script>

<svelte:head><title>{run?.label ?? 'Run'} · eval</title></svelte:head>

{#if data.loadError}
  <p class="err">Couldn't load this run. {data.loadError}</p>
{:else if run}
  <a class="back muted" href="/">← all runs</a>
  <p class="eyebrow">Evaluation run</p>
  <h1>{run.label ?? 'Run'}</h1>
  <p class="sub muted">
    {#if overallPass !== null}<b class="pen">{overallPass}% of cases passed</b> · {/if}
    {run.totalCases} cases{#if run.audioCases > 0}, {run.audioCases} audio{/if} · {when}
    {#if run.branch} · {run.branch}{/if}{#if run.gitCommit} · {run.gitCommit.slice(0, 7)}{/if}
  </p>

  <div class="strip">
    <section class="panel card">
      <h2>Did it hear the words right?</h2>
      <WerBars werBySource={run.aggregate.werBySource} />
    </section>
    <section class="panel card">
      <h2>Did it clean up correctly and safely?</h2>
      <OutcomeTiles aggregate={run.aggregate} />
    </section>
  </div>

  <section class="cases-section">
    <h2>Every case</h2>
    <p class="legend muted">
      Each case shows the instant on device cleanup, then the <b>Light</b> and
      <b>Polish</b> passes marked up against it (<span class="ins">red</span> is added,
      <span class="del">struck</span> is removed). For audio, <b>Heard</b> is what the mic transcribed.
    </p>

    <div class="controls">
      <input class="search" placeholder="Search transcripts, ids…" bind:value={rawSearch} />
      <div class="chips">
        <button class="chip pen" aria-pressed={outcome === 'fail'} onclick={() => setOutcome('fail')}
          >Needs review</button
        >
        <button class="chip" aria-pressed={outcome === 'pass'} onclick={() => setOutcome('pass')}
          >Clean</button
        >
        {#each sources as s (s)}
          <button class="chip" aria-pressed={source === s} onclick={() => setSource(s)}
            >{SOURCE_LABEL[s] ?? s}</button
          >
        {/each}
      </div>
    </div>

    {#if casesQuery.isError}
      <p class="err">Couldn't load cases. {casesQuery.error?.message}</p>
    {:else if (casesQuery.data?.cases?.length ?? 0) === 0}
      <p class="muted none">No cases match these filters.</p>
    {:else}
      <p class="count muted">
        {casesQuery.data?.total} case{(casesQuery.data?.total ?? 0) === 1 ? '' : 's'} match
      </p>
      <div class="cases" class:dim={casesQuery.isPlaceholderData}>
        {#each casesQuery.data?.cases ?? [] as c (c.caseId)}
          <CaseCard {c} />
        {/each}
      </div>
      <Pagination
        {page}
        total={casesQuery.data?.total ?? 0}
        pageSize={CASES_PAGE_SIZE}
        loading={casesQuery.isPlaceholderData}
        onchange={(p) => (page = p)}
      />
    {/if}
  </section>
{/if}

<style>
  .back {
    display: inline-block;
    font-size: 13px;
    margin-bottom: 18px;
  }
  .sub {
    font-size: 14px;
    margin: 8px 0 0;
  }
  .strip {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 16px;
    margin: 30px 0 8px;
  }
  .panel {
    padding: 22px 24px;
  }
  .panel h2 {
    font-size: 18px;
    margin: 0 0 16px;
  }
  .cases-section {
    margin-top: 40px;
  }
  .legend {
    font-size: 13.5px;
    line-height: 1.5;
    margin: 6px 0 16px;
    max-width: 68ch;
  }
  .legend .ins {
    color: var(--pen);
    font-weight: 600;
  }
  .legend .del {
    text-decoration: line-through;
    text-decoration-color: var(--pen);
  }
  .controls {
    position: sticky;
    top: 0;
    z-index: 5;
    background: var(--paper);
    padding: 14px 0 12px;
    border-bottom: 1px solid var(--rule);
    display: flex;
    gap: 10px;
    align-items: center;
    flex-wrap: wrap;
  }
  .search {
    flex: 1;
    min-width: 200px;
    font-size: 14px;
    background: var(--card);
    border: 1px solid var(--rule);
    border-radius: 9px;
    padding: 9px 13px;
    color: var(--ink);
    font-family: var(--sans);
  }
  .chips {
    display: flex;
    gap: 7px;
    flex-wrap: wrap;
  }
  .count {
    font-size: 13px;
    margin: 14px 0 0;
  }
  .cases {
    transition: opacity 0.15s;
  }
  .cases.dim {
    opacity: 0.55;
  }
  .none {
    margin-top: 20px;
  }
  .err {
    color: var(--flag);
  }
  @media (max-width: 720px) {
    .strip {
      grid-template-columns: 1fr;
    }
  }
</style>
