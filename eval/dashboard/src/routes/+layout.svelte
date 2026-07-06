<script lang="ts">
  import '@fontsource-variable/fraunces';
  import '@fontsource-variable/inter';
  import '@fontsource-variable/jetbrains-mono';
  import '../app.css';
  import { browser } from '$app/environment';
  import { QueryClient, QueryClientProvider } from '@tanstack/svelte-query';

  let { children } = $props();

  // One client per request (SSR-safe: +layout.svelte re-instantiates per render,
  // so server caches never leak across requests). Queries only run in the
  // browser; the server renders from each page's `load` initialData.
  const queryClient = new QueryClient({
    defaultOptions: {
      queries: { enabled: browser, staleTime: 60_000, refetchOnWindowFocus: false }
    }
  });
</script>

<QueryClientProvider client={queryClient}>
  <div class="wrap">
    <header class="site">
      <a href="/" class="brand">Whisper&nbsp;Master <span class="pen">· eval</span></a>
      <span class="muted sub">how we test on device dictation cleanup</span>
    </header>
    {@render children()}
  </div>
</QueryClientProvider>

<style>
  .site {
    display: flex;
    align-items: baseline;
    gap: 14px;
    padding: 26px 0 20px;
    border-bottom: 1px solid var(--rule);
    margin-bottom: 30px;
    flex-wrap: wrap;
  }
  .brand {
    font-family: var(--display);
    font-weight: 600;
    font-size: 19px;
  }
  .brand .pen {
    color: var(--pen);
  }
  .sub {
    font-size: 13px;
  }
</style>
