<script lang="ts">
  import WerBars from '$lib/components/WerBars.svelte';
  import OutcomeTiles from '$lib/components/OutcomeTiles.svelte';
  import CaseCard from '$lib/components/CaseCard.svelte';
  import type { CaseGroup, RunSummary } from '$lib/types';
  import type { PageData } from './$types';

  let { data }: { data: PageData } = $props();
  const run = $derived(data.run as RunSummary);
  const cases = $derived(data.cases as CaseGroup[]);

  const sources = ['Text', 'TTS', 'LibriSpeech', 'Bluetooth', 'Noise'];
  let q = $state('');
  let verdict = $state<'all' | 'fail' | 'pass'>('all');
  let source = $state<string | null>(null);

  const shown = $derived(
    cases.filter((c) => {
      if (source && c.source !== source) return false;
      if (verdict === 'fail' && !c.anyFail) return false;
      if (verdict === 'pass' && c.anyFail) return false;
      if (q) {
        const hay = (
          c.caseId +
          ' ' +
          (c.category ?? '') +
          ' ' +
          c.deterministic +
          ' ' +
          (c.asrText ?? '') +
          ' ' +
          Object.values(c.targets)
            .map((r) => r.llmOutput)
            .join(' ')
        ).toLowerCase();
        if (!hay.includes(q.toLowerCase())) return false;
      }
      return true;
    })
  );
</script>

<svelte:head><title>{run.label ?? 'run'} · eval proof sheet</title></svelte:head>

<p class="eyebrow">Proof sheet</p>
<h1 class="mono">{run.label ?? 'Run'}</h1>
<div class="runmeta mono muted">
  <span><b>{run.totalCases}</b> cases</span>
  <span><b>{run.totalRuns}</b> runs</span>
  <span><b>{run.audioCases}</b> audio</span>
  {#if run.branch}<span>{run.branch}</span>{/if}
  {#if run.gitCommit}<span>{run.gitCommit.slice(0, 7)}</span>{/if}
  <span>{new Date(run.createdAt).toLocaleString()}</span>
</div>

<div class="strip">
  <div class="panel">
    <h3>The ear — <span class="k">ASR word error rate by source</span></h3>
    <WerBars werBySource={run.aggregate.werBySource} />
  </div>
  <div class="panel">
    <h3>The pen — <span class="k">cleanup outcome</span></h3>
    <OutcomeTiles aggregate={run.aggregate} />
  </div>
</div>

<div class="controls">
  <input class="search" placeholder="filter transcripts, ids, categories…" bind:value={q} />
  <span class="count mono muted">{shown.length} / {cases.length}</span>
  <div class="chips">
    <button class="chip pen" aria-pressed={verdict === 'fail'} onclick={() => (verdict = verdict === 'fail' ? 'all' : 'fail')}>fail</button>
    <button class="chip" aria-pressed={verdict === 'pass'} onclick={() => (verdict = verdict === 'pass' ? 'all' : 'pass')}>pass</button>
    {#each sources as s (s)}
      {#if cases.some((c) => c.source === s)}
        <button class="chip" aria-pressed={source === s} onclick={() => (source = source === s ? null : s)}>{s}</button>
      {/if}
    {/each}
  </div>
</div>

<div class="cases">
  {#each shown as c (c.caseId)}
    <CaseCard {c} />
  {/each}
</div>

<style>
  h1 {
    font-size: clamp(26px, 4.5vw, 40px);
    margin: 0;
  }
  .runmeta {
    display: flex;
    gap: 18px;
    flex-wrap: wrap;
    font-size: 12px;
    margin-top: 12px;
  }
  .strip {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 26px;
    margin: 28px 0 8px;
  }
  @media (max-width: 720px) {
    .strip {
      grid-template-columns: 1fr;
    }
  }
  .panel h3 {
    font-size: 11px;
    letter-spacing: 0.22em;
    text-transform: uppercase;
    color: var(--muted);
    margin: 0 0 14px;
    font-weight: 600;
  }
  .panel h3 .k {
    color: var(--ink);
  }
  .controls {
    position: sticky;
    top: 0;
    z-index: 5;
    background: var(--paper);
    padding: 16px 0 12px;
    margin-top: 24px;
    border-bottom: 1px solid var(--rule);
    display: flex;
    gap: 10px;
    align-items: center;
    flex-wrap: wrap;
  }
  .search {
    flex: 1;
    min-width: 200px;
    font-family: var(--mono);
    font-size: 13px;
    background: var(--card);
    border: 1px solid var(--rule);
    border-radius: 9px;
    padding: 9px 12px;
    color: var(--ink);
  }
  .count {
    font-size: 12px;
  }
  .chips {
    display: flex;
    gap: 7px;
    flex-wrap: wrap;
    width: 100%;
  }
</style>
