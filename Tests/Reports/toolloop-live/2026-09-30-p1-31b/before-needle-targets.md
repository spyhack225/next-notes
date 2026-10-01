# Tool loop live eval — 2026-10-01 00:48:54 +0000

- Model: `appLLM` "Qwen3-4B-Instruct-2507" ctx=32768 role=`installed:unsloth/Qwen3-4B-Instruct-2507-GGUF/Qwen3-4B-Instruct-2507-Q4_K_M.gguf`
- Mode: only; pass bar 2/2; elapsed 96.0s
- Needle first: yes
- Artifact: `unsloth/Qwen3-4B-Instruct-2507-GGUF/Qwen3-4B-Instruct-2507-Q4_K_M.gguf`; `/Users/sergekadjo/Library/Application Support/Next Notes/Models/unsloth--Qwen3-4B-Instruct-2507-Q4_K_M.gguf`; 2497281120 bytes
- Timing: per turn, first fixture result and completed reply; not first token or audio. One-time base-model warm-up excluded; Needle schema startup included. See JSONL.
- First verified fixture result: n=3, p50=2.876s, p95=28.488s
- Completed reply: n=3, p50=33.609s, p95=43.313s
- Whole case: n=3, p50=33.609s, p95=43.313s
- Needle outcomes: accepted=2, class-does-not-fit=1
- App peak RSS: 3617095680 bytes; excludes the Needle child.
- Incomplete: a model turn exceeded the time limit. Partial cases are diagnostic, not a score.
- Owner log (P1-27, not scored): 0/1 pass
- Classes: error=0 timeout=1 leak=0 refusal=0 wrong_tool=0 fabricated=0 missed_tool=1 ungrounded=0 filler=0 pass=1

| Case | Verdict | Seconds | Turns | Tools | Reply |
|---|---|---|---|---|---|
| Y01 | MISSED_TOOL | 19.0 | 1 | memory.recall(query=my brother's name) | Got it — your brother’s name is Cyril. I’ll keep that in mind. |
| M04 | PASS | 43.3 | 1 | draft_email(body=Hi Ana,  I'll send the deck on Friday.  Best regards, Serge,subject=Deck Delivery - Friday,to=ana@example.com) | I’ve drafted an email to ana@example.com saying you’ll send the deck on Friday. It’s ready for you to review or adjust. Let me know if you’d like to change anything. |
| O09 | TIMEOUT | 33.6 | 1 | search_email | This takes a few steps on this Mac.  1) Wed 30 Sep 19:47 · Cyril <cyril@example.com> · Dinner tomorrow? — Are you free tomorrow evening? 2) Wed 30 Sep 18:47 · Ana Ruiz <ana@example.com> · Deck for Friday — Can you send the deck by Friday? 3) Wed 30 Sep 17:47 · Marcus Lee <marcus@productflo.example>  |

## Non-PASS detail

### Y01 MISSED_TOOL
- evidence: memory write; expected fix: baseline
- rounds: 1; last prompt: system=5624 user=419 maxTokens=1024
- last completion:
```
Got it — your brother’s name is Cyril. I’ll keep that in mind.
```

### O09 TIMEOUT
- evidence: J L1, L11 — two accounts in one turn; expected fix: P1-24 (multi-class)
- rounds: 0; last prompt: system=-1 user=-1 maxTokens=-1

## Model passes

- Y01: agent.typed/needle-first needle needle3 prompt=0 completion=0 reasoning=0 ttft=0ms total=860ms finish=stop proposed=memory.recall executed=- · agent.typed/planner llama Qwen3-4B-Instruct-2507 prompt=1383 completion=17 reasoning=0 ttft=12902ms total=15197ms finish=stop proposed=- executed=-
- M04: agent.typed/planner llama Qwen3-4B-Instruct-2507 prompt=1741 completion=58 reasoning=0 ttft=19134ms total=28040ms finish=stop proposed=draft_email executed=draft_email · agent.typed/planner llama Qwen3-4B-Instruct-2507 prompt=1791 completion=39 reasoning=0 ttft=10116ms total=14772ms finish=stop proposed=- executed=-
- O09: agent.typed/needle-first needle needle3 prompt=0 completion=0 reasoning=0 ttft=0ms total=2848ms finish=stop proposed=search_email executed=- · agent.typed/planner llama Qwen3-4B-Instruct-2507 prompt=0 completion=0 reasoning=0 ttft=19477ms total=30612ms finish=timeout proposed=- executed=-

## Owner log (P1-27)

Not scored, and never inside the thirty. `TOOLLOOP_LIVE_OWNER` counts them; the Phase 1 exit gate reads them.

| Case | Verdict | Tools | Expected fix | Reply |
|---|---|---|---|---|
| O09 | TIMEOUT | search_email | P1-24 (multi-class) | This takes a few steps on this Mac.  1) Wed 30 Sep 19:47 · Cyril <cyril@example.com> · Dinner tomorrow? — Are you free tomorrow evening? 2) Wed 30 Sep 18:47 · Ana Ruiz <ana@example.com> · Deck for Friday — Can you send the deck by Friday? 3) Wed 30 Sep 17:47 · Marcus Lee <marcus@productflo.example>  |
