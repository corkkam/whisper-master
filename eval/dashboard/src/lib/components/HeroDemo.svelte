<script lang="ts">
  import { browser } from '$app/environment';

  // Real inputs from the eval suite (cases.jsonl) paired with what the shipped
  // pipeline produces — a rotating "watch it work" demo, not a mockup.
  const demos = [
    {
      tag: 'Fixes self-corrections',
      said: 'the total comes to fifty no wait sixty dollars',
      typed: 'The total comes to $60.'
    },
    {
      tag: 'Strips fillers & stutters',
      said: 'i i i think we we should just go go now',
      typed: 'I think we should just go now.'
    },
    {
      tag: 'Formats numbers & times',
      said: "let's meet at four thirty this afternoon",
      typed: "Let's meet at 4:30 this afternoon."
    },
    {
      tag: 'Never answers, only cleans',
      said: 'who was the first president of the united states',
      typed: 'Who was the first president of the United States?'
    }
  ];

  let idx = $state(0);
  let paused = $state(false);

  $effect(() => {
    if (!browser || paused) return;
    if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) return;
    const t = setInterval(() => (idx = (idx + 1) % demos.length), 4500);
    return () => clearInterval(t);
  });

  const d = $derived(demos[idx]);
</script>

<div
  class="demo"
  role="group"
  aria-label="Example cleanups"
  onmouseenter={() => (paused = true)}
  onmouseleave={() => (paused = false)}
>
  <span class="tag">{d.tag}</span>

  {#key idx}
    <div class="pair">
      <div class="row">
        <span class="role">You said</span>
        <p class="messy">“{d.said}”</p>
      </div>
      <div class="mid"><span class="line"></span><span class="note">cleaned on your Mac</span><span class="line"></span></div>
      <div class="row">
        <span class="role pen">It typed</span>
        <p class="clean">{d.typed}</p>
      </div>
    </div>
  {/key}

  <div class="dots">
    {#each demos as _, i (i)}
      <button
        class="dot"
        class:on={i === idx}
        onclick={() => (idx = i)}
        aria-label="Example {i + 1}"
      ></button>
    {/each}
  </div>
</div>

<style>
  .demo {
    background: var(--card);
    border: 1px solid var(--rule);
    border-radius: 18px;
    padding: 26px 30px 22px;
    position: relative;
    overflow: hidden;
  }
  .tag {
    display: inline-block;
    font-size: 12px;
    font-weight: 650;
    letter-spacing: 0.02em;
    color: var(--pen);
    background: color-mix(in srgb, var(--pen) 10%, transparent);
    padding: 4px 11px;
    border-radius: 20px;
    margin-bottom: 20px;
  }
  .pair {
    animation: fade 0.5s ease;
  }
  @keyframes fade {
    from {
      opacity: 0;
      transform: translateY(4px);
    }
  }
  .row {
    display: flex;
    align-items: baseline;
    gap: 14px;
  }
  .role {
    flex: none;
    width: 66px;
    text-align: right;
    font-size: 12px;
    font-weight: 650;
    color: var(--faint);
    padding-top: 3px;
  }
  .role.pen {
    color: var(--pen);
  }
  .messy {
    margin: 0;
    font-family: var(--mono);
    font-size: 15px;
    color: var(--muted);
    line-height: 1.45;
  }
  .clean {
    margin: 0;
    font-family: var(--display);
    font-size: clamp(22px, 3.2vw, 30px);
    font-weight: 560;
    color: var(--ink);
    line-height: 1.2;
    letter-spacing: -0.01em;
  }
  .mid {
    display: flex;
    align-items: center;
    gap: 12px;
    margin: 13px 0 13px 80px;
  }
  .mid .line {
    height: 1px;
    background: var(--rule);
    flex: 1;
  }
  .mid .note {
    font-size: 11.5px;
    color: var(--faint);
    letter-spacing: 0.04em;
    text-transform: uppercase;
    white-space: nowrap;
  }
  .dots {
    display: flex;
    gap: 7px;
    margin-top: 22px;
    padding-left: 80px;
  }
  .dot {
    width: 22px;
    height: 4px;
    border-radius: 3px;
    border: none;
    padding: 0;
    background: var(--rule-2);
    cursor: pointer;
    transition: background 0.2s;
  }
  .dot.on {
    background: var(--pen);
  }
  @media (max-width: 560px) {
    .demo {
      padding: 22px 20px 18px;
    }
    .row {
      flex-direction: column;
      gap: 3px;
    }
    .role {
      width: auto;
      text-align: left;
    }
    .mid,
    .dots {
      margin-left: 0;
      padding-left: 0;
    }
  }
</style>
