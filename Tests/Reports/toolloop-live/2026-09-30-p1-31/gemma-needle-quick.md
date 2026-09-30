# Tool loop live eval — 2026-09-30 21:39:03 +0000

- Model: `appLLM` "gemma-4-E4B-it-Q4_K_M" ctx=32768 role=`file:gemma-4-E4B-it-Q4_K_M`
- Mode: quick; pass bar 5/10; elapsed 271.8s
- Needle first: yes
- Artifact: `benchmark/gemma-4-E4B-it-Q4_K_M`; `/Users/sergekadjo/Library/Application Support/Next Notes/Models/gemma-4-E4B-it-Q4_K_M.gguf`; 4977171584 bytes
- Timing: per turn, first fixture result and completed reply; not first token or audio. One-time base-model warm-up excluded; Needle schema startup included. See JSONL.
- First verified fixture result: n=2, p50=2.184s, p95=25.151s
- Completed reply: n=6, p50=33.676s, p95=104.916s
- Whole case: n=5, p50=46.969s, p95=104.916s
- Needle outcomes: abstained=1, accepted=2, class-does-not-fit=1, error=1, rejected=1
- App peak RSS: 2935242752 bytes; excludes the Needle child.
- Incomplete: Needle failed on 1 turn(s). Partial cases are diagnostic, not a score.
- Classes: error=1 timeout=0 leak=0 refusal=0 wrong_tool=0 fabricated=2 missed_tool=1 ungrounded=1 filler=0 pass=0

| Case | Verdict | Seconds | Turns | Tools | Reply |
|---|---|---|---|---|---|
| C01 | FABRICATED | 104.9 | 1 |  | I ran out of time before finishing the rest. |
| C04 | FABRICATED | 34.3 | 1 |  | This takes a few steps on this Mac.  I ran out of time before finishing the rest. |
| M03 | UNGROUNDED | 56.2 | 1 | search_email(query=email) | No message matches email.  I ran out of time before finishing the rest. |
| M04 | MISSED_TOOL | 28.6 | 1 |  | I can draft that email for you. What should the subject line be? |
| M05 | ERROR | 47.0 | 2 | search_email | Are you asking me to do something with those emails? |

## Non-PASS detail

### C01 FABRICATED
- evidence: B §1 core tool; expected fix: baseline should pass
- rounds: 0; last prompt: system=-1 user=-1 maxTokens=-1

### C04 FABRICATED
- evidence: 09-22 00:58Z; expected fix: P1-02, P1-06
- rounds: 0; last prompt: system=-1 user=-1 maxTokens=-1

### M03 UNGROUNDED
- evidence: 09-15 01:13Z; expected fix: P1-06, P1-09
- rounds: 0; last prompt: system=-1 user=-1 maxTokens=-1

### M04 MISSED_TOOL
- evidence: write token cap; expected fix: P1-02/P1-04
- rounds: 1; last prompt: system=7449 user=91 maxTokens=1024
- last completion:
```
I can draft that email for you. What should the subject line be?
```

### M05 ERROR
- evidence: 09-22 five-denial loop; expected fix: P1-02
- rounds: 1; last prompt: system=6445 user=350 maxTokens=1024
- last completion:
```
Are you asking me to do something with those emails?
```

## Model passes

- C01: agent.typed/needle-first needle needle3 prompt=0 completion=0 reasoning=0 ttft=0ms total=1969ms finish=stop proposed=create_event executed=- · agent.typed/planner llama gemma-4-E4B-it-Q4_K_M prompt=0 completion=0 reasoning=0 ttft=17352ms total=31203ms finish=timeout proposed=- executed=-
- C04: agent.typed/needle-first needle needle3 prompt=0 completion=0 reasoning=0 ttft=0ms total=3233ms finish=stop proposed=- executed=- · agent.typed/planner llama gemma-4-E4B-it-Q4_K_M prompt=0 completion=0 reasoning=0 ttft=19073ms total=30279ms finish=timeout proposed=- executed=-
- M03: agent.typed/needle-first needle needle3 prompt=0 completion=0 reasoning=0 ttft=0ms total=24850ms finish=stop proposed=search_email executed=- · agent.typed/planner llama gemma-4-E4B-it-Q4_K_M prompt=0 completion=0 reasoning=0 ttft=23729ms total=30913ms finish=timeout proposed=- executed=-
- M04: agent.typed/planner llama gemma-4-E4B-it-Q4_K_M prompt=1817 completion=15 reasoning=0 ttft=25135ms total=27594ms finish=stop proposed=- executed=-
- M05: agent.typed/needle-first needle needle3 prompt=0 completion=0 reasoning=0 ttft=0ms total=2107ms finish=stop proposed=search_email executed=- · agent.typed/needle-first needle needle3 prompt=0 completion=0 reasoning=0 ttft=0ms total=17327ms finish=error proposed=- executed=- · agent.typed/planner llama gemma-4-E4B-it-Q4_K_M prompt=1639 completion=11 reasoning=0 ttft=14411ms total=16197ms finish=stop proposed=- executed=-
