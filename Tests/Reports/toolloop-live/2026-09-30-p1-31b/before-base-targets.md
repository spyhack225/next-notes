# Tool loop live eval — 2026-10-01 00:41:20 +0000

- Model: `appLLM` "Qwen3-4B-Instruct-2507" ctx=32768 role=`installed:unsloth/Qwen3-4B-Instruct-2507-GGUF/Qwen3-4B-Instruct-2507-Q4_K_M.gguf`
- Mode: only; pass bar 2/2; elapsed 85.0s
- Needle first: no
- Artifact: `unsloth/Qwen3-4B-Instruct-2507-GGUF/Qwen3-4B-Instruct-2507-Q4_K_M.gguf`; `/Users/sergekadjo/Library/Application Support/Next Notes/Models/unsloth--Qwen3-4B-Instruct-2507-Q4_K_M.gguf`; 2497281120 bytes
- Timing: per turn, first fixture result and completed reply; not first token or audio. One-time base-model warm-up excluded; Needle schema startup included. See JSONL.
- First verified fixture result: no observations
- Completed reply: n=3, p50=30.845s, p95=31.032s
- Whole case: n=3, p50=30.845s, p95=31.032s
- App peak RSS: 3683794944 bytes; excludes the Needle child.
- Incomplete: a model turn exceeded the time limit. Partial cases are diagnostic, not a score.
- Owner log (P1-27, not scored): 0/1 pass
- Classes: error=0 timeout=2 leak=0 refusal=0 wrong_tool=0 fabricated=0 missed_tool=1 ungrounded=0 filler=0 pass=0

| Case | Verdict | Seconds | Turns | Tools | Reply |
|---|---|---|---|---|---|
| Y01 | MISSED_TOOL | 22.9 | 1 |  | Got it. I’ll remember that your brother’s name is Cyril. |
| M04 | TIMEOUT | 31.0 | 1 |  | I ran out of time before finishing the rest. |
| O09 | TIMEOUT | 30.8 | 1 |  | This takes a few steps on this Mac.  I ran out of time before finishing the rest. |

## Non-PASS detail

### Y01 MISSED_TOOL
- evidence: memory write; expected fix: baseline
- rounds: 1; last prompt: system=5624 user=176 maxTokens=1024
- last completion:
```
Got it. I’ll remember that your brother’s name is Cyril.
```

### M04 TIMEOUT
- evidence: write token cap; expected fix: P1-02/P1-04
- rounds: 0; last prompt: system=-1 user=-1 maxTokens=-1

### O09 TIMEOUT
- evidence: J L1, L11 — two accounts in one turn; expected fix: P1-24 (multi-class)
- rounds: 0; last prompt: system=-1 user=-1 maxTokens=-1

## Model passes

- Y01: agent.typed/planner llama Qwen3-4B-Instruct-2507 prompt=1330 completion=14 reasoning=0 ttft=16751ms total=19365ms finish=stop proposed=- executed=-
- M04: agent.typed/planner llama Qwen3-4B-Instruct-2507 prompt=1741 completion=58 reasoning=0 ttft=19653ms total=30037ms finish=timeout proposed=- executed=-
- O09: agent.typed/planner llama Qwen3-4B-Instruct-2507 prompt=0 completion=0 reasoning=0 ttft=7491ms total=30369ms finish=timeout proposed=- executed=-

## Owner log (P1-27)

Not scored, and never inside the thirty. `TOOLLOOP_LIVE_OWNER` counts them; the Phase 1 exit gate reads them.

| Case | Verdict | Tools | Expected fix | Reply |
|---|---|---|---|---|
| O09 | TIMEOUT |  | P1-24 (multi-class) | This takes a few steps on this Mac.  I ran out of time before finishing the rest. |
