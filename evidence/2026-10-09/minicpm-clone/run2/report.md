# Tool loop live eval — 2026-10-09 06:00:46 +0000

- Model: `appLLM` "MiniCPM5-2B" ctx=32768 role=`installed:openbmb/MiniCPM5-2B-GGUF/MiniCPM5-2B-Q4_K_M.gguf`
- Mode: quick; pass bar 9/10; elapsed 112.7s
- Needle first: no
- Model pin: `openbmb/MiniCPM5-2B-GGUF/MiniCPM5-2B-Q4_K_M.gguf`; fixture clock: `2026-10-05T09:00:00-04:00`; time zone: `America/New_York`.
- JSONL replies preserves every complete rendered turn reply; rawRounds preserves every planner round and its full completion. systemCharacters/userCharacters are prompt character counts, not prompt text.
- Artifact: `openbmb/MiniCPM5-2B-GGUF/MiniCPM5-2B-Q4_K_M.gguf`; `/Users/sergekadjo/Library/Application Support/Next Notes/Models/MiniCPM5-2B-Q4_K_M.gguf`; 1561318368 bytes
- Timing: per turn, first fixture result and completed reply; not first token or audio. One-time base-model warm-up excluded; Needle schema startup included. See JSONL.
- First verified fixture result: n=9, p50=5.390s, p95=9.774s
- Completed reply: n=12, p50=7.958s, p95=26.163s
- Whole case: n=10, p50=9.094s, p95=26.163s
- App peak RSS: 2077032448 bytes; excludes the Needle child.
- Classes: error=0 timeout=0 leak=0 refusal=0 wrong_tool=2 fabricated=0 missed_tool=0 ungrounded=1 filler=0 pass=7

| Case | Verdict | Seconds | Turns | Tools | Reply |
|---|---|---|---|---|---|
| C01 | WRONG_TOOL | 9.1 | 1 | get_agenda(date=2026-10-09) | Nothing is booked on 2026-10-09. That's the only date I have access to right now, so if you're thinking of something else, let me know and I can help with that too. |
| C04 | WRONG_TOOL | 26.2 | 1 | search_email get_agenda(date=2026-10-10) | This takes a few steps on this Mac.  Here's a summary of your recent emails:  - Mon 5 Oct 08:00 · Cyril <cyril@example.com> — Dinner tomorrow? Are you free tomorrow evening? - Mon 5 Oct 07:00 · Ana Ruiz <ana@example.com> — Deck for Friday. Can you send the deck by Friday? - Mon 5 Oct 06:00 · Marcus Lee <marcus@productflo.example> — Pricing sheet v3. - Mon 5 Oct 05:00 · GitHub <no-reply@github.example> — [next-notes] CI passed on main. All 214 checks passed. - Fri 2 Oct 09:00 · Stripe <noreply@stripe.example> — Your invoice for September is ready. - Sat 26 Sep 09:00 · Marcus Lee <marcus@productflo.example> — Re: contract renewal. The renewal terms are attached.  For tomorrow, there are no events booked. |
| M03 | PASS | 4.4 | 1 | search_email(maxResults=1) | I found one email in your Gmail. It's a question from Cyril asking whether you're free for dinner tomorrow evening.  Would you like me to check for more emails, or help with anything else? |
| M04 | PASS | 13.0 | 1 | draft_email(body=I'll send the deck on Friday.,subject=Sending the deck on Friday,to=ana@example.com) | I'll draft the email for you. |
| M05 | PASS | 14.1 | 2 | search_email | I'll help you with each item from your last emails.  1. **Cyril** asked about dinner tomorrow — want me to help with that? 2. **Ana Ruiz** needs the deck sent by Friday — can I assist with sending it? 3. **Marcus Lee** shared an updated pricing sheet — should I forward or share that? 4. GitHub CI note passed on main — already handled? 5. **Stripe** notified you about a September invoice — do I need to follow up? 6. **Marcus Lee** discussed contract renewal terms — any next steps needed there? |
| K01 | PASS | 10.4 | 1 | meeting.decisions | We decided to move the launch to October 14 and keep the price at $12 a month. You would send the revised budget to Ana by Thursday, Marcus would update the pricing page, and Sarah mentioned that the budget needs a 10% buffer for ads. |
| R02 | PASS | 18.7 | 2 | schedule.create(id=REMINDER_ID,repeat=daily,text=Remind to put the book out every night at 10,time=10:00 PM,title=Put book out) | Reminder set: put the book out every night at 10. |
| F03 | PASS | 6.0 | 1 | filesystem.search(query=pricing) | I can see two pricing documents on your Mac: "Pricing 2026.pdf" in Documents and "Pricing sheet v3" on Google Drive. Would you like me to email one of them to Marcus, or do you have a preference? |
| A02 | UNGROUNDED | 7.6 | 1 | browser.navigate(url=https://www.youtube.com/results?search_query=cortech) browser.snapshot | I found the latest Cortech uploads on YouTube. You can watch them directly from the search results page. Want me to open a specific video or help with anything else? |
| N04 | PASS | 3.0 | 1 |  | You can reach your calendar, your email, your Drive and Docs, reminders and routines, past meetings and notes, what you tell me to remember, Mac apps and the screen, browser pages, installable skills, and the apps you have connected. If something needs doing in any of those areas, I can help with it directly. |

## Non-PASS detail

### C01 WRONG_TOOL
- evidence: B §1 core tool; expected fix: baseline should pass
- rounds: 2; last prompt: system=5114 user=218 maxTokens=1024
- last completion:
```
Nothing is booked on 2026-10-09. That's the only date I have access to right now, so if you're thinking of something else, let me know and I can help with that too.
```

### C04 WRONG_TOOL
- evidence: 09-22 00:58Z; expected fix: P1-02, P1-06
- rounds: 2; last prompt: system=6901 user=1086 maxTokens=1024
- last completion:
```
Here's a summary of your recent emails:

- Mon 5 Oct 08:00 · Cyril <cyril@example.com> — Dinner tomorrow? Are you free tomorrow evening?
- Mon 5 Oct 07:00 · Ana Ruiz <ana@example.com> — Deck for Friday. Can you send the deck by Friday?
- Mon 5 Oct 06:00 · Marcus Lee <marcus@productflo.example> — Pricing sheet v3.
- Mon 5 Oct 05:00 · GitHub <no-reply@github.example> — [next-notes] CI passed on main
```

### A02 UNGROUNDED
- evidence: T10 "Opened youtube.com."; expected fix: P1-08
- rounds: 4; last prompt: system=5822 user=933 maxTokens=1024
- last completion:
```
I found the latest Cortech uploads on YouTube. You can watch them directly from the search results page. Want me to open a specific video or help with anything else?
```

## Model passes

- C01: agent.typed/planner llama MiniCPM5-2B prompt=1229 completion=28 reasoning=0 ttft=5148ms total=6040ms finish=stop proposed=get_agenda executed=get_agenda · agent.typed/planner llama MiniCPM5-2B prompt=1273 completion=44 reasoning=0 ttft=371ms total=2889ms finish=stop proposed=- executed=-
- C04: agent.typed/planner llama MiniCPM5-2B prompt=1712 completion=46 reasoning=0 ttft=6464ms total=8995ms finish=stop proposed=search_email+get_agenda executed=search_email+get_agenda · agent.typed/planner llama MiniCPM5-2B prompt=1960 completion=202 reasoning=0 ttft=7527ms total=17118ms finish=stop proposed=- executed=-
- M03: agent.typed/planner llama MiniCPM5-2B prompt=1622 completion=7 reasoning=0 ttft=2182ms total=2380ms finish=stop proposed=search_email executed=search_email · agent.typed/planner llama MiniCPM5-2B prompt=1681 completion=42 reasoning=0 ttft=318ms total=1984ms finish=stop proposed=- executed=-
- M04: agent.typed/planner llama MiniCPM5-2B prompt=1809 completion=9 reasoning=0 ttft=2725ms total=2961ms finish=stop proposed=- executed=- · agent.typed/planner llama MiniCPM5-2B prompt=1887 completion=94 reasoning=0 ttft=400ms total=6745ms finish=stop proposed=draft_email executed=draft_email · agent.typed/planner llama MiniCPM5-2B prompt=1913 completion=60 reasoning=0 ttft=199ms total=1881ms finish=stop proposed=- executed=- · agent.typed/planner llama MiniCPM5-2B prompt=2000 completion=8 reasoning=0 ttft=818ms total=1250ms finish=stop proposed=- executed=-
- M05: agent.typed/planner llama MiniCPM5-2B prompt=1564 completion=22 reasoning=0 ttft=1845ms total=2500ms finish=stop proposed=search_email executed=search_email · agent.typed/planner llama MiniCPM5-2B prompt=1794 completion=99 reasoning=0 ttft=913ms total=5385ms finish=stop proposed=- executed=- · agent.typed/planner llama MiniCPM5-2B prompt=1766 completion=120 reasoning=0 ttft=1060ms total=6114ms finish=stop proposed=- executed=-
- K01: agent.typed/planner llama MiniCPM5-2B prompt=1439 completion=49 reasoning=0 ttft=1501ms total=5348ms finish=stop proposed=- executed=meeting.decisions
- R02: agent.typed/planner llama MiniCPM5-2B prompt=1592 completion=118 reasoning=0 ttft=3259ms total=8375ms finish=stop proposed=schedule.create executed=- · agent.typed/planner llama MiniCPM5-2B prompt=1698 completion=45 reasoning=0 ttft=495ms total=2044ms finish=stop proposed=- executed=- · agent.typed/planner llama MiniCPM5-2B prompt=1775 completion=76 reasoning=0 ttft=1050ms total=4042ms finish=stop proposed=schedule.create executed=- · agent.typed/planner llama MiniCPM5-2B prompt=1870 completion=64 reasoning=0 ttft=567ms total=2946ms finish=stop proposed=schedule.create [modify] executed=schedule.create · agent.typed/planner llama MiniCPM5-2B prompt=1919 completion=14 reasoning=0 ttft=462ms total=1070ms finish=stop proposed=- executed=-
- F03: agent.typed/planner llama MiniCPM5-2B prompt=1712 completion=42 reasoning=0 ttft=2233ms total=3333ms finish=stop proposed=- executed=filesystem.search · agent.typed/planner llama MiniCPM5-2B prompt=1771 completion=53 reasoning=0 ttft=316ms total=2543ms finish=stop proposed=- executed=-
- A02: agent.typed/planner llama MiniCPM5-2B prompt=1396 completion=47 reasoning=0 ttft=1328ms total=2782ms finish=stop proposed=- executed=- · agent.typed/planner llama MiniCPM5-2B prompt=1515 completion=40 reasoning=0 ttft=535ms total=2015ms finish=stop proposed=browser.navigate executed=browser.navigate · agent.typed/planner llama MiniCPM5-2B prompt=1537 completion=20 reasoning=0 ttft=311ms total=1096ms finish=stop proposed=- executed=browser.snapshot · agent.typed/planner llama MiniCPM5-2B prompt=1574 completion=35 reasoning=0 ttft=371ms total=1583ms finish=stop proposed=- executed=-
- N04: agent.typed/planner llama MiniCPM5-2B prompt=1124 completion=68 reasoning=0 ttft=157ms total=2926ms finish=stop proposed=- executed=-
