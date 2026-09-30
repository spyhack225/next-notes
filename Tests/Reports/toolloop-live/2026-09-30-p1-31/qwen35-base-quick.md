# Tool loop live eval — 2026-09-30 21:45:50 +0000

- Model: `appLLM` "Qwen3.5-4B" ctx=32768 role=`installed:unsloth/Qwen3.5-4B-GGUF/Qwen3.5-4B-Q4_K_M.gguf`
- Mode: quick; pass bar 9/10; elapsed 365.9s
- Needle first: no
- Artifact: `unsloth/Qwen3.5-4B-GGUF/Qwen3.5-4B-Q4_K_M.gguf`; `/Users/sergekadjo/Library/Application Support/Next Notes/Models/unsloth--Qwen3.5-4B-Q4_K_M.gguf`; 2740937888 bytes
- Timing: per turn, first fixture result and completed reply; not first token or audio. One-time base-model warm-up excluded; Needle schema startup included. See JSONL.
- First verified fixture result: n=4, p50=20.200s, p95=28.661s
- Completed reply: n=11, p50=30.649s, p95=63.903s
- Whole case: n=10, p50=30.649s, p95=66.068s
- App peak RSS: 3254435840 bytes; excludes the Needle child.
- Classes: error=0 timeout=0 leak=0 refusal=0 wrong_tool=0 fabricated=2 missed_tool=4 ungrounded=2 filler=0 pass=2

| Case | Verdict | Seconds | Turns | Tools | Reply |
|---|---|---|---|---|---|
| C01 | FABRICATED | 63.9 | 1 |  | I ran out of time before finishing the rest. |
| C04 | FABRICATED | 30.6 | 1 |  | This takes a few steps on this Mac.  I ran out of time before finishing the rest. |
| M03 | PASS | 33.4 | 1 | search_email | The last email is from Ana about the deck due Friday, followed by Marcus's pricing sheet and a GitHub build success. I've summarized those three items for you. |
| M04 | MISSED_TOOL | 20.9 | 1 |  | I will draft that email for you right now. |
| M05 | UNGROUNDED | 66.1 | 2 | search_email | Got it. I've noted that you want me to check your emails again if you need more details later. |
| K01 | PASS | 40.3 | 1 | meeting.recent_context | We decided to move the launch to October 14 and keep the price at $12 a month. |
| R02 | MISSED_TOOL | 18.9 | 1 |  | I'll set that reminder for you tonight at 10. |
| F03 | MISSED_TOOL | 50.8 | 1 | filesystem.search(folder=true,query=pricing) | I found the pricing document, so I will send it to Marcus now. |
| A02 | MISSED_TOOL | 19.1 | 1 |  | I'll open YouTube and play that video for you. |
| N04 | UNGROUNDED | 20.7 | 1 |  | I can help you check your calendar, find files on your Mac, and open apps. What would you like to do first? |

## Non-PASS detail

### C01 FABRICATED
- evidence: B §1 core tool; expected fix: baseline should pass
- rounds: 0; last prompt: system=-1 user=-1 maxTokens=-1

### C04 FABRICATED
- evidence: 09-22 00:58Z; expected fix: P1-02, P1-06
- rounds: 0; last prompt: system=-1 user=-1 maxTokens=-1

### M04 MISSED_TOOL
- evidence: write token cap; expected fix: P1-02/P1-04
- rounds: 1; last prompt: system=7449 user=91 maxTokens=1024
- last completion:
```
I will draft that email for you right now.
```

### M05 UNGROUNDED
- evidence: 09-22 five-denial loop; expected fix: P1-02
- rounds: 2; last prompt: system=6445 user=436 maxTokens=1024
- last completion:
```
Got it. I've noted that you want me to check your emails again if you need more details later.
```

### R02 MISSED_TOOL
- evidence: 09-23 06:37Z leak; expected fix: P0-04, P1-04
- rounds: 1; last prompt: system=6447 user=70 maxTokens=1024
- last completion:
```
I'll set that reminder for you tonight at 10.
```

### F03 MISSED_TOOL
- evidence: B D9; expected fix: P1-08
- rounds: 2; last prompt: system=6910 user=306 maxTokens=1024
- last completion:
```
I found the pricing document, so I will send it to Marcus now.
```

### A02 MISSED_TOOL
- evidence: T10 "Opened youtube.com."; expected fix: P1-08
- rounds: 1; last prompt: system=5825 user=68 maxTokens=1024
- last completion:
```
I'll open YouTube and play that video for you.
```

### N04 UNGROUNDED
- evidence: Q13; expected fix: P1-03
- rounds: 1; last prompt: system=4805 user=38 maxTokens=1024
- last completion:
```
I can help you check your calendar, find files on your Mac, and open apps. What would you like to do first?
```

## Model passes

- C01: agent.typed/planner llama Qwen3.5-4B prompt=0 completion=0 reasoning=0 ttft=15901ms total=31439ms finish=timeout proposed=- executed=-
- C04: agent.typed/planner llama Qwen3.5-4B prompt=0 completion=0 reasoning=0 ttft=20917ms total=30520ms finish=timeout proposed=- executed=-
- M03: agent.typed/planner llama Qwen3.5-4B prompt=1600 completion=21 reasoning=0 ttft=13745ms total=17006ms finish=stop proposed=- executed=-
- M04: agent.typed/planner llama Qwen3.5-4B prompt=1795 completion=10 reasoning=0 ttft=18852ms total=20837ms finish=stop proposed=- executed=-
- M05: agent.typed/planner llama Qwen3.5-4B prompt=1557 completion=17 reasoning=0 ttft=16518ms total=19693ms finish=stop proposed=- executed=- · agent.typed/planner llama Qwen3.5-4B prompt=1639 completion=22 reasoning=0 ttft=15482ms total=19004ms finish=stop proposed=- executed=-
- K01: agent.typed/planner llama Qwen3.5-4B prompt=1471 completion=35 reasoning=0 ttft=13080ms total=20855ms finish=stop proposed=meeting.recent_context executed=meeting.recent_context · agent.typed/planner llama Qwen3.5-4B prompt=1590 completion=22 reasoning=0 ttft=15079ms total=19260ms finish=stop proposed=- executed=-
- R02: agent.typed/planner llama Qwen3.5-4B prompt=1567 completion=13 reasoning=0 ttft=17441ms total=18747ms finish=stop proposed=- executed=-
- F03: agent.typed/planner llama Qwen3.5-4B prompt=1672 completion=45 reasoning=0 ttft=16587ms total=28597ms finish=stop proposed=filesystem.search executed=filesystem.search · agent.typed/planner llama Qwen3.5-4B prompt=1732 completion=15 reasoning=0 ttft=18537ms total=21505ms finish=stop proposed=- executed=-
- A02: agent.typed/planner llama Qwen3.5-4B prompt=1386 completion=11 reasoning=0 ttft=15061ms total=17869ms finish=stop proposed=- executed=-
- N04: agent.typed/planner llama Qwen3.5-4B prompt=1149 completion=26 reasoning=0 ttft=12525ms total=20509ms finish=stop proposed=- executed=-
