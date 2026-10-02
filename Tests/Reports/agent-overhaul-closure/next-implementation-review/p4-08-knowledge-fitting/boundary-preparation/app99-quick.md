# Tool loop live eval — 2026-10-02 21:29:41 +0000

- Model: `appLLM` "Gemma 4 E4B" ctx=32768 role=`cloud` FALLBACK
- Mode: quick; pass bar 9/10; elapsed 147.9s
- Needle first: no
- Timing: per turn, first fixture result and completed reply; not first token or audio. One-time base-model warm-up excluded; Needle schema startup included. See JSONL.
- First verified fixture result: n=4, p50=8.026s, p95=18.163s
- Completed reply: n=11, p50=9.001s, p95=38.472s
- Whole case: n=10, p50=9.003s, p95=38.473s
- App peak RSS: 1825423360 bytes; excludes the Needle child.
- Classes: error=0 timeout=1 leak=0 refusal=2 wrong_tool=0 fabricated=0 missed_tool=3 ungrounded=1 filler=0 pass=3

| Case | Verdict | Seconds | Turns | Tools | Reply |
|---|---|---|---|---|---|
| C01 | PASS | 21.0 | 1 | get_agenda(date=2026-10-02) | You have Standup at 9:30, Budget review with Ana at 2:00 PM, and a call with Marcus about pricing at 4:30 PM today. |
| C04 | TIMEOUT | 38.5 | 1 | search_email(maxResults=5) | This takes a few steps on this Mac.  1) Fri 2 Oct 16:27 · Cyril <cyril@example.com> · Dinner tomorrow? — Are you free tomorrow evening? 2) Fri 2 Oct 15:27 · Ana Ruiz <ana@example.com> · Deck for Friday — Can you send the deck by Friday? 3) Fri 2 Oct 14:27 · Marcus Lee <marcus@productflo.example> · P |
| M03 | REFUSAL | 12.8 | 1 |  | I can check your last emails for you. Should I show you a summary of what I find? |
| M04 | MISSED_TOOL | 6.4 | 1 |  | I can draft that email for you. What should the subject line be? |
| M05 | UNGROUNDED | 22.5 | 2 | search_email(maxResults=3) | I need a little more information about what you want me to do with that. |
| K01 | REFUSAL | 4.6 | 1 |  | I can check the decisions from the last meeting for you. Should I look at the decisions recorded in this meeting? |
| R02 | MISSED_TOOL | 9.0 | 1 |  | I haven't checked that yet. |
| F03 | MISSED_TOOL | 5.4 | 1 |  | I can find the pricing document, but I need to know where it is saved first. |
| A02 | PASS | 21.5 | 1 | browser.navigate(url=https://www.youtube.com) browser.snapshot browser.click(expectedText=Cortech — newest upload (2 days ago)) | I see you want to watch the latest Cortech video. I clicked on the link for the newest upload, so that should be open now. |
| N04 | PASS | 4.0 | 1 |  | I can look at your calendar, email, Drive and Docs, reminders and routines, past meetings and notes, Mac apps and the screen, browser pages, installable skills, and connected apps. |

## Non-PASS detail

### C04 TIMEOUT
- evidence: 09-22 00:58Z; expected fix: P1-02, P1-06
- rounds: 1; last prompt: system=6738 user=232 maxTokens=1024
- last completion:
```
I can check your last emails and see what you have planned for tomorrow.

<tool_call>{"name":"search_email","arguments":{"maxResults":5},"rationale":"The user asked to summarize their last emails, so I will search for the five newest emails."}</tool_call>
```

### M03 REFUSAL
- evidence: 09-15 01:13Z; expected fix: P1-06, P1-09
- rounds: 1; last prompt: system=6442 user=279 maxTokens=1024
- last completion:
```
I can check your last emails for you. Should I show you a summary of what I find?
```

### M04 MISSED_TOOL
- evidence: write token cap; expected fix: P1-02/P1-04
- rounds: 1; last prompt: system=7446 user=91 maxTokens=1024
- last completion:
```
I can draft that email for you. What should the subject line be?
```

### M05 UNGROUNDED
- evidence: 09-22 five-denial loop; expected fix: P1-02
- rounds: 4; last prompt: system=6442 user=357 maxTokens=1024
- last completion:
```
I need a little more information about what you want me to do with that.
```

### K01 REFUSAL
- evidence: B D8; expected fix: P1-03
- rounds: 1; last prompt: system=6168 user=61 maxTokens=1024
- last completion:
```
I can check the decisions from the last meeting for you. Should I look at the decisions recorded in this meeting?
```

### R02 MISSED_TOOL
- evidence: 09-23 06:37Z leak; expected fix: P0-04, P1-04
- rounds: 2; last prompt: system=6444 user=340 maxTokens=1024
- last completion:
```
I can set a reminder for you. Should I set it every night at 10 PM to remind you to put the book out?
```

### F03 MISSED_TOOL
- evidence: B D9; expected fix: P1-08
- rounds: 1; last prompt: system=6907 user=174 maxTokens=1024
- last completion:
```
I can find the pricing document, but I need to know where it is saved first.
```

## Model passes

- C01: agent.typed/planner llama Gemma 4 E4B prompt=1287 completion=41 reasoning=0 ttft=12583ms total=15065ms finish=stop proposed=get_agenda executed=get_agenda · agent.typed/planner llama Gemma 4 E4B prompt=1386 completion=39 reasoning=0 ttft=596ms total=2674ms finish=stop proposed=- executed=-
- C04: agent.typed/planner llama Gemma 4 E4B prompt=1741 completion=62 reasoning=0 ttft=3500ms total=7897ms finish=stop proposed=search_email executed=search_email · agent.typed/planner llama Gemma 4 E4B prompt=0 completion=0 reasoning=0 ttft=12471ms total=30308ms finish=timeout proposed=- executed=-
- M03: agent.typed/planner llama Gemma 4 E4B prompt=1626 completion=20 reasoning=0 ttft=11105ms total=12691ms finish=stop proposed=- executed=-
- M04: agent.typed/planner llama Gemma 4 E4B prompt=1817 completion=15 reasoning=0 ttft=5485ms total=6332ms finish=stop proposed=- executed=-
- M05: agent.typed/planner llama Gemma 4 E4B prompt=1571 completion=25 reasoning=0 ttft=3560ms total=5319ms finish=stop proposed=- executed=- · agent.typed/planner llama Gemma 4 E4B prompt=1677 completion=79 reasoning=0 ttft=1989ms total=9888ms finish=stop proposed=search_email executed=search_email · agent.typed/planner llama Gemma 4 E4B prompt=1791 completion=42 reasoning=0 ttft=1479ms total=4801ms finish=stop proposed=- executed=- · agent.typed/planner llama Gemma 4 E4B prompt=1639 completion=16 reasoning=0 ttft=1033ms total=2208ms finish=stop proposed=- executed=-
- K01: agent.typed/planner llama Gemma 4 E4B prompt=1479 completion=23 reasoning=0 ttft=2857ms total=4568ms finish=stop proposed=- executed=-
- R02: agent.typed/planner llama Gemma 4 E4B prompt=1567 completion=22 reasoning=0 ttft=4258ms total=5617ms finish=stop proposed=- executed=- · agent.typed/planner llama Gemma 4 E4B prompt=1631 completion=28 reasoning=0 ttft=871ms total=3171ms finish=stop proposed=- executed=-
- F03: agent.typed/planner llama Gemma 4 E4B prompt=1719 completion=18 reasoning=0 ttft=4234ms total=5257ms finish=stop proposed=- executed=-
- A02: agent.typed/planner llama Gemma 4 E4B prompt=1424 completion=58 reasoning=0 ttft=2479ms total=7061ms finish=stop proposed=browser.navigate executed=browser.navigate · agent.typed/planner llama Gemma 4 E4B prompt=1466 completion=31 reasoning=0 ttft=576ms total=2884ms finish=stop proposed=browser.snapshot executed=browser.snapshot · agent.typed/planner llama Gemma 4 E4B prompt=1504 completion=96 reasoning=0 ttft=521ms total=8541ms finish=stop proposed=browser.click executed=browser.click · agent.typed/planner llama Gemma 4 E4B prompt=1503 completion=29 reasoning=0 ttft=788ms total=2878ms finish=stop proposed=- executed=-
- N04: agent.typed/planner llama Gemma 4 E4B prompt=1155 completion=39 reasoning=0 ttft=327ms total=3898ms finish=stop proposed=- executed=-
