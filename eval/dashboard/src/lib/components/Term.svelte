<script lang="ts">
  // Inline jargon with a plain-language definition on hover/focus.
  let { children, title }: { children: import('svelte').Snippet; title: string } = $props();
</script>

<abbr class="term" {title}>{@render children()}</abbr>

<style>
  .term {
    text-decoration: underline dotted var(--muted);
    text-underline-offset: 3px;
    cursor: help;
    font-style: normal;
  }
</style>
