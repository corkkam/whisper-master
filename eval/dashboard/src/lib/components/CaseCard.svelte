<script lang="ts">
  import DiffText from './DiffText.svelte';
  import type { CaseGroup } from '$lib/types';

  let { c }: { c: CaseGroup } = $props();
  const order = ['light', 'polish'];
  const roleLabel: Record<string, string> = { light: 'Light', polish: 'Polish' };

  function werColor(w: number): string {
    if (w < 0.05) return 'var(--approve)';
    if (w < 0.15) return '#8a8f3a';
    if (w < 0.3) return 'var(--pen)';
    return 'var(--flag)';
  }
</script>

<div class="case">
  <div class="top">
    <span class="id">{c.caseId}</span>
    {#if c.category}<span class="tag">{c.category}</span>{/if}
    <span class="tag">{c.source}</span>
    <span class="verdict {c.anyFail ? 'fail' : 'pass'}">{c.anyFail ? 'needs review' : 'clean'}</span>
  </div>

  <div class="lines">
    {#if c.inputKind === 'audio' && c.asrReference != null}
      <div class="line">
        <span class="role heard">Heard</span>
        <span class="txt">
          <DiffText base={c.asrReference} text={c.asrText ?? ''} />
          {#if c.wer != null}
            <span
              class="wer"
              style="color:{werColor(c.wer)};background:color-mix(in srgb,{werColor(
                c.wer
              )} 12%,transparent)">{Math.round(c.wer * 100)}% misheard</span
            >
          {/if}
        </span>
      </div>
    {/if}

    <div class="line">
      <span class="role">Instant</span>
      <span class="txt"><DiffText text={c.deterministic} /></span>
    </div>

    {#each order as t (t)}
      {#if c.targets[t]}
        {@const r = c.targets[t]}
        <div class="line">
          <span class="role">{roleLabel[t]}</span>
          <span class="txt">
            <DiffText base={c.deterministic} text={r.llmOutput} />
            {#if r.latencyMs?.llm != null}<span class="lat muted"> · {r.latencyMs.llm}ms</span>{/if}
            {#if !r.guardAccepted}<span class="rej"> · kept safe: cleanup rejected, original kept</span
              >{/if}
          </span>
        </div>
      {/if}
    {/each}

    {#each order as t (t)}
      {#if c.targets[t] && !c.targets[t].mechanicalPass}
        {@const r = c.targets[t]}
        <div class="line why">
          <span class="role fail">Why {roleLabel[t]}?</span>
          <span class="txt muted">{r.reasons.join('; ')}</span>
        </div>
      {/if}
    {/each}
  </div>
</div>

<style>
  .case {
    border-bottom: 1px solid var(--rule);
    padding: 22px 0;
  }
  .top {
    display: flex;
    align-items: baseline;
    gap: 10px;
    flex-wrap: wrap;
  }
  .id {
    font-family: var(--mono);
    font-weight: 600;
    font-size: 13.5px;
  }
  .top .verdict {
    margin-left: auto;
  }
  .lines {
    margin-top: 14px;
    display: grid;
    gap: 9px;
  }
  .line {
    display: grid;
    grid-template-columns: 84px 1fr;
    gap: 14px;
    align-items: baseline;
  }
  .role {
    font-size: 11.5px;
    font-weight: 650;
    letter-spacing: 0.02em;
    color: var(--muted);
    text-align: right;
    padding-top: 2px;
  }
  .role.heard {
    color: var(--pen);
  }
  .role.fail {
    color: var(--flag);
  }
  .wer {
    font-size: 11px;
    font-weight: 700;
    padding: 2px 7px;
    border-radius: 5px;
    margin-left: 8px;
    white-space: nowrap;
  }
  .lat {
    font-family: var(--mono);
    font-size: 11px;
  }
  .rej {
    font-size: 11.5px;
    color: var(--approve);
  }
  .why .txt {
    font-family: var(--sans);
    font-size: 12.5px;
  }
  @media (max-width: 520px) {
    .line {
      grid-template-columns: 66px 1fr;
      gap: 10px;
    }
  }
</style>
