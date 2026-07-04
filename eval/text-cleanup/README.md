# Text-cleanup model eval

Decide whether a small on-device LLM can reliably clean up dictated text
(fix "one day" vs "1 day", strip fillers, resolve self-corrections, punctuate)
**without** rephrasing, answering, or dropping content. We test with Ollama to
judge quality cheaply before committing to an MLX integration in the app.

> Ollama uses llama.cpp/GGUF, not MLX (what we'd ship). So these numbers judge
> **quality** reliably and give a **rough** latency ballpark. Final speed gets
> confirmed in MLX once we pick a model.

## 1. Pull the candidates (~1 GB tier + a couple of 3B references)

```bash
ollama pull gemma3:1b        # ~0.8 GB  — smallest realistic floor
ollama pull llama3.2:1b      # ~1.3 GB
ollama pull qwen2.5:1.5b     # ~1.0 GB
ollama pull qwen2.5:3b       # ~1.9 GB  — reference ceiling
ollama pull llama3.2:3b      # ~2.0 GB  — reference ceiling
```

Add more if you want (`gemma2:2b`, `smollm2:1.7b`, `phi3.5`). The point is to
find the **smallest model that passes**, then check its real memory/latency in
MLX.

## 2. Run the eval

```bash
python3 eval/text-cleanup/run.py
# or a subset:
python3 eval/text-cleanup/run.py --models gemma3:1b,qwen2.5:3b
```

Needs the Ollama app running (or `ollama serve`). Writes `report.md`
(side-by-side outputs + pass rates) and `raw.json`.

## 3. Read the results

- **`cases.jsonl`** — the scenarios, one JSON object per line. Add your own as
  you hit real-world misfires; this file is the lasting record of "what good
  output looks like."
- Auto-scoring is deliberately strict (substring must/must-not checks). The
  `"judge": true` cases are genuinely ambiguous (e.g. "chapter one") and are
  left for human eyeballing.
- What we're really watching for from small models: do they **over-edit** —
  answer a dictated question, rewrite a sentence, drop a list item, invent
  words? That failure matters more than a missed number, because it breaks
  trust. The `faithfulness` category targets exactly this.

## Prompt

`prompt.txt` is the system prompt (few-shot). It's as important as the model —
tune it here and re-run before concluding a model "can't do it."
