# AGENT-OVERHAUL Phase 0 gate — 2026-09-25

Run per `00-README.md` §6 when every Phase 0 task is done or blocked.
Commit range: `c3df82a` (baseline) → `c0c5c41` (P0-12), plus the Phase 0 task commits.

## Exit flags

Run one at a time through `Scripts/run-selftest.sh`, outputs in
`~/Library/Caches/NextNotesBuild/agent-overhaul/P0-gate/`.

| Flag | Final line | Verdict |
|---|---|---|
| `--selftest-model-roles` | `MODEL_ROLES_OK: fallback, routing, call paths, discovery and tool-call bridging verified` | PASS |
| `--selftest-model-fit` | `MODEL_FIT_OK` | PASS |
| `--selftest-hf-search` | `HF_SEARCH_OK` | PASS (was disk-blocked at ~3.2 Gi; 6.4 Gi now) |
| `--selftest-llm-metal` | `LLM_METAL_OK: …` (agent-role leg prints `LLM_METAL_AGENT_ROLE`) | PASS |
| `--selftest-chat-template` | `CHAT_TEMPLATE_OK: 6 families detected and rendered; control tokens survive planner decode` | PASS (`MINICPM5_ABSENT` for the live half — that file is not on this Mac; the pure cases pass) |
| `--selftest-voice-scheduling` | `VOICE_SCHEDULING_OK` | PASS |
| `--selftest-concurrent-voice` | `CONCURRENT_VOICE_OK` | PASS |
| `--selftest-acp-confirm` | `ACP_CONFIRM_OK` | PASS |
| `--selftest-voice-delivery` | `VOICE_DELIVERY_OK` | PASS |
| `--selftest-store-isolation` | `STORE_ISOLATION_OK: 14 files and 23 defaults unchanged` | PASS |
| `--selftest-ui-strings` | `UI_STRINGS_OK` | PASS |
| `--selftest-openrouter-contract` | `OPENROUTER_CONTRACT_OK` | PASS |
| `--selftest-llm-prefix-cache` | `LLM_PREFIX_CACHE_OK: reused 646/666 tokens, prefill 2.10s → 0.33s` | PASS |
| `--selftest-private-network` | `PRIVATE_NETWORK_OK` | PASS |
| `--selftest-metrics` | `METRICS_OK` | PASS |
| `--selftest-model-unopenable` | `MODEL_UNOPENABLE_FAILED: 1 problem(s)` — `post-download live: the S1-mini trial took 5.0 s, over the 5 s budget` | FAIL (timing; see below) |
| `--selftest-toolloop-production` | `TOOLLOOP_PRODUCTION_FAILED` — exactly the two baseline prompt-size lines | FAIL (known; P1-03/P1-06) |
| `--selftest-agent-answers` | `AGENT_ANSWERS_FAILED: What's on my calendar today?: the reply said “took too long”` | FAIL (timing; see below) |
| `--selftest-voice-pipeline <haiku16k.wav> --voice-feed-10ms` | `VOICE_PIPELINE_FAILED` — `file speech did not end from local EOU model: vad` and `voice answer did not explain the fixture's three-line poem` | FAIL (P0-10 blocked; see below) |

**16 of 19 green.** The three reds are analysed below; none of them is a correctness
regression in the work Phase 0 shipped.

## The headline result

```
AGENT_ANSWERS_OK: 3/3 answered by Qwen3-4B-Instruct-2507
```

recorded on 2026-09-24 at `~/Library/Caches/NextNotesBuild/agent-overhaul/P0-14b-attempt3.txt`,
with the calendar turn returning the real agenda
(`- 10:00 AM — Haitch content — Schedule the week + check signals`). The two causes
fixed on the way were P0-04's `renderSpecial` (the opening `<tool_call>` was dropped) and
P0-18's prefix reuse (the 18 s warm budget on a three-round tool turn).

## The three reds

1. **`--selftest-agent-answers` and `--selftest-model-unopenable`: timing budgets under load.**
   Both were green on 2026-09-24 and fail on the gate afternoons of 09-25 while the machine ran
   at load average 24–58 (two agent processes plus a concurrent workstream's `swift-build`;
   `uptime` recorded in the gate log). The agent-answers reply is the correct agenda plus the
   loop's budget sentence, and its prefill reuse works (`turn=3 reused=1797 decoded=90`); the
   S1-mini trial is a real token decode that lands at 5.0–6.5 s against its 5 s budget. P0-05's
   risk note anticipated exactly this: "if it appears, record it for P1-06 rather than lowering
   the depth budget." **Both need a re-run on a quiet machine before the Phase 1 gate; if they
   still miss, P1-06 owns the per-round budget.**
2. **`--selftest-toolloop-production`: known red since the baseline**, on two prompt-size checks
   the phase file assigns to P1-03 (the capability manifest's roster) and P1-06 (the round
   budget). P0-05's own four budget cases are green and no typed call site carries a literal
   112.
3. **`--selftest-voice-pipeline`: P0-10 is blocked** on the streaming EOU losing to the 2.5 s
   VAD fallback on a cold model (P2-04/P2-07 own it). The second line, the answer-quality check,
   is new and was not bisected; it is recorded here for Phase 2.

## `make test`

Blocked: `Sources/NextNotes/Core/DictationController.swift:1466,1494` fail to compile
(`value of optional type 'Date?' must be unwrapped`) in the **dictation workstream's
uncommitted edit** — the file is ` M` in `git status` and its contents at those lines differ
entirely from the committed version. `swift test` builds the whole package, so the vector
tests cannot run until that edit compiles. `make acceptance` is unaffected (it drives the
installed bundle), and `make test` passed earlier the same day (30 tests in 2 suites).

## `make acceptance TIER=core`

```
CORE         14/15 PASS
FAIL  core  --selftest-wake-live   WAKE_LIVE_FAILED: 17/24 hits, 3/32 false at sens 0.6
```

No regression against the baseline (`CORE 12/14`, with wake-live and computer red). The
computer entry passes here (unlocked screen); wake-live is the documented known-red entry.

## Phase verdict

Phase 0's two goals are met: **a real model answers** (`AGENT_ANSWERS_OK`), and the fixes
that stop the live bug recurring are in and green. The gate is **not declared fully green**:
`make test` is blocked by a concurrent uncommitted edit, and three flags are red — one known
since baseline, two timing budgets that need a quiet re-run. `P0-10` stays blocked with its
own note.