# Decision-gate benchmark — laya vs Needle (Cactus)

Compares the open-source **"System One"** alternatives to Needle 3 (Cactus Compute)
for the function-calling watcher in `Sources/NextNotes/Agent/FunctionCalling/`.

Self-contained Python; it does not build or touch the app.

```bash
python3 -m venv --system-site-packages /tmp/decision-bench-venv   # or a clean venv, see below
. /tmp/decision-bench-venv/bin/activate
pip install laya                       # pulls torch + transformers (~600 MB weights on first predict)
python bench/decision-gate/bench.py    # both backends; writes results.json + report.md
```

On this Mac anaconda's bundled `scipy` is broken (`_spropack` dlopen breaks `transformers`'
import chain), so use a **clean** venv (`python3 -m venv` without `--system-site-packages`),
which installs a working torch 2.14 / transformers 5.17. Needle needs no setup — the harness
runs the already-downloaded CLI in `~/Library/Application Support/Next Notes/Models/`.

Flags: `--backends laya,needle`, `--laya-checkpoint multilingual|english|typed-decisions`.

---

## The finding that reframes the question

**None of the six candidates is a function-calling model.** Needle 3 emits real
`function_calls` with arbitrary typed `arguments`, a calibrated `confidence`, and grounding
validation (`validation.ungrounded`, `negation`). The six alternatives — NanoJev, laya,
openjev, Bespoke-Nimble-9B, SemIf, decider — are all **typed-decision** models (Jev-style
"System One"): in one forward pass they answer a fixed-option `choice`, an ordinal `score`,
or a `noul` (probability of yes), and **generate no text**. None can produce
`to: "sarah@acme.com", subject: "Q3 deck"` from an utterance. Argument extraction is the
reason Needle exists here, and nothing in this list does it.

So they are not drop-in replacements for `FunctionCallProposer`. The only seat they could
fill is the **decision gate** the app currently implements deterministically in
`FunctionCallRelevance` / `FunctionCallGrounding`:

1. *Is this utterance an actionable request at all?* → a `noul`
2. *Which of the ≤8 catalogue tools, or none?* → a `choice`

This harness scores **exactly that gate**, on the app's own fixtures
(`FunctionCallSelfTest.fixtures`) and the app's own 8-tool catalogue
(`FunctionCallCatalogue`, plus the `no_action` abstention tool that
`FunctionCallRelevance.wireTools` adds). Needle answers the same gate by whether it emits a
call, so it is the function-calling reference, not a like-for-like typed-decision model.

---

## What was measured (2026-09-22, Apple M3 · 16 GB)

| backend | params | weights | peak RSS | p50 latency\* | exact-tool | family | is-request | silence on `none` | fired on request |
|---|---|---|---|---|---|---|---|---|---|
| laya-multilingual (smallest) | 322M | 644 MB | ~2.6–2.8 GB† | 84 ms | 0.571 | 0.571 | 0.357 | 5/7 | 4/7 |
| laya-typed-decisions | 421M | 843 MB | ~2.6–2.8 GB† | 200 ms | 0.643 | 0.643 | **0.357** | **4/7** | 6/7 |
| **Needle 3** (Cactus) | 121M | **36 MB** | **98 MB** | 428 ms | **0.786** | **0.786** | **0.786** | 5/7 | 6/7 |

\*Not the same measurement. Needle's wall clock **includes process launch + model load on
every row**, because the app spawns one child process per proposal — that is the honest
production number. laya's excludes its one-time load (29 s / 37 s, shown separately) and its
~2.7 GB RSS is the whole Python/torch runtime resident, not just the model; when several
laya checkpoints run in one process it is a shared high-water mark. Per *forward pass* laya
is faster; per *proposal as the app ships it*, Needle's number already includes everything.

Full per-fixture grid and the published numbers for the unrun candidates are in
[`report.md`](report.md); raw rows in [`results.json`](results.json).

### Reading the result

- **The fine-tune trades silence for recall.** `laya-typed-decisions` fixes the two email
  requests the smallest checkpoint missed (`send Marcus the pricing sheet`, the
  context-window continuation) — but it now **fires `send_email` on "Open Google Chrome and
  go to youtube"** and `create_event` on "Play some music". Silence on `none` drops 5/7 →
  4/7, and one of those false fires is the exact failure class behind the app's 2026-09-20
  audit incident (a device command turned into a catalogue proposal).
- **The `noul` request gate is equally broken in both checkpoints** (is-request 0.357
  either way): 0.31–0.44 on real requests that must fire, 0.60–0.89 on browser/folder
  commands that must stay silent. laya's own README warned this — *"the base checkpoints are
  near chance on typed-decisions zero-shot … a fast base to specialise, not a zero-shot
  decision engine"* — and the fine-tune does not repair the boolean head.
- **laya itself flags typed-decisions' confidence as uncalibrated**: the checkpoint ships a
  temperature of 0.1006, which the library clamps with `Treat confidence from the affected
  buckets as uncalibrated`. The app cannot trust the score it would gate on.
- **Needle wins every accuracy axis at 1/23 the weights and 1/29 the RAM**, while also doing
  the argument extraction none of the six can.
- Both laya checkpoints and Needle miss *"What's on my calendar this afternoon?"* (a
  question, not a request) — which is precisely why the app does not trust the model alone
  and keeps `FunctionCallRelevance.isInformationalQuestion` as a deterministic gate on top.

### Conclusion

The best laya checkpoint is still **larger, hungrier and less accurate** than Needle on
every gate axis, its confidence is flagged uncalibrated by its own library, and its one
improvement came at the cost of firing on device commands. None of the six candidates is a
function-calling model, so none replaces Needle; the relevance gate they could back is
already done deterministically and for free. **Recommendation: keep Needle.** If you want to
re-evaluate, the interesting candidate is `decider-2b` (MPS, 0.755 held-out) — it has a real
Apple-Silicon path; run it with `--backends` extended and a 2B download budget.

---

## The candidates that could not run here

`report.md` carries their published size/speed/accuracy. In short, on a 16 GB / ~19 GB-free
M-series Mac with **no CUDA**:

| model | runs here? | blocker |
|---|---|---|
| NanoJev (0.6B) | no | CUDA service only (`serve_decisions.py`); game/RL oriented |
| laya-multilingual (322M) | **yes** | — (measured above) |
| laya / laya-typed-decisions (421M) | **yes** | laya-typed-decisions measured above; the English base was not |
| SemIf (Qwen3.5-4B) | partial | MPS/MLX/llama.cpp path exists but 4B is heavy for this disk |
| decider-2b (Qwen3.5-2B) | partial | MPS path exists (~133 ms); out of the requested download budget |
| openjev (0.8B/4B/35B) | no/partial | NLI primitive, CUDA/SGLang oriented |
| Bespoke-Nimble-9B | no | needs CUDA + the ~18 GB Qwen3.5-9B base |
