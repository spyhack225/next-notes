# Cleanup model head-to-head — 2026-09-30

Same corpus for every row: `CleanupEvalCases.all` (42 cases — shipped
transcripts, constructed error classes, adversarial instruction/question,
spoken-structure markers), graded by `CleanupEvalCases.failures` on the
guarded shipped text (what a dictation would have typed). One
production-faithful pass per case in the compare legs; the single-engine legs
add a second unguarded call per fixture to tell a rejection from a shrug.

Flags: `--selftest-cleanup app-llm` (active GGUF), `--selftest-cleanup
app-llm-compare` (every GGUF, new), `--selftest-cleanup apple-grammar`
(Apple FM), `--selftest-cleanup minicpm` (MiniCPM wiring, new). Model under
test in each row is the file that answered, never the picker label.

## Table (assertions failed / 42 — fewer is better)

| Model | File | Size | Failed | Median | Max | Notes |
|---|---|---|---|---|---|---|
| MiniCPM5-2B Q4_K_M | openbmb `MiniCPM5-2B-Q4_K_M.gguf` | 1.56 GB | **3** | **0.59 s** | 5.3 s | R6, C21 (2× `you know`); also wrote `UI/UX` for `ui ux` once |
| Apple FM (grammar) | OS-resident | 0 | **0** | 3.03 s | 9.33 s | 4 guard rejections, all replaced safely |
| Qwen3-4B-Instruct-2507 Q4_K_M | unsloth | 2.5 GB | 8 | 1.61 s | 8.42 s | incl. renumbering an explicit `- ` list to `1. ` (C16×3) |
| Qwen3.5-4B Q4_K_M | unsloth | 2.7 GB | 11 | 8.58 s | 9.28 s | restart, articles, word-order, debris cases |
| Gemma 4 E4B Q4_K_M | local file, unregistered | 5.0 GB | 3–11 | 2.62–8.51 s | 11.7–13.8 s | wide run-to-run swing, see below |
| MiniCPM5-2B | — | — | absent | — | — | first run predated the download |

MiniCPM5-2B numbers are the `app-llm-compare` row (production-faithful
single pass). The `minicpm` wiring leg (MiniCPM → Apple fallback) medians
0.69 s with the same 3 assertion classes — the wiring adds no overhead.

## Reading the result

- **MiniCPM5-2B is the speed-for-quality trade, not a sweep.** 5× faster
  median than Apple (0.59 s vs 3.03 s) with 3 misses against Apple's zero.
  Its misses are small (a preposition, two leftover fillers); Qwen's and the
  slow Gemma run's are structural (restarts, articles, word order).
- **Qwen3-4B beats Qwen3.5-4B on both axes** (8 vs 11, 1.61 s vs 8.58 s).
  Newer file is not a better file; version alone is not identity.
- **Gemma 4 E4B swung 11 → 3 between runs** (loaded machine vs quieter
  machine). Single-run GGUF numbers are weather, not climate; the ranking
  above is from the quieter run and should be re-measured before any flip.
- **Apple is still the only zero for quality and footprint.** Its 4 guard
  rejections (incl. an obeyed `write the word banana` injection — only the
  guard stood between that and the document) are the argument for keeping it
  as every GGUF's fallback, not just MiniCPM's.
- **Qwen's C16** (rewriting `- ` as `1. `) is the model doing layout work the
  deterministic stage owns — invisible without the `requires` assertions.

## Decision (owner, 2026-09-30)

MiniCPM5-2B ships as a dictation-cleanup picker row (`CleanupEngineChoice.miniCPM`,
`MiniCPMCleanupFormatter`: pinned file, shared runtime, Apple guard+fallback
from the original transcript). Apple stays the fresh-install default (a default
nobody can download is a picker row that lies; the Models tab does not offer
MiniCPM yet — SHARED-BRAIN SB-01 territory). This Mac runs MiniCPM now.

Out of scope, unchanged: the agent model and role (`modelRoles.agent`,
`activeAgentModelID` untouched — cleanup pins its own file and resolves
nothing through the agent); meeting notes; any cloud path.

## Reproduce

```bash
make install OPEN=0
Scripts/run-selftest.sh --selftest-cleanup app-llm-compare   # every GGUF, table
Scripts/run-selftest.sh --selftest-cleanup minicpm           # the wiring
Scripts/run-selftest.sh --selftest-cleanup apple-grammar     # the baseline
```

`app-llm-compare` skips files that are not here (`MODEL_COMPARE … absent`)
and files llama.cpp cannot open (vocabulary-only probe first, never a
full-weight load to answer the question). Quality differences are reported,
never gated — the table is the product.
