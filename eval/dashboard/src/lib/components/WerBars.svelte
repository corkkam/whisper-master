<script lang="ts">
  import type { Aggregate, Source } from '$lib/scoring';

  let { werBySource }: { werBySource: Aggregate['werBySource'] } = $props();

  // Plain-language labels; LibriSpeech (the real-human anchor) first.
  const LABELS: Record<Source, string> = {
    LibriSpeech: 'Real human speech',
    TTS: 'Synthetic voice',
    Bluetooth: 'Bluetooth mic',
    Noise: 'Noisy room',
    Text: 'Typed text'
  };
  const order: Source[] = ['LibriSpeech', 'TTS', 'Bluetooth', 'Noise', 'Text'];
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
      <span class="lab">{LABELS[s]}</span>
      <span class="track"
        ><i style="width:{Math.min(100, m * 100)}%;background:{color(m)}"></i></span
      >
      <span class="val" style="color:{color(m)}">{(m * 100).toFixed(0)}%</span>
    </div>
  {/each}
  <p class="reading muted">
    The share of words misheard, lower is better. Real human speech is the number to trust. Noise
    and Bluetooth mics are where hearing gets hard.
  </p>
{:else}
  <p class="muted empty">This run graded typed text only. No audio, so there's nothing to hear here.</p>
{/if}

<style>
  .bar {
    display: grid;
    grid-template-columns: 140px 1fr 46px;
    align-items: center;
    gap: 12px;
    margin: 0 0 11px;
    font-size: 14px;
  }
  .lab {
    color: var(--ink);
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
    font-weight: 650;
  }
  .reading {
    font-size: 13px;
    line-height: 1.45;
    margin: 14px 0 0;
    max-width: 46ch;
  }
  .empty {
    font-size: 13.5px;
    margin: 0;
  }
  @media (max-width: 520px) {
    .bar {
      grid-template-columns: 110px 1fr 42px;
      font-size: 13px;
    }
  }
</style>
