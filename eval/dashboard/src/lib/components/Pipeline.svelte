<script lang="ts">
  const stages = [
    {
      k: 'Real speech',
      body: '20 real human clips, plus synthetic, noisy-room and Bluetooth-mic versions of every case.'
    },
    { k: 'Transcribe', body: 'The exact Parakeet model the app ships. No stand-in, no cloud.' },
    { k: 'Clean up', body: 'The shipped on device cleanup runs. Nothing ever leaves the Mac.' },
    {
      k: 'Grade',
      body: 'Keyword rules, word error vs the reference, a faithfulness guard, then Claude judges quality.'
    }
  ];
</script>

<section class="pipe">
  <h2>What happens to one clip</h2>
  <p class="muted cap">Every case rides the same assembly line the app uses, then gets graded at the end.</p>

  <ol>
    {#each stages as s, i (s.k)}
      <li>
        <div class="stage">
          <span class="num">{i + 1}</span>
          <p class="k">{s.k}</p>
          <p class="b muted">{s.body}</p>
        </div>
      </li>
      {#if i < stages.length - 1}
        <li class="arrow" aria-hidden="true">→</li>
      {/if}
    {/each}
  </ol>
</section>

<style>
  .pipe {
    margin: 48px 0;
  }
  .cap {
    font-size: 14px;
    margin: 4px 0 20px;
    max-width: 62ch;
  }
  ol {
    list-style: none;
    margin: 0;
    padding: 0;
    display: flex;
    align-items: stretch;
    gap: 6px;
  }
  li {
    flex: 1;
  }
  li.arrow {
    flex: none;
    display: flex;
    align-items: center;
    justify-content: center;
    color: var(--pen);
    font-size: 22px;
    padding: 0 2px;
  }
  .stage {
    height: 100%;
    background: var(--card);
    border: 1px solid var(--rule);
    border-radius: 14px;
    padding: 18px 18px 20px;
  }
  .num {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 26px;
    height: 26px;
    border-radius: 50%;
    background: color-mix(in srgb, var(--pen) 12%, transparent);
    color: var(--pen);
    font-family: var(--display);
    font-weight: 640;
    font-size: 14px;
  }
  .k {
    margin: 12px 0 5px;
    font-weight: 650;
    font-size: 15.5px;
  }
  .b {
    margin: 0;
    font-size: 13px;
    line-height: 1.5;
  }
  @media (max-width: 760px) {
    ol {
      flex-direction: column;
      gap: 4px;
    }
    li {
      flex: none;
    }
    li.arrow {
      transform: rotate(90deg);
      padding: 2px 0;
    }
  }
</style>
