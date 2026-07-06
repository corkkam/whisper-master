<script lang="ts">
  let {
    page,
    total,
    pageSize,
    loading = false,
    onchange
  }: {
    page: number;
    total: number;
    pageSize: number;
    loading?: boolean;
    onchange: (page: number) => void;
  } = $props();

  const pages = $derived(Math.max(1, Math.ceil(total / pageSize)));
</script>

{#if pages > 1}
  <nav class="pg" aria-label="Pagination">
    <button class="chip" disabled={page <= 1 || loading} onclick={() => onchange(page - 1)}>
      ← Prev
    </button>
    <span class="ind muted">Page {page} of {pages}{#if loading} · loading…{/if}</span>
    <button class="chip" disabled={page >= pages || loading} onclick={() => onchange(page + 1)}>
      Next →
    </button>
  </nav>
{/if}

<style>
  .pg {
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 16px;
    margin: 24px 0 0;
  }
  .chip:disabled {
    opacity: 0.4;
    cursor: default;
  }
  .ind {
    font-size: 13px;
    min-width: 130px;
    text-align: center;
  }
</style>
