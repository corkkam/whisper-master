<script lang="ts">
  import '../app.css';
  let { children } = $props();
</script>

<div class="wrap">
  <header class="site">
    <a href="/" class="brand mono">◧ eval proof sheet</a>
    <span class="muted mono sub">dictation cleanup · run history</span>
  </header>
  {@render children()}
</div>

<style>
  .site {
    display: flex;
    align-items: baseline;
    gap: 14px;
    padding: 26px 0 20px;
    border-bottom: 2px solid var(--ink);
    margin-bottom: 8px;
    flex-wrap: wrap;
  }
  .brand {
    font-weight: 600;
    font-size: 16px;
    color: var(--pen);
  }
  .sub {
    font-size: 12px;
  }
</style>
