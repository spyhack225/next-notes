# Decision-gate benchmark: laya vs Needle (Cactus)

_Generated 2026-09-22 on Apple M3 · 8 cores · 16 GB. 14 fixtures from `FunctionCallSelfTest`, 8-tool catalogue from `FunctionCallCatalogue`._

> **Scope.** The six "System One" candidates are typed-decision models, not function-calling models. None can emit `to: "sarah@acme.com"`. This harness scores only the gate they *can* do -- is-it-a-request and which-tool -- and keeps Needle beside them as the function-calling reference. Argument extraction is Needle's job and is not compared here.

## Measured here

| backend | params | weights | load | p50 latency | mean | peak RSS | exact-tool | family | is-request | silence on none | fired on request |
|---|---|---|---|---|---|---|---|---|---|---|---|
| laya-multilingual | 322M | 644 MB | 28.7s | 81.6 ms | 80.9 ms | 3489.0 MB | 0.571 | 0.571 | 0.357 | 5/7 | 4/7 |
| laya-typed-decisions | 421M | 843 MB | 27.2s | 193.8 ms | 194.1 ms | 3489.0 MB | 0.643 | 0.643 | 0.357 | 4/7 | 6/7 |
| needle | 121M | 36 MB | -s | 615.0 ms | 601.6 ms | 98.2 MB | 0.786 | 0.786 | 0.786 | 5/7 | 6/7 |

Needle's latency includes process launch + model load on every row, because that is how the app runs it (one child process per proposal); laya's excludes its one-time load, shown separately. The two are not the same measurement -- see README. laya's peak RSS is the whole Python/torch runtime; when several laya checkpoints run in one process it is a shared high-water mark, so read the laya rows as one number.

### Per-fixture decisions

| fixture | gold | laya-multilingual | laya-typed-decisions | needle |
|---|---|---|---|---|
| address said out loud | `send_email` | ✓ send_email (noul 0.327) | ✓ send_email (noul 0.365) | ✓ send_email (conf 1.0) |
| no address anywhere | `send_email` | ✗ none (noul 0.84) | ✓ send_email (noul 0.44) | ✓ send_email (conf 1.0) |
| address said a minute earlier | `send_email` | ✗ none (noul 0.897) | ✓ send_email (noul 0.307) | ✓ send_email (conf 0.965) |
| ordinary conversation | `none` | ✓ none (noul 0.134) | ✓ none (noul 0.13) | ✓ none (conf 0.502) |
| browser command (verbatim audit line) | `none` | ✓ none (noul 0.409) | ✓ none (noul 0.599) | ✓ none (conf 0.988) |
| browser command, as said | `none` | ✓ none (noul 0.799) | ✗ send_email (noul 0.63) | ✓ none (conf 1.0) |
| a folder on this Mac | `none` | ✗ append_doc (noul 0.892) | ✗ memory.remember (noul 0.304) | ✓ none (conf 1.0) |
| media control | `none` | ✓ none (noul 0.407) | ✗ create_event (noul 0.463) | ✗ create_doc (conf 0.294) |
| a question about the diary | `none` | ✗ create_event (noul 0.576) | ✓ none (noul 0.168) | ✗ create_event (conf 0.427) |
| a search somebody asked for out loud | `none` | ✓ none (noul 0.736) | ✓ none (noul 0.457) | ✓ none (conf 1.0) |
| append a line to a doc | `append_doc` | ✓ append_doc (noul 0.438) | ✓ append_doc (noul 0.454) | ✓ append_doc (conf 1.0) |
| open the doc and add to it | `append_doc` | ✓ append_doc (noul 0.105) | ✓ append_doc (noul 0.414) | ✓ append_doc (conf 0.963) |
| diary entry for Thursday | `create_event` | ✗ none (noul 0.178) | ✗ append_doc (noul 0.351) | ✓ create_event (conf 1.0) |
| put the review in the diary | `create_event` | ✗ memory.remember (noul 0.228) | ✗ none (noul 0.357) | ✗ none (conf 1.0) |

## The other candidates (published, not measured here)

These need CUDA and/or won't fit beside a ~19 GB free disk, so they are reported from their own READMEs/model cards, read 2026-09-22. **Not run on this machine.**

| model | class | params | size | speed (published) | accuracy (published) | why not run |
|---|---|---|---|---|---|---|
| NanoJev | decision heads (Qwen3-0.6B) | 0.6B | ~1.2 GB bf16 | parallel; CUDA service | ViZDoom Basic 128/128 (game tasks) | CUDA service only (serve_decisions.py); game/RL oriented, not text-tool gating |
| SemIf (ex-OpenJev) | typed logits (Qwen3.5-4B) | 4B | 3.01 GB Q4 GGUF / ~8 GB bf16 | 1.02 s for 21 decisions (RTX 3090); MPS ~133 ms-ish path exists | authored decisions 0.813 bal-acc (4B BF16) | 4B; MPS path exists but heavy for 19 GB disk |
| decider (Mapika) | typed decisions (Qwen3.5) | 2B / 4B / 35B | 2B ~4 GB, 4B 8.4 GB, 35B 65 GB | 2B 133 ms MPS (M1 Pro); 43 ms B300 | held-out 0.755 (2B) / 0.788 (4B) regression set | 2B has an MPS path but was out of the requested download budget |
| openjev | NLI cross-encoder (Qwen3.5) | 0.8B / 4B / 35B | 0.8B ~1.6 GB … 35B MoE | 321 pairs/s SGLang (A6000) | MNLI 86.6, ANLI r1 65.3 (0.8B) | NLI primitive, CUDA/SGLang oriented; not a tool gate |
| Bespoke-Nimble-9B | LoRA over Qwen3.5-9B | 9B (+165 MB adapter) | ~18 GB base + adapter | CUDA BF16 only | Bespoke suite 0.757 (decider's re-run) | needs CUDA + the 9B base; won't fit on this disk |
