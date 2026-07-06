<script lang="ts">
  import type { Aggregate } from '$lib/scoring';

  let { aggregate }: { aggregate: Aggregate } = $props();
  const targets = $derived(Object.keys(aggregate.byTarget));

  const label = (t: string) =>
    t === 'light' ? 'Light, ships by default' : t === 'polish' ? 'Polish, experimental' : t;
</script>

<div class="tiles">
  {#each targets as t (t)}
    {@const a = aggregate.byTarget[t]}
    <div class="tile">
      <div class="big">{a.total ? Math.round((a.pass / a.total) * 100) : 0}<small>%</small></div>
      <div class="cap">{label(t)}</div>
      <div class="sub muted">
        {a.pass}/{a.total} cases passed{#if a.latency.llm} · {a.latency.llm.median}ms typical{/if}
      </div>
    </div>
  {/each}
  <div class="tile span">
    <div class="cap">When a case fails, whose fault is it?</div>
    <div class="attr">
      <b style="color:var(--pen)">{aggregate.attribution.asr}</b> the mic misheard the words
      &nbsp;·&nbsp;
      <b style="color:var(--flag)">{aggregate.attribution.cleanup}</b> the cleanup itself slipped
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
    padding: 15px 17px;
  }
  .tile.span {
    grid-column: 1 / -1;
  }
  .big {
    font-family: var(--display);
    font-size: 30px;
    font-weight: 600;
    line-height: 1;
    color: var(--pen);
  }
  .big small {
    font-size: 0.55em;
  }
  .cap {
    font-size: 13.5px;
    font-weight: 600;
    margin-top: 8px;
  }
  .sub {
    font-size: 12.5px;
    margin-top: 3px;
  }
  .attr {
    font-size: 14px;
    margin-top: 8px;
    line-height: 1.4;
  }
  @media (max-width: 520px) {
    .tiles {
      grid-template-columns: 1fr;
    }
  }
</style>
