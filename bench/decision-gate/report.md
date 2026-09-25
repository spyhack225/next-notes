# Decision-gate benchmark: laya vs Needle (Cactus)

_Generated 2026-09-23 on Apple M3 · 8 cores · 16 GB. 112 fixtures -- the app's own `FunctionCallSelfTest` cases plus the expanded families in `fixtures.json` -- against the 8-tool `FunctionCallCatalogue`._

> **Scope.** The six "System One" candidates are typed-decision models, not function-calling models. None can emit `to: "sarah@acme.com"`. This harness scores only the gate they *can* do -- is-it-a-request and which-tool -- and keeps Needle beside them as the function-calling reference. Argument extraction is Needle's job and is not compared here.

## Measured here

| backend | params | weights | load | p50 latency | mean | peak RSS | exact-tool | family | is-request | silence on none | fired on request |
|---|---|---|---|---|---|---|---|---|---|---|---|
| laya-multilingual | 322M | 644 MB | 29.1s | 89.3 ms | 98.6 ms | 2518.5 MB | 0.696 | 0.714 | 0.509 | 38/50 | 47/62 |
| laya-typed-decisions | 421M | 843 MB | 28.9s | 462.3 ms | 472.4 ms | 2518.5 MB | 0.741 | 0.786 | 0.527 | 32/50 | 58/62 |
| needle | 121M | 36 MB | - | 994.7 ms | 1163.0 ms | 100.7 MB | 0.732 | 0.768 | 0.786 | 35/50 | 53/62 |
| needle-serve | 121M | 36 MB | 0.897s | 277.0 ms | 464.0 ms | 101.2 MB | 0.732 | 0.768 | 0.786 | 35/50 | 53/62 |

Per-decision latency is wall clock around one decision. **`needle` is a child process per proposal** -- launch, model load and prefill on every row, which is what the app did until 2026-09-23. **`needle-serve` is one resident `--serve` child**, reset before every turn exactly as `NeedleServer` does; its start-up and first-turn prefill are one-time and shown in the start column, not folded into the number. laya's latency excludes its one-time load, shown separately. The rows are not the same measurement -- see README. laya's peak RSS is the whole Python/torch runtime; when several laya checkpoints run in one process it is a shared high-water mark, so read the laya rows as one number. `needle-serve`'s peak RSS comes from the engine's own turn report.

### Per-fixture decisions

| fixture | gold | laya-multilingual | laya-typed-decisions | needle | needle-serve |
|---|---|---|---|---|---|
| address said out loud | `send_email` | ✓ send_email (noul 0.327) | ✓ send_email (noul 0.365) | ✓ send_email (conf 1.0) | ✓ send_email (conf 1.0) |
| no address anywhere | `send_email` | ✗ none (noul 0.84) | ✓ send_email (noul 0.44) | ✓ send_email (conf 1.0) | ✓ send_email (conf 1.0) |
| address said a minute earlier | `send_email` | ✗ none (noul 0.897) | ✓ send_email (noul 0.307) | ✓ send_email (conf 0.967) | ✓ send_email (conf 0.967) |
| ordinary conversation | `none` | ✓ none (noul 0.134) | ✓ none (noul 0.13) | ✓ none (conf 0.494) | ✓ none (conf 0.494) |
| browser command (verbatim audit line) | `none` | ✓ none (noul 0.409) | ✓ none (noul 0.599) | ✓ none (conf 0.987) | ✓ none (conf 0.987) |
| browser command, as said | `none` | ✓ none (noul 0.799) | ✗ send_email (noul 0.63) | ✓ none (conf 1.0) | ✓ none (conf 1.0) |
| a folder on this Mac | `none` | ✗ append_doc (noul 0.892) | ✗ memory.remember (noul 0.304) | ✓ none (conf 0.984) | ✓ none (conf 0.984) |
| media control | `none` | ✓ none (noul 0.407) | ✗ create_event (noul 0.463) | ✗ create_event (conf 0.415) | ✗ create_event (conf 0.415) |
| a question about the diary | `none` | ✗ create_event (noul 0.576) | ✓ none (noul 0.168) | ✓ none (conf 0.432) | ✓ none (conf 0.432) |
| a search somebody asked for out loud | `none` | ✓ none (noul 0.736) | ✓ none (noul 0.457) | ✓ none (conf 1.0) | ✓ none (conf 1.0) |
| append a line to a doc | `append_doc` | ✓ append_doc (noul 0.438) | ✓ append_doc (noul 0.454) | ✓ append_doc (conf 1.0) | ✓ append_doc (conf 1.0) |
| open the doc and add to it | `append_doc` | ✓ append_doc (noul 0.105) | ✓ append_doc (noul 0.414) | ✓ append_doc (conf 0.922) | ✓ append_doc (conf 0.922) |
| diary entry for Thursday | `create_event` | ✗ none (noul 0.178) | ✗ append_doc (noul 0.351) | ✓ create_event (conf 1.0) | ✓ create_event (conf 1.0) |
| put the review in the diary | `create_event` | ✗ memory.remember (noul 0.228) | ✗ none (noul 0.357) | ✗ none (conf 1.0) | ✗ none (conf 1.0) |
| email the team the release notes | `send_email` | ✗ none (noul 0.861) | ✓ send_email (noul 0.422) | ✓ send_email (conf 0.958) | ✓ send_email (conf 0.958) |
| send the invoice to billing | `send_email` | ✗ none (noul 0.971) | ✓ send_email (noul 0.496) | ✓ send_email (conf 1.0) | ✓ send_email (conf 1.0) |
| shoot an email to Dana | `send_email` | ✓ send_email (noul 0.968) | ✓ send_email (noul 0.56) | ✓ send_email (conf 1.0) | ✓ send_email (conf 1.0) |
| send the notes to James | `send_email` | ✓ send_email (noul 0.718) | ✓ send_email (noul 0.517) | ✓ send_email (conf 0.981) | ✓ send_email (conf 0.981) |
| draft email about the renewal | `draft_email` | ✓ draft_email (noul 0.87) | ✓ draft_email (noul 0.584) | ✓ draft_email (conf 0.428) | ✓ draft_email (conf 0.428) |
| write a draft asking for a quote | `draft_email` | ✓ draft_email (noul 0.835) | ✓ draft_email (noul 0.575) | ✓ draft_email (conf 0.86) | ✓ draft_email (conf 0.86) |
| draft but do not send | `draft_email` | ✓ draft_email (noul 0.763) | ✗ send_email (noul 0.49) | ✗ none (conf 1.0) | ✗ none (conf 1.0) |
| compose and leave it in drafts | `draft_email` | ✗ send_email (noul 0.937) | ✓ draft_email (noul 0.457) | ✗ send_email (conf 0.998) | ✗ send_email (conf 0.998) |
| write up a rough draft of the follow-up | `draft_email` | ✓ draft_email (noul 0.134) | ✓ draft_email (noul 0.42) | ✓ draft_email (conf 1.0) | ✓ draft_email (conf 1.0) |
| reply to Sarah's email | `reply_email` | ✓ reply_email (noul 0.196) | ✓ reply_email (noul 0.476) | ✓ reply_email (conf 0.924) | ✓ reply_email (conf 0.924) |
| reply to the vendor thread | `reply_email` | ✓ reply_email (noul 0.101) | ✓ reply_email (noul 0.195) | ✓ reply_email (conf 1.0) | ✓ reply_email (conf 1.0) |
| answer Marcus's email | `reply_email` | ✓ reply_email (noul 0.037) | ✓ reply_email (noul 0.482) | ✓ reply_email (conf 0.993) | ✓ reply_email (conf 0.993) |
| get back to Dana's email | `reply_email` | ✗ schedule.create (noul 0.502) | ✓ reply_email (noul 0.546) | ✓ reply_email (conf 1.0) | ✓ reply_email (conf 1.0) |
| send a reply on the pricing thread | `reply_email` | ✓ reply_email (noul 0.671) | ✓ reply_email (noul 0.479) | ✓ reply_email (conf 0.984) | ✓ reply_email (conf 0.984) |
| dentist on Friday morning | `create_event` | ✓ create_event (noul 0.207) | ✗ schedule.create (noul 0.544) | ✗ none (conf 0.0) | ✗ none (conf 0.0) |
| team sync tomorrow at three | `create_event` | ✗ none (noul 0.34) | ✓ create_event (noul 0.551) | ✗ schedule.create (conf 0.564) | ✗ schedule.create (conf 0.564) |
| lunch next Tuesday | `create_event` | ✗ none (noul 0.456) | ✗ schedule.create (noul 0.522) | ✗ schedule.create (conf 0.763) | ✗ schedule.create (conf 0.763) |
| design review with ISO timestamps | `create_event` | ✓ create_event (noul 0.649) | ✓ create_event (noul 0.438) | ✓ create_event (conf 0.989) | ✓ create_event (conf 0.989) |
| standup next Monday | `create_event` | ✓ create_event (noul 0.089) | ✗ schedule.create (noul 0.553) | ✓ create_event (conf 0.254) | ✓ create_event (conf 0.254) |
| flight on the 14th | `create_event` | ✗ schedule.create (noul 0.101) | ✗ none (noul 0.448) | ✗ none (conf 0.0) | ✗ none (conf 0.0) |
| schedule a chat with Marcus | `schedule.create` | ✓ schedule.create (noul 0.005) | ✓ schedule.create (noul 0.515) | ✓ schedule.create (conf 0.953) | ✓ schedule.create (conf 0.953) |
| schedule the boiler service | `schedule.create` | ✓ schedule.create (noul 0.338) | ✓ schedule.create (noul 0.518) | ✓ schedule.create (conf 0.957) | ✓ schedule.create (conf 0.957) |
| schedule a dentist checkup | `schedule.create` | ✓ schedule.create (noul 0.712) | ✓ schedule.create (noul 0.466) | ✓ schedule.create (conf 0.884) | ✓ schedule.create (conf 0.884) |
| workshop in the schedule | `schedule.create` | ✓ schedule.create (noul 0.884) | ✓ schedule.create (noul 0.547) | ✓ schedule.create (conf 0.96) | ✓ schedule.create (conf 0.96) |
| schedule an appointment with the bank | `schedule.create` | ✓ schedule.create (noul 0.332) | ✓ schedule.create (noul 0.519) | ✓ schedule.create (conf 0.959) | ✓ schedule.create (conf 0.959) |
| start a new doc for Q4 planning | `create_doc` | ✓ create_doc (noul 0.879) | ✓ create_doc (noul 0.448) | ✓ create_doc (conf 0.935) | ✓ create_doc (conf 0.935) |
| make a document for the offsite | `create_doc` | ✓ create_doc (noul 0.637) | ✓ create_doc (noul 0.447) | ✓ create_doc (conf 0.75) | ✓ create_doc (conf 0.75) |
| create a launch retro doc | `create_doc` | ✓ create_doc (noul 0.46) | ✓ create_doc (noul 0.419) | ✓ create_doc (conf 0.976) | ✓ create_doc (conf 0.976) |
| new doc for the vendor list | `create_doc` | ✓ create_doc (noul 0.76) | ✓ create_doc (noul 0.41) | ✓ create_doc (conf 0.917) | ✓ create_doc (conf 0.917) |
| write up the meeting notes doc | `create_doc` | ✓ create_doc (noul 0.685) | ✓ create_doc (noul 0.501) | ✓ create_doc (conf 0.849) | ✓ create_doc (conf 0.849) |
| add a line about the delay | `append_doc` | ✓ append_doc (noul 0.04) | ✓ append_doc (noul 0.468) | ✗ create_doc (conf 0.869) | ✗ create_doc (conf 0.869) |
| append the venue decision | `append_doc` | ✓ append_doc (noul 0.017) | ✓ append_doc (noul 0.436) | ✓ append_doc (conf 1.0) | ✓ append_doc (conf 1.0) |
| add the budget figure to the plan | `append_doc` | ✓ append_doc (noul 0.027) | ✓ append_doc (noul 0.413) | ✓ append_doc (conf 1.0) | ✓ append_doc (conf 1.0) |
| put a paragraph into the proposal | `append_doc` | ✓ append_doc (noul 0.015) | ✓ append_doc (noul 0.489) | ✓ append_doc (conf 0.623) | ✓ append_doc (conf 0.623) |
| remember morning meetings | `memory.remember` | ✓ memory.remember (noul 0.303) | ✓ memory.remember (noul 0.188) | ✓ memory.remember (conf 1.0) | ✓ memory.remember (conf 1.0) |
| remember the deposit deadline | `memory.remember` | ✓ memory.remember (noul 0.012) | ✓ memory.remember (noul 0.319) | ✓ memory.remember (conf 1.0) | ✓ memory.remember (conf 1.0) |
| make a note about procurement | `memory.remember` | ✗ create_doc (noul 0.15) | ✓ memory.remember (noul 0.283) | ✗ create_doc (conf 0.557) | ✗ create_doc (conf 0.557) |
| keep in mind the pronunciation | `memory.remember` | ✗ none (noul 0.1) | ✓ memory.remember (noul 0.165) | ✗ none (conf 0.526) | ✗ none (conf 0.526) |
| don't forget the code freeze | `memory.remember` | ✗ none (noul 0.83) | ✗ none (noul 0.367) | ✗ create_event (conf 0.987) | ✗ create_event (conf 0.987) |
| time said earlier, pronoun now | `create_event` | ✗ create_doc (noul 0.726) | ✗ none (noul 0.354) | ✗ none (conf 0.994) | ✗ none (conf 0.994) |
| address said earlier, send it to her | `send_email` | ✗ none (noul 0.991) | ✓ send_email (noul 0.53) | ✓ send_email (conf 0.96) | ✓ send_email (conf 0.96) |
| doc name said earlier, add to it | `append_doc` | ✓ append_doc (noul 0.862) | ✓ append_doc (noul 0.385) | ✓ append_doc (conf 0.371) | ✓ append_doc (conf 0.371) |
| event topic said earlier, no time anywhere | `create_event` | ✓ create_event (noul 0.666) | ✓ create_event (noul 0.54) | ✗ none (conf 0.318) | ✗ none (conf 0.318) |
| recipient said earlier, no address anywhere | `send_email` | ✗ none (noul 0.937) | ✓ send_email (noul 0.499) | ✓ send_email (conf 0.204) | ✓ send_email (conf 0.204) |
| no time anywhere in the diary request | `create_event` | ✗ append_doc (noul 0.662) | ✗ append_doc (noul 0.44) | ✗ none (conf 0.398) | ✗ none (conf 0.398) |
| a value in the window is not a request | `none` | ✗ memory.remember (noul 0.006) | ✓ none (noul 0.107) | ✓ none (conf 1.0) | ✓ none (conf 1.0) |
| grounded address, refusal now | `none` | ✓ none (noul 0.952) | ✗ send_email (noul 0.34) | ✓ none (conf 0.25) | ✓ none (conf 0.25) |
| don't send that after all | `none` | ✓ none (noul 0.93) | ✗ send_email (noul 0.492) | ✓ none (conf 0.367) | ✓ none (conf 0.367) |
| not to him | `none` | ✓ none (noul 0.039) | ✓ none (noul 0.18) | ✗ reply_email (conf 0.436) | ✗ reply_email (conf 0.436) |
| forget the email to the vendor | `none` | ✗ send_email (noul 0.715) | ✓ none (noul 0.278) | ✗ reply_email (conf 1.0) | ✗ reply_email (conf 1.0) |
| hold off on the invite | `none` | ✓ none (noul 0.528) | ✓ none (noul 0.266) | ✓ none (conf 0.406) | ✓ none (conf 0.406) |
| never mind the doc | `none` | ✗ create_doc (noul 0.487) | ✓ none (noul 0.192) | ✓ none (conf 0.916) | ✓ none (conf 0.916) |
| don't remember that | `none` | ✗ memory.remember (noul 0.047) | ✗ memory.remember (noul 0.115) | ✓ none (conf 1.0) | ✓ none (conf 1.0) |
| don't create the standup | `none` | ✗ create_doc (noul 0.757) | ✗ schedule.create (noul 0.257) | ✓ none (conf 0.579) | ✓ none (conf 0.579) |
| open Safari to the pricing page | `none` | ✓ none (noul 0.23) | ✓ none (noul 0.589) | ✓ none (conf 0.949) | ✓ none (conf 0.949) |
| click the Send button | `none` | ✓ none (noul 0.88) | ✗ send_email (noul 0.644) | ✓ none (conf 0.864) | ✓ none (conf 0.864) |
| type into a web form | `none` | ✗ memory.remember (noul 0.846) | ✓ none (noul 0.641) | ✗ send_email (conf 0.332) | ✗ send_email (conf 0.332) |
| scroll the results page | `none` | ✓ none (noul 0.667) | ✓ none (noul 0.416) | ✓ none (conf 0.98) | ✓ none (conf 0.98) |
| download a PDF from a link | `none` | ✗ append_doc (noul 0.271) | ✓ none (noul 0.467) | ✓ none (conf 1.0) | ✓ none (conf 1.0) |
| take a screenshot | `none` | ✓ none (noul 0.824) | ✓ none (noul 0.554) | ✓ none (conf 0.582) | ✓ none (conf 0.582) |
| launch an app | `none` | ✓ none (noul 0.225) | ✗ send_email (noul 0.595) | ✗ create_doc (conf 0.923) | ✗ create_doc (conf 0.923) |
| open the Downloads folder | `none` | ✓ none (noul 0.459) | ✓ none (noul 0.513) | ✓ none (conf 1.0) | ✓ none (conf 1.0) |
| show the invoices folder | `none` | ✗ append_doc (noul 0.749) | ✓ none (noul 0.318) | ✓ none (conf 1.0) | ✓ none (conf 1.0) |
| reveal the export in Finder | `none` | ✓ none (noul 0.176) | ✓ none (noul 0.308) | ✓ none (conf 1.0) | ✓ none (conf 1.0) |
| switch to the exports folder | `none` | ✓ none (noul 0.343) | ✓ none (noul 0.357) | ✓ none (conf 0.883) | ✓ none (conf 0.883) |
| move the invoices into the archive | `none` | ✓ none (noul 0.195) | ✗ append_doc (noul 0.366) | ✓ none (conf 1.0) | ✓ none (conf 1.0) |
| play the focus playlist | `none` | ✓ none (noul 0.434) | ✓ none (noul 0.354) | ✓ none (conf 0.596) | ✓ none (conf 0.596) |
| pause the music | `none` | ✓ none (noul 0.062) | ✓ none (noul 0.398) | ✓ none (conf 0.481) | ✓ none (conf 0.481) |
| mute the music | `none` | ✓ none (noul 0.691) | ✗ send_email (noul 0.239) | ✓ none (conf 1.0) | ✓ none (conf 1.0) |
| skip this song | `none` | ✓ none (noul 0.779) | ✓ none (noul 0.234) | ✓ none (conf 0.676) | ✓ none (conf 0.676) |
| turn the volume down | `none` | ✓ none (noul 0.006) | ✓ none (noul 0.294) | ✗ create_event (conf 0.387) | ✗ create_event (conf 0.387) |
| what did Marcus say about the budget | `none` | ✓ none (noul 0.011) | ✓ none (noul 0.129) | ✗ reply_email (conf 0.983) | ✗ reply_email (conf 0.983) |
| when is the design review | `none` | ✓ none (noul 0.395) | ✓ none (noul 0.368) | ✓ none (conf 0.73) | ✓ none (conf 0.73) |
| did we send the deck | `none` | ✓ none (noul 0.007) | ✗ send_email (noul 0.176) | ✗ reply_email (conf 0.981) | ✗ reply_email (conf 0.981) |
| who is on the vendor thread | `none` | ✓ none (noul 0.489) | ✓ none (noul 0.299) | ✗ reply_email (conf 0.995) | ✗ reply_email (conf 0.995) |
| can you hear me | `none` | ✓ none (noul 0.685) | ✓ none (noul 0.223) | ✓ none (conf 0.884) | ✓ none (conf 0.884) |
| what time is the standup | `none` | ✓ none (noul 0.28) | ✓ none (noul 0.117) | ✓ none (conf 0.684) | ✓ none (conf 0.684) |
| search the web for a CRM | `none` | ✓ none (noul 0.879) | ✗ send_email (noul 0.548) | ✓ none (conf 0.908) | ✓ none (conf 0.908) |
| search Google for a phone number | `none` | ✓ none (noul 0.581) | ✓ none (noul 0.33) | ✓ none (conf 1.0) | ✓ none (conf 1.0) |
| look up what EBITDA means | `none` | ✓ none (noul 0.166) | ✓ none (noul 0.274) | ✓ none (conf 0.875) | ✓ none (conf 0.875) |
| open a browser tab and look something up | `none` | ✓ none (noul 0.759) | ✓ none (noul 0.572) | ✓ none (conf 1.0) | ✓ none (conf 1.0) |
| google the venue's phone number | `none` | ✓ none (noul 0.682) | ✓ none (noul 0.366) | ✓ none (conf 0.924) | ✓ none (conf 0.924) |
| thanks, then the real request | `send_email` | ✗ none (noul 0.236) | ✓ send_email (noul 0.386) | ✓ send_email (conf 0.673) | ✓ send_email (conf 0.673) |
| agree, then book the room | `create_event` | ✗ none (noul 0.107) | ✗ schedule.create (noul 0.498) | ✓ create_event (conf 0.656) | ✓ create_event (conf 0.656) |
| aside, then remember | `memory.remember` | ✓ memory.remember (noul 0.025) | ✓ memory.remember (noul 0.246) | ✓ memory.remember (conf 1.0) | ✓ memory.remember (conf 1.0) |
| opinion, then append | `append_doc` | ✓ append_doc (noul 0.572) | ✓ append_doc (noul 0.284) | ✓ append_doc (conf 1.0) | ✓ append_doc (conf 1.0) |
| question, then reply | `reply_email` | ✗ none (noul 0.091) | ✓ reply_email (noul 0.469) | ✓ reply_email (conf 0.991) | ✓ reply_email (conf 0.991) |
| greeting, then draft | `draft_email` | ✓ draft_email (noul 0.36) | ✓ draft_email (noul 0.507) | ✓ draft_email (conf 0.457) | ✓ draft_email (conf 0.457) |
| two actions: draft then send | `draft_email` | ✓ draft_email (noul 0.983) | ✓ draft_email (noul 0.534) | ✓ draft_email (conf 0.971) | ✓ draft_email (conf 0.971) |
| two actions: email and book | `send_email` | ✗ none (noul 0.872) | ✓ send_email (noul 0.512) | ✗ none (conf 1.0) | ✗ none (conf 1.0) |
| two actions: remember and append | `memory.remember` | ✓ memory.remember (noul 0.012) | ✓ memory.remember (noul 0.376) | ✓ memory.remember (conf 0.988) | ✓ memory.remember (conf 0.988) |
| two actions: reply and schedule | `reply_email` | ✓ reply_email (noul 0.569) | ✓ reply_email (noul 0.582) | ✓ reply_email (conf 0.575) | ✓ reply_email (conf 0.575) |
| I'll email you later | `none` | ✓ none (noul 0.323) | ✓ none (noul 0.477) | ✗ send_email (conf 0.659) | ✗ send_email (conf 0.659) |
| let's schedule a chat | `none` | ✗ create_event (noul 0.881) | ✗ create_event (noul 0.413) | ✗ schedule.create (conf 0.482) | ✗ schedule.create (conf 0.482) |
| we should send an invite | `none` | ✓ none (noul 0.709) | ✗ send_email (noul 0.487) | ✗ send_email (conf 0.912) | ✗ send_email (conf 0.912) |
| I was going to email the vendor | `none` | ✗ memory.remember (noul 0.037) | ✗ send_email (noul 0.268) | ✗ send_email (conf 0.544) | ✗ send_email (conf 0.544) |
| if you email him, mention the deadline | `none` | ✓ none (noul 0.034) | ✗ send_email (noul 0.503) | ✗ send_email (conf 0.217) | ✗ send_email (conf 0.217) |
| should I send the deck | `none` | ✓ none (noul 0.105) | ✗ send_email (noul 0.347) | ✗ send_email (conf 0.79) | ✗ send_email (conf 0.79) |

## The other candidates (published, not measured here)

These need CUDA and/or won't fit beside a ~19 GB free disk, so they are reported from their own READMEs/model cards, read 2026-09-22. **Not run on this machine.**

| model | class | params | size | speed (published) | accuracy (published) | why not run |
|---|---|---|---|---|---|---|
| NanoJev | decision heads (Qwen3-0.6B) | 0.6B | ~1.2 GB bf16 | parallel; CUDA service | ViZDoom Basic 128/128 (game tasks) | CUDA service only (serve_decisions.py); game/RL oriented, not text-tool gating |
| SemIf (ex-OpenJev) | typed logits (Qwen3.5-4B) | 4B | 3.01 GB Q4 GGUF / ~8 GB bf16 | 1.02 s for 21 decisions (RTX 3090); MPS ~133 ms-ish path exists | authored decisions 0.813 bal-acc (4B BF16) | 4B; MPS path exists but heavy for 19 GB disk |
| decider (Mapika) | typed decisions (Qwen3.5) | 2B / 4B / 35B | 2B ~4 GB, 4B 8.4 GB, 35B 65 GB | 2B 133 ms MPS (M1 Pro); 43 ms B300 | held-out 0.755 (2B) / 0.788 (4B) regression set | 2B has an MPS path but was out of the requested download budget |
| openjev | NLI cross-encoder (Qwen3.5) | 0.8B / 4B / 35B | 0.8B ~1.6 GB … 35B MoE | 321 pairs/s SGLang (A6000) | MNLI 86.6, ANLI r1 65.3 (0.8B) | NLI primitive, CUDA/SGLang oriented; not a tool gate |
| Bespoke-Nimble-9B | LoRA over Qwen3.5-9B | 9B (+165 MB adapter) | ~18 GB base + adapter | CUDA BF16 only | Bespoke suite 0.757 (decider's re-run) | needs CUDA + the 9B base; won't fit on this disk |
