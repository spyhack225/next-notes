# Tool loop live eval — 2026-10-01 01:58:06 +0000

- Model: `appLLM` "Qwen3-4B-Instruct-2507" ctx=32768 role=`installed:unsloth/Qwen3-4B-Instruct-2507-GGUF/Qwen3-4B-Instruct-2507-Q4_K_M.gguf`
- Mode: only; pass bar 1/1; elapsed 72.9s
- Needle first: yes
- Artifact: `unsloth/Qwen3-4B-Instruct-2507-GGUF/Qwen3-4B-Instruct-2507-Q4_K_M.gguf`; `/Users/sergekadjo/Library/Application Support/Next Notes/Models/unsloth--Qwen3-4B-Instruct-2507-Q4_K_M.gguf`; 2497281120 bytes
- Timing: per turn, first fixture result and completed reply; not first token or audio. One-time base-model warm-up excluded; Needle schema startup included. See JSONL.
- First verified fixture result: n=1, p50=12.818s, p95=12.818s
- Completed reply: n=1, p50=72.411s, p95=72.411s
- Whole case: n=1, p50=72.411s, p95=72.411s
- Needle outcomes: accepted=1
- App peak RSS: 2982461440 bytes; excludes the Needle child.
- Incomplete: a model turn exceeded the time limit. Partial cases are diagnostic, not a score.
- Classes: error=0 timeout=1 leak=0 refusal=0 wrong_tool=0 fabricated=0 missed_tool=0 ungrounded=0 filler=0 pass=0

| Case | Verdict | Seconds | Turns | Tools | Reply |
|---|---|---|---|---|---|
| M03 | TIMEOUT | 72.4 | 1 | search_email | This takes a few steps on this Mac.  1) Wed 30 Sep 20:56 · Cyril <cyril@example.com> · Dinner tomorrow? — Are you free tomorrow evening? 2) Wed 30 Sep 19:56 · Ana Ruiz <ana@example.com> · Deck for Friday — Can you send the deck by Friday? 3) Wed 30 Sep 18:56 · Marcus Lee <marcus@productflo.example>  |

## Non-PASS detail

### M03 TIMEOUT
- evidence: 09-15 01:13Z; expected fix: P1-06, P1-09
- rounds: 0; last prompt: system=-1 user=-1 maxTokens=-1

## Model passes

- M03: agent.typed/needle-first needle needle3 prompt=0 completion=0 reasoning=0 ttft=0ms total=10282ms finish=stop proposed=search_email executed=- · agent.typed/planner llama Qwen3-4B-Instruct-2507 prompt=0 completion=0 reasoning=0 ttft=0ms total=31577ms finish=timeout proposed=- executed=-
