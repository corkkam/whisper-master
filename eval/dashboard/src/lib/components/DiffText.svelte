<script lang="ts">
  import { wordDiff } from '$lib/diff';

  let { base, text }: { base?: string | null; text: string } = $props();
  const parts = $derived(base == null ? null : wordDiff(base, text));
</script>

<span class="txt">
  {#if parts}
    {#each parts as p, i (i)}<span class={p.type === 'same' ? '' : p.type}>{p.text}</span>{' '}{/each}
  {:else}
    {text}
  {/if}
</span>
