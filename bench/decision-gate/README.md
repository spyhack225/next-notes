# Decision-gate benchmark — laya vs Needle (Cactus)

Compares the open-source **"System One"** alternatives to Needle 3 (Cactus Compute)
for the function-calling watcher in `Sources/NextNotes/Agent/FunctionCalling/`.

Self-contained Python; it does not build or touch the app.

```bash
python3 -m venv --system-site-packages /tmp/decision-bench-venv   # or a clean venv, see below
. /tmp/decision-bench-venv/bin/activate
pip install laya                       # pulls torch + transformers (~600 MB weights on first predict)
python bench/decision-gate/bench.py    # every backend; writes results.json + report.md
```

On this Mac anaconda's bundled `scipy` is broken (`_spropack` dlopen breaks `transformers`'
import chain), so use a **clean** venv (`python3 -m venv` without `--system-site-packages`),
which installs a working torch 2.14 / transformers 5.17. Needle needs no setup — the harness
runs the already-downloaded CLI in `~/Library/Application Support/Next Notes/Models/`.

Flags: `--backends laya,needle,needle-serve`, `--laya-checkpoints multilingual,english,typed-decisions` (comma-separated).

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
(`FunctionCallSelfTest.fixtures`, expanded to 112 fixtures with the synonym traps,
context-window continuations, negations and safety negatives the original 14 could not
distinguish) and the app's own 8-tool catalogue (`FunctionCallCatalogue`, plus the
`no_action` abstention tool that `FunctionCallRelevance.wireTools` adds). Needle answers the
same gate by whether it emits a call, so it is the function-calling reference, not a
like-for-like typed-decision model.

---

## What was measured (2026-09-23, Apple M3 · 16 GB)

All four rows were measured in one pass on 2026-09-23, on the expanded 112-fixture set,
under a machine load average that sat between ~13 and ~27 (other agents working in the repo),
so the absolute millisecond figures are pessimistic against an idle Mac. Accuracy is
load-independent; only the clock moves. The same-day 14-fixture pass under load ~9 measured the spawn row at
310.3 ms p50 and the resident row at 70.6 ms, and this run's resident row still has a 72.4 ms
fastest turn — read the ratio and the answers, not the absolute milliseconds.

| backend | params | weights | start-up | peak RSS | p50 per proposal\* | exact-tool | family | is-request | silence on `none` | fired on request |
|---|---|---|---|---|---|---|---|---|---|---|
| laya-multilingual (smallest) | 322M | 644 MB | 29.1 s | ~2.5 GB† | 89.3 ms | 0.696 | 0.714 | 0.509 | **38/50** | 47/62 |
| laya-typed-decisions | 421M | 843 MB | 28.9 s | ~2.5 GB† | 462.3 ms | **0.741** | **0.786** | 0.527 | 32/50 | 58/62 |
| Needle 3 — spawn per proposal | 121M | **36 MB** | — | 100.7 MB | 994.7 ms (310.3 ms on the 14-fixture pass) | 0.732 | 0.768 | 0.786 | 35/50 | 53/62 |
| **Needle 3 — resident `--serve`** | 121M | **36 MB** | **0.897 s once** | **101.2 MB** | **277.0 ms** (70.6 ms on the 14-fixture pass) | 0.732 | 0.768 | **0.786** | 35/50 | 53/62 |

\*Not the same measurement. The **spawn** row is one child process per proposal, so its wall
clock includes process launch + model load + static-prefix prefill every time — that is what
the app did until 2026-09-23, and why 615 ms was never pure inference. The **resident** row is
the app's current shape: `NeedleServer` starts one `needle --serve` child, keeps it resident,
and sends `POST /reset` before each `POST /complete`. One 0.897 s start-up and one 247.8 ms
warm-up turn are paid once per meeting, not per sentence. laya's latency excludes its
one-time load (shown separately) and its ~2.5 GB RSS is the whole Python/torch runtime
resident, not just the model; when several laya checkpoints run in one process it is a shared
high-water mark.

The two Needle rows score identically on all 112 fixtures, which is the point: the server is a
latency change, not a behaviour change. `--selftest-function-calls` asserts the same thing on
the app side.

Full per-fixture grid and the published numbers for the unrun candidates are in
[`report.md`](report.md); raw rows in [`results.json`](results.json).

### Reading the result

- **The fine-tune trades silence for recall, and the larger set prices the trade.**
  `laya-typed-decisions` fires on 58/62 requests where the smallest checkpoint managed 47/62
  — but silence on `none` drops 38/50 → 32/50. Eight of its 18 false fires are browser,
  folder, media or search commands: `send_email` on the verbatim audit line "Open Google
  Chrome and go to youtube", `create_event` on "Play some music", `send_email` on "Click the
  Send button" and on "Launch Zoom for me". That is the exact failure class behind the app's
  2026-09-20 audit incident (a device command turned into a catalogue proposal), and the
  expanded set reproduces it on several fixtures rather than one.
- **The `noul` request gate is the weakest part of both checkpoints, and the fine-tune makes
  its two heads disagree.** is-request 0.509 (multilingual) and 0.527 (typed-decisions)
  against Needle's 0.786, and the head does not separate the classes at any threshold:
  0.005–0.991 on real requests vs 0.006–0.952 on `none` for the smallest checkpoint, and
  0.165–0.584 vs 0.107–0.644 for the fine-tune. Worse, its two outputs contradict each other:
  typed-decisions' `noul` says "request" on 31/112 sentences while its choice head fires a
  tool on 76/112, so the heads agree on just 55/112 (49%). laya's own README warned this —
  *"the base checkpoints are near chance on typed-decisions zero-shot … a fast base to
  specialise, not a zero-shot decision engine"* — and the fine-tune does not repair the
  boolean head; it moves the two heads further apart.
- **laya itself flags typed-decisions' confidence as uncalibrated**: the checkpoint ships a
  temperature of 0.1006, which the library clamps with `Treat confidence from the affected
  buckets as uncalibrated`. The app cannot trust the score it would gate on.
- **On the expanded set the exact-tool result is a split decision, not a sweep.**
  typed-decisions edges Needle on exact-tool (0.741 vs 0.732) and family (0.786 vs 0.768) —
  a one- and two-fixture margin, driven by the added calendar synonyms splitting the exact id
  (`schedule.create` vs `create_event`; neither model is consistent about the pair). Needle
  takes the request axis as the harness measures it, 0.786 vs 0.527. The added fixtures also
  expose Needle's own gate failures the small set could not: it fires on 15/50 `none` — all
  six false friends, three informational questions, "not to him", "forget the email to the
  vendor" and "type my email into the field" — and misses 9/62 requests, six of them calendar
  (the diary continuations with no time, and requests like "dentist on Friday morning" that
  come back as `none` at confidence 0.0). That is the case for keeping the deterministic gate
  over any model, not for replacing Needle.
- **Needle is still 1/23 the weights and ~1/25 the RAM**, while also doing the argument
  extraction none of the six can.
- **The 615 ms was architecture, not the model.** Run as the app runs it now — one resident
  `--serve` child instead of a process per proposal — the same 121M model decides 3.6x faster
  per proposal in the same pass (277.0 ms vs 994.7 ms p50, 72.4 ms on its fastest turn). The
  lighter 14-fixture pass earlier the same day measured 70.6 ms against the spawn row's
  310.3 ms; the ratio is the architecture's, the absolute number is the machine's load. The
  model did not change and neither did a single answer.
- **The deterministic question gate is still needed.** Needle and typed-decisions now get
  *"What's on my calendar this afternoon?"* right, but Needle turns *"what did Marcus say
  about the budget"*, *"did we send the deck"* and *"who's on the vendor thread"* into
  `reply_email`, and multilingual still proposes `create_event` for the calendar question —
  which is why `FunctionCallRelevance.isInformationalQuestion` stays.

### Conclusion

The best laya checkpoint is now a fixture-level tie with Needle on exact-tool and family
(0.741/0.786 vs 0.732/0.768 — one and two fixtures), but it is 23x the weights and ~25x the
RAM, it loses the request gate by 0.259 (0.527 vs 0.786), its own two heads contradict each
other, its confidence is flagged uncalibrated by its library, and its extra recall comes at
the cost of firing on device commands. None of the six candidates is a function-calling
model, so none replaces Needle; the relevance gate they could back is already done
deterministically and for free. The expanded set also shows Needle's own gate is not clean on
the new hard cases — which is the argument for keeping that deterministic gate, not for
trusting any model alone. **Recommendation: keep Needle.** If you want to re-evaluate, the
interesting candidate is `decider-2b` (MPS, 0.755 held-out) — it has a real Apple-Silicon
path; run it with `--backends` extended and a 2B download budget.

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
