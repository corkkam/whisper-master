<script lang="ts">
  import type { Aggregate, Source } from '$lib/scoring';

  let { werBySource }: { werBySource: Aggregate['werBySource'] } = $props();

  const order: Source[] = ['Text', 'TTS', 'LibriSpeech', 'Bluetooth', 'Noise'];
  const shown = $derived(order.filter((s) => werBySource[s]));

  function color(w: number): string {
    if (w < 0.05) return 'var(--approve)';
    if (w < 0.15) return '#8a8f3a';
    if (w < 0.3) return 'var(--pen)';
    return 'var(--flag)';
  }
</script>

{#if shown.length}
  {#each shown as s (s)}
    {@const m = werBySource[s]!.median}
    <div class="bar">
      <span class="lab mono muted">{s}</span>
      <span class="track"><i style="width:{Math.min(100, m * 100)}%;background:{color(m)}"></i></span>
      <span class="val mono" style="color:{color(m)}">{(m * 100).toFixed(0)}%</span>
    </div>
  {/each}
{:else}
  <p class="muted" style="font-size:13px;margin:0">No audio cases in this run.</p>
{/if}

<style>
  .bar {
    display: grid;
    grid-template-columns: 96px 1fr 52px;
    align-items: center;
    gap: 12px;
    margin: 0 0 11px;
    font-size: 13px;
  }
  .track {
    height: 9px;
    border-radius: 5px;
    background: var(--rule-2);
    overflow: hidden;
  }
  .track > i {
    display: block;
    height: 100%;
    border-radius: 5px;
  }
  .val {
    text-align: right;
    font-weight: 600;
  }
</style>
