# Tool loop live eval — 2026-10-01 01:56:28 +0000

- Model: `appLLM` "Qwen3-4B-Instruct-2507" ctx=32768 role=`installed:unsloth/Qwen3-4B-Instruct-2507-GGUF/Qwen3-4B-Instruct-2507-Q4_K_M.gguf`
- Mode: only; pass bar 2/2; elapsed 176.4s
- Needle first: no
- Artifact: `unsloth/Qwen3-4B-Instruct-2507-GGUF/Qwen3-4B-Instruct-2507-Q4_K_M.gguf`; `/Users/sergekadjo/Library/Application Support/Next Notes/Models/unsloth--Qwen3-4B-Instruct-2507-Q4_K_M.gguf`; 2497281120 bytes
- Timing: per turn, first fixture result and completed reply; not first token or audio. One-time base-model warm-up excluded; Needle schema startup included. See JSONL.
- First verified fixture result: no observations
- Completed reply: n=3, p50=31.950s, p95=113.251s
- Whole case: n=3, p50=31.950s, p95=113.252s
- App peak RSS: 3036692480 bytes; excludes the Needle child.
- Incomplete: a model turn exceeded the time limit. Partial cases are diagnostic, not a score.
- Owner log (P1-27, not scored): 0/1 pass
- Classes: error=0 timeout=3 leak=0 refusal=0 wrong_tool=0 fabricated=0 missed_tool=0 ungrounded=0 filler=0 pass=0

| Case | Verdict | Seconds | Turns | Tools | Reply |
|---|---|---|---|---|---|
| Y01 | TIMEOUT | 113.3 | 1 |  | I ran out of time before finishing the rest. |
| M04 | TIMEOUT | 30.4 | 1 |  | I ran out of time before finishing the rest. |
| O09 | TIMEOUT | 31.9 | 1 |  | This takes a few steps on this Mac.  I ran out of time before finishing the rest. |

## Non-PASS detail

### Y01 TIMEOUT
- evidence: memory write; expected fix: baseline
- rounds: 0; last prompt: system=-1 user=-1 maxTokens=-1

### M04 TIMEOUT
- evidence: write token cap; expected fix: P1-02/P1-04
- rounds: 0; last prompt: system=-1 user=-1 maxTokens=-1

### O09 TIMEOUT
- evidence: J L1, L11 — two accounts in one turn; expected fix: P1-24 (multi-class)
- rounds: 0; last prompt: system=-1 user=-1 maxTokens=-1

## Model passes

- Y01: agent.typed/planner llama Qwen3-4B-Instruct-2507 prompt=0 completion=0 reasoning=0 ttft=0ms total=31192ms finish=timeout proposed=- executed=-
- M04: agent.typed/planner llama Qwen3-4B-Instruct-2507 prompt=0 completion=0 reasoning=0 ttft=18551ms total=30072ms finish=timeout proposed=- executed=-
- O09: agent.typed/planner llama Qwen3-4B-Instruct-2507 prompt=0 completion=0 reasoning=0 ttft=16102ms total=30545ms finish=timeout proposed=- executed=-

## Owner log (P1-27)

Not scored, and never inside the thirty. `TOOLLOOP_LIVE_OWNER` counts them; the Phase 1 exit gate reads them.

| Case | Verdict | Tools | Expected fix | Reply |
|---|---|---|---|---|
| O09 | TIMEOUT |  | P1-24 (multi-class) | This takes a few steps on this Mac.  I ran out of time before finishing the rest. |
