<script lang="ts">
  import DiffText from './DiffText.svelte';
  import type { CaseGroup } from '$lib/types';

  let { c }: { c: CaseGroup } = $props();
  const order = ['light', 'polish'];

  function werColor(w: number): string {
    if (w < 0.05) return 'var(--approve)';
    if (w < 0.15) return '#8a8f3a';
    if (w < 0.3) return 'var(--pen)';
    return 'var(--flag)';
  }
</script>

<div class="case">
  <div class="top">
    <span class="id mono">{c.caseId}</span>
    <span class="tag">{c.category ?? '—'}</span>
    <span class="tag">{c.source}</span>
    <span class="verdict {c.anyFail ? 'fail' : 'pass'}">{c.anyFail ? 'needs review' : 'clean'}</span>
  </div>

  <div class="lines">
    {#if c.inputKind === 'audio' && c.asrReference != null}
      <div class="line">
        <span class="role pen">heard</span>
        <span>
          <DiffText base={c.asrReference} text={c.asrText ?? ''} />
          {#if c.wer != null}
            <span
              class="wer"
              style="color:{werColor(c.wer)};background:color-mix(in srgb,{werColor(c.wer)} 12%,transparent)"
              >WER {Math.round(c.wer * 100)}%</span
            >
          {/if}
        </span>
      </div>
    {/if}

    <div class="line">
      <span class="role">det</span>
      <span><DiffText text={c.deterministic} /></span>
    </div>

    {#each order as t (t)}
      {#if c.targets[t]}
        {@const r = c.targets[t]}
        <div class="line">
          <span class="role">{t}</span>
          <span>
            <DiffText base={c.deterministic} text={r.llmOutput} />
            {#if r.latencyMs?.llm != null}<span class="lat mono muted"> · {r.latencyMs.llm}ms</span>{/if}
            {#if !r.guardAccepted}<span class="rej"> · guard rejected → kept deterministic</span>{/if}
          </span>
        </div>
      {/if}
    {/each}

    {#each order as t (t)}
      {#if c.targets[t] && !c.targets[t].mechanicalPass}
        {@const r = c.targets[t]}
        <div class="line">
          <span class="role fail">✕ {t}</span>
          <span class="txt muted">
            {r.reasons.join('; ')}
            {#if r.attribution}<b class="attr {r.attribution}">— {r.attribution}</b>{/if}
          </span>
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
    gap: 12px;
    flex-wrap: wrap;
  }
  .id {
    font-weight: 600;
    font-size: 14px;
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
    grid-template-columns: 78px 1fr;
    gap: 14px;
    align-items: baseline;
  }
  .role {
    font-family: var(--mono);
    font-size: 11px;
    letter-spacing: 0.04em;
    text-transform: uppercase;
    color: var(--muted);
    text-align: right;
    padding-top: 2px;
  }
  .role.pen {
    color: var(--pen);
  }
  .role.fail {
    color: var(--flag);
  }
  .wer {
    font-family: var(--mono);
    font-size: 11px;
    font-weight: 700;
    padding: 2px 7px;
    border-radius: 5px;
    margin-left: 8px;
    white-space: nowrap;
  }
  .rej {
    font-family: var(--mono);
    font-size: 11px;
    color: var(--flag);
  }
  .attr.asr {
    color: var(--pen);
  }
  .attr.cleanup {
    color: var(--flag);
  }
</style>
