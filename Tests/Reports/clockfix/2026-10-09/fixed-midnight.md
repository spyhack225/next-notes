# Tool loop live eval — 2026-10-09 06:40:43 +0000

- Model: `localServer` "Scripted clock diagnostic" ctx=16384 role=`scripted-clock`
- Mode: only; pass bar 2/2; elapsed 0.2s
- Needle first: no
- Model pin: `scripted-clock`; fixture clock: `2026-10-05T23:30:00-04:00`; time zone: `America/New_York`.
- JSONL replies preserves every complete rendered turn reply; rawRounds preserves every planner round and its full completion. systemCharacters/userCharacters are prompt character counts, not prompt text.
- Timing: per turn, first fixture result and completed reply; not first token or audio. One-time base-model warm-up excluded; Needle schema startup included. See JSONL.
- First verified fixture result: n=2, p50=0.010s, p95=0.095s
- Completed reply: n=2, p50=0.017s, p95=0.101s
- Whole case: n=2, p50=0.017s, p95=0.101s
- App peak RSS: 116310016 bytes; excludes the Needle child.
- Classes: error=0 timeout=0 leak=0 refusal=0 wrong_tool=0 fabricated=0 missed_tool=0 ungrounded=0 filler=0 pass=2

| Case | Verdict | Seconds | Turns | Tools | Reply |
|---|---|---|---|---|---|
| C01 | PASS | 0.1 | 1 | get_agenda(date=2026-10-05) | Today you have a standup, a budget review with Ana and a call with Marcus about pricing. |
| C04 | PASS | 0.0 | 1 | search_email get_agenda(date=2026-10-06) | This takes a few steps on this Mac.  Marcus sent the pricing sheet, Ana requested the deck and Stripe sent an invoice. Tomorrow you have a dentist appointment, a design sync and dinner with Cyril. |

## Non-PASS detail

## Model passes

- C01: agent.typed/planner openaiCompatible Scripted clock diagnostic prompt=0 completion=0 reasoning=0 ttft=1ms total=2ms finish=stop proposed=get_agenda executed=get_agenda · agent.typed/planner openaiCompatible Scripted clock diagnostic prompt=0 completion=0 reasoning=0 ttft=1ms total=1ms finish=stop proposed=- executed=-
- C04: agent.typed/planner openaiCompatible Scripted clock diagnostic prompt=0 completion=0 reasoning=0 ttft=1ms total=1ms finish=stop proposed=search_email+get_agenda executed=search_email+get_agenda · agent.typed/planner openaiCompatible Scripted clock diagnostic prompt=0 completion=0 reasoning=0 ttft=1ms total=1ms finish=stop proposed=- executed=-
