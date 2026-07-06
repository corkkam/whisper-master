<script lang="ts">
  const steps = [
    {
      n: '1',
      title: 'Real speech goes in',
      body: 'We feed real recordings — 20 clips of real human speech (LibriSpeech), plus synthetic, noisy-room, and Bluetooth-mic versions of every case.'
    },
    {
      n: '2',
      title: 'The actual shipping app runs',
      body: 'Each clip runs through the exact pipeline you get in the app — the same transcription and the same cleanup, not a stand-in or a mock.'
    },
    {
      n: '3',
      title: 'It is graded objectively',
      body: 'We check keyword rules, word-error-rate against the reference, and a faithfulness guard that must never let cleanup answer or obey the words spoken.'
    },
    {
      n: '4',
      title: 'Claude judges the rest',
      body: 'Finally Claude reads the before/after and rates the subjective quality that fixed rules cannot — did it read naturally, keep the meaning?'
    }
  ];
</script>

<section class="how">
  <h2>How we test it</h2>
  <ol>
    {#each steps as s (s.n)}
      <li class="card">
        <span class="n">{s.n}</span>
        <div>
          <p class="t">{s.title}</p>
          <p class="b muted">{s.body}</p>
        </div>
      </li>
    {/each}
  </ol>
</section>

<style>
  .how {
    margin: 44px 0;
  }
  ol {
    list-style: none;
    padding: 0;
    margin: 18px 0 0;
    display: grid;
    grid-template-columns: repeat(2, 1fr);
    gap: 14px;
  }
  li {
    display: flex;
    gap: 14px;
    padding: 18px 20px;
    align-items: flex-start;
  }
  .n {
    font-family: var(--display);
    font-size: 22px;
    font-weight: 600;
    color: var(--pen);
    line-height: 1;
    flex: none;
  }
  .t {
    margin: 0 0 4px;
    font-weight: 600;
    font-size: 15px;
  }
  .b {
    margin: 0;
    font-size: 13.5px;
    line-height: 1.5;
  }
  @media (max-width: 640px) {
    ol {
      grid-template-columns: 1fr;
    }
  }
</style>
