<script lang="ts">
  let {
    label,
    value,
    unit = '',
    sub = ''
  }: { label: string; value: string; unit?: string; sub?: string } = $props();
</script>

<div class="stat card">
  <p class="label">{label}</p>
  <p class="value">{value}{#if unit}<span class="unit">{unit}</span>{/if}</p>
  {#if sub}<p class="sub muted">{sub}</p>{/if}
</div>

<style>
  .stat {
    padding: 20px 22px;
    display: flex;
    flex-direction: column;
    gap: 6px;
  }
  .label {
    margin: 0;
    font-size: 13px;
    font-weight: 600;
    color: var(--muted);
  }
  .value {
    margin: 0;
    font-family: var(--display);
    font-weight: 600;
    font-size: clamp(34px, 6vw, 46px);
    line-height: 1;
    letter-spacing: -0.02em;
    color: var(--pen);
  }
  .unit {
    font-size: 0.5em;
    color: var(--ink);
    margin-left: 3px;
  }
  .sub {
    margin: 0;
    font-size: 13px;
    line-height: 1.4;
  }
</style>
