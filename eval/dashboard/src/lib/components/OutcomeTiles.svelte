<script lang="ts">
  import type { Aggregate } from '$lib/scoring';

  let { aggregate }: { aggregate: Aggregate } = $props();
  const targets = $derived(Object.keys(aggregate.byTarget));
</script>

<div class="tiles">
  {#each targets as t (t)}
    {@const a = aggregate.byTarget[t]}
    <div class="tile">
      <div class="big mono">{a.pass}/{a.total}</div>
      <div class="cap">{t} · passed</div>
      {#if a.latency.llm}
        <div class="sub mono muted">llm {a.latency.llm.median}ms median</div>
      {/if}
    </div>
  {/each}
  <div class="tile span">
    <div class="cap">Where failures come from</div>
    <div class="sub attr">
      <b style="color:var(--pen)">{aggregate.attribution.asr}</b> the ear (ASR) &nbsp;·&nbsp;
      <b style="color:var(--flag)">{aggregate.attribution.cleanup}</b> the pen (cleanup)
    </div>
  </div>
</div>

<style>
  .tiles {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 12px;
  }
  .tile {
    background: var(--card);
    border: 1px solid var(--rule);
    border-radius: 12px;
    padding: 14px 16px;
  }
  .tile.span {
    grid-column: 1 / -1;
  }
  .big {
    font-size: 26px;
    font-weight: 600;
    line-height: 1;
  }
  .cap {
    font-size: 12px;
    color: var(--muted);
    margin-top: 6px;
  }
  .sub {
    font-family: var(--mono);
    font-size: 12px;
    color: var(--muted);
    margin-top: 2px;
  }
  .sub.attr {
    font-size: 14px;
    margin-top: 6px;
    color: var(--ink);
  }
</style>
