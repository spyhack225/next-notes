# POSITIONING-AND-LOCAL-MODEL: start here

**Owner decision: 2026-10-04.** Next Notes is for people who want an AI agent but will not
or cannot set one up. The agent runs privately on the Mac, and it has to be fast on the
cheapest Mac Apple sells, not only on the fastest. This folder turns that decision into
work: who we build for, how we prove speed on the low-end floor, which open model we ship
silently, how we make it better than the stock model, and what each person needs it to do.

This is a plan. No task here, or in a sibling roadmap, becomes implemented or green because
this document changed. Read this file, root `AGENTS.md` (especially "What we optimize for"
and "Dumb simple, and never nerd-shaped"), then `STATUS.md` in this folder. `roadmap/` is
git-ignored; never commit it or put plans in the published `docs/`. Reports go in
`Tests/Reports/`.

---

## 1. Who it is for

Not the tech-savvy, and not anyone who knows what a language model is. Four people, each
named by the job they already do. They are a starting point, not a closed list (owner
feedback 2026-10-04): `01-PERSONAS-AND-ICP.md` describes them in depth, adds adjacent people
with the same traits, and maps their jobs to what exists and what is missing.

| Person | What their week looks like | What they want taken off their plate |
|---|---|---|
| **The parent running the household** | School calendar, family schedule, budgeting, groceries, planning | "Do I have time to pick up the kids?", a weekly family plan, the grocery list, school emails that need an answer |
| **The office manager** | Onboarding new staff, sending email, keeping the team's calendar on track | Summarise the inbox, send the follow-ups after a meeting, set up a new hire's first week |
| **The legal-practice operations manager** (not the lawyer) | Many cases moving at once, deadlines, file sharing | Which case has a deadline this week, where the latest file for a case is, what still has not been shared |
| **The filmmaker / editor** | Footage across shoot dates, sessions and drives | Find the footage from Tuesday's shoot, sort a card dump by date and session, keep two drives in step |

**The promise.** The agent listens and answers, talks while it works (full duplex), does
things before being asked when it is sure they help, and never makes the person do
technical work. It runs on their Mac. They never download or pick a model, never see a
terminal, never hop between tabs to get something done. Reads happen by themselves;
anything that sends, deletes or cannot be taken back waits for one approval, and the card
says exactly what will happen first. That last rule is unchanged from `AGENTS.md`.

**What we are not.**
- Not a developer tool, a model playground or a model picker. The advanced Models view may
  exist, but it is opt-in and never part of the default path.
- Not a cloud agent. Cloud is an explicit, per-workload choice (AGENT-OVERHAUL P4-09 and
  Phase 5); the default is local.
- Not autonomous about consequential actions. Proactive means it notices, prepares and
  offers; it does not send, share, buy, move or delete without the person's yes.
- Not a phone-first product. It is Mac-first; reach beyond the open Mac is AGENT-OVERHAUL
  X08 and is unproven.
- Not on Windows yet for the agent or meetings. The Windows dictation app has never run on
  real hardware (`AGENTS.md`).

## 2. The competitive map (research 2026-10-04)

Everything in this table is what each company says about itself on or around that date. We
have not verified their numbers, and their benchmarks run on hardware we do not target.

| Product | Where it runs | Surfaces | Meetings / dictation | Model story | Safety story | Access |
|---|---|---|---|---|---|---|
| **Underdog** (underdog.ai) | "100% local" | Mac, Windows beta | Meeting notes and dictation, plus email, calendar, errands | Own models: Woof 4B (~115 tok/s claimed), Underdog 27B (Qwen-based, claims to beat Claude Opus 4.6 Max on the Artificial Analysis index); benchmarked on high-end hardware | Security assessments, Google approval for Gmail/Calendar, "Naval mode" that never calls home | Invite-only beta; backed by a16z, Khosla, Anthology (Anthropic) |
| **Meta Muse** (launched 2026-09-08) | Cloud | iOS, Android, muse.ai; glasses coming | None announced | Meta's cloud models | Muse Secure VM, "Sentinel agent", approvals, audit trail, memory, training opt-out; encrypted Confidential VM promised | Free tier plus subscriptions |
| **OpenAI Dots** (2026-09-29) | Cloud, always on | ChatGPT | Not the focus | GPT-6 Astra; 4,000+ apps; its own computer | User-set boundaries | ChatGPT Pro, Business Premium, Enterprise |
| **xAI Grok Bot** (x.ai/bot) | Cloud | "Teammate" in work tools | Meeting stand-in; notes from other recorders | Grok | Not detailed | Bundled with SuperGrok and Cursor plans |
| **Next Notes** | Local by default, on the Mac | Mac (Windows dictation unproven) | Push-to-talk dictation in daily use; two-track meeting capture, speakers, notes | Open models under test (section 4); none yet passes our quality bar | Reads run, irreversible writes wait for one approval; `usage.jsonl` never leaves the Mac | AGPL-3.0, open source |

**What this means.** Underdog already owns the sentence "local and private". We cannot win
by saying it louder. Our edge has to be the things that are true and that they do not lead
with:
1. **Made for the four people above**, not for people who read model cards.
2. **Proactive, full-duplex voice**: it listens while it speaks and offers before it is asked.
3. **Depth in meetings**: two tracks, speakers, notes, owed items, follow-ups.
4. **Open source (AGPL)**: anyone can check what runs on their Mac.
5. **Proven on the cheapest Mac**: we publish floor-machine numbers, where they publish
   numbers from the most expensive one. That claim is worth something only once the floor
   benchmark in `02-FLOOR-BENCHMARK.md` passes; until then it is a goal, not a claim.

## Messaging rules

These bind every sentence a customer reads or hears: the site, onboarding, empty states,
the agent's own speech, release notes. They are the outward half of `AGENTS.md`'s "Dumb
simple, and never nerd-shaped".

1. **Sell the outcome, never the feature.** Say what changes in the person's day: "The
   follow-ups are written before you're back at your desk", not "AI meeting notes with action
   item extraction".
2. **Never lead with a capability.** Lead with their problem or their result; the capability
   is, at most, the reason it works, and usually goes unsaid.
3. **Translate every technical fact into a benefit.**

   | Technical fact | What we say |
   |---|---|
   | Open source (AGPL) | "Anyone can check how it works, so you know your things stay private." |
   | Runs locally / on-device model | "It works on your Mac. Your family's calendar and your clients' files don't go anywhere." |
   | Fast on a MacBook Air with 16 GB | "It keeps up with you on the Mac you already have." |
   | Approval before irreversible actions | "Nothing is sent, shared or moved until you say yes." |
   | Full-duplex voice | "Talk to it like a person. Interrupt it, change your mind, it keeps up." |
   | Proactive triggers and routines | "It tells you what you're about to forget." |
   | Receipts / outcome-unknown handling | "If it isn't sure something went out, it tells you instead of sending it twice." |
   | Speaker identification | "Your notes know who said what." |

4. **Words we never use with customers:** model, LLM, AI model, open source (as a bare
   label), on-device inference, tokens, parameters, API, OAuth, terminal, index, sync engine,
   prompt, agent framework, tool call, schema. Engineering documents, including this one, may
   use them.
5. **Speak in the person's own nouns.** Pickup, permission slip, all-hands, new hire, matter,
   filing deadline, shoot day, card, drive — `01-PERSONAS-AND-ICP.md` lists them per person.
6. **Show it with their own things.** The first impression is an answer about their week,
   their meeting or their files, not a tour or a list of what it can do.
7. **Sell the vision; label its status honestly (owner decision, 2026-10-04).** The website
   paints the full end state, the "moon" of what this assistant will do for each person, not
   only what ships today. Every capability carries a visible status: **Available now**,
   **In progress** or **Coming soon**. A capability is only labelled "Available now" once it
   has passed its gate (AGENT-OVERHAUL X11 claim gate; "fast on the cheapest Mac" waits for
   `02-FLOOR-BENCHMARK.md`). In-product copy (onboarding, empty states, the agent's own speech)
   describes only what works today; the vision belongs on the site and in release notes.

## Voice and personality

**Owner decision, 2026-10-04.** The assistant must feel personal, close, connected and a step
ahead — never organisational, bureaucratic or boring. It should feel like it knows what you
need before you do and has already started on it. It talks like someone who knows you and your
people, not like a system issuing notifications. The name the person chose in onboarding is
its name (`AGENTS.md`: the name never appears in a prompt; `AgentGrounding` supplies it).

**How it sounds**
1. **The warm word over the formal word.**

   | Instead of | Say |
   |---|---|
   | briefing, digest, report | catch-up |
   | contacts, recipients | your people, or their names |
   | notification, alert, reminder fired | a sentence from me: "Quick one —" |
   | task completed | done |
   | event, calendar entry | the dentist, swim, the all-hands |
   | action items, deliverables | what you owe, what Sam owes you |
   | pending approval | ready for you to check |
   | error, failed | I couldn't — and what I did instead |

2. **First person, short, caring.** "I", "you", names. One thought per sentence. It notices how
   the day is going ("Tight afternoon —"), never gushes, never flatters (the existing
   no-flattery rule in `Resources/agent-persona-base.md` stands).
3. **Anticipation is framed as already handled, not as an alert.** Lead with what it did or
   prepared, then the one choice left: "I noticed…", "Already drafted…", "Before you ask…",
   "Want me to keep Thursday clear?". Never "Reminder:", "Alert:", "You have 3 new…".
4. **It knows your people.** It uses the names and relationships it has learned ("your mum",
   "Priya from accounts") — only from what the person said or what their own mail, calendar and
   meetings show.

**The limits that keep it trustworthy** (these outrank warmth every time)
- **It never acts irreversibly without a yes.** Prepared and drafted, yes; sent, shared, moved,
  paid or deleted, only after the person says so. "Already drafted" never means "already sent".
- **It says how it knows.** "From Ms. Rivera's email on Monday", "you said last week", "the last
  three Thursdays". A guess is labelled as a guess.
- **It never pretends certainty.** "I think", "I'm not sure it went out", "I can't see that" are
  part of its voice, not failures of it.
- **It backs off when dismissed.** A "not now" or "stop suggesting that" is remembered and
  honoured; it does not ask the same thing twice the same day.
- **It is quiet when there is nothing worth saying** (the routine silence rule), and never
  speaks into a call or during quiet hours.

**Before and after**

| Before (system voice) | After (our voice) |
|---|---|
| "Reminder: Event 'Swim practice' at 17:00." | "Swim's at five — I checked, nobody's down to drive. Want me to ask Dan?" |
| "Your morning digest is ready." | "Your morning catch-up's ready. Two things need you before nine." |
| "3 action items were extracted from 'All-hands'." | "I've already drafted the three follow-ups from the all-hands. Want to look before they go?" |
| "Deadline approaching: Ortiz response (3 days)." | "Before you ask — the Ortiz response is due Friday. The latest draft is v4, from Tuesday." |
| "Error: send_email failed." | "I'm not sure that email went out. I won't resend it until you tell me." |
| "No events found." | "Nothing on tomorrow. Want me to keep it that way?" |
| "Contacts matching 'Sam': 2." | "Do you mean Sam from school or Sam at the studio?" |

`--selftest-persona`, `PersonaCareEval` and `--selftest-ui-strings` are the floor for these rules,
not the goal. Per-person examples of how it feels and what it anticipates are in
`01-PERSONAS-AND-ICP.md`.

## 3. Honest strengths and weaknesses (2026-10-04)

**Strengths we can stand behind today**
- macOS dictation works and is in daily use: target captured at key-down, bounded tail,
  cleanup with MiniCPM5-2B and an Apple guard/fallback (`Tests/Reports/MODEL-COMPARE-CLEANUP-2026-09-30.md`:
  3/42 failures at 0.59 s per case vs Apple 0/42 at 3.03 s).
- Meetings capture two tracks, transcribe with Parakeet, tell speakers apart, write notes,
  and resume after an interrupted run (`--selftest-meeting-resume`, CORE).
- The permission model is the right shape: `AgentRisk` grades every tool, reads run
  themselves, writes wait for a person, an unknown outcome is "not sure", never "failed".
- Local models already load on the floor machine. The owner's Mac is a MacBook Air M3
  (`Mac15,12`), 16 GB, 245 GB disk, and has run MiniCPM5-2B, Qwen3-4B-Instruct-2507,
  Qwen3.5-4B and Gemma 4 E4B through the real tool loop (P1-31a report below).
- The llama prefix cache is real: 646 of 666 prompt tokens reused, prefill 2.10 s → 0.33 s
  (`--selftest-llm-prefix-cache`, recorded in `AGENTS.md`).
- One local usage record (`usage.jsonl`) already carries per-pass `tokensPerSec`, `ttftMs`,
  `loadMs`, `cachedTokens`, provider and model (`Sources/NextNotes/Support/Usage/UsageRecord.swift`).
- AGPL-3.0, every dependency BSD/MIT/Apache/ISC/OFL.

**Weaknesses, said plainly**
- **The agent is not good enough yet.** The fixed quick tool-loop set scores 3/10 at the
  latest run against a 9/10 bar (AGENT-OVERHAUL STATUS, quick156); recent runs range 2–5/10.
  The best full run is Qwen3-4B 17/30 against 25/30 on two consecutive runs
  (`Tests/Reports/toolloop-live/2026-09-30-p1-31-investigation.md`).
- **Voice is too slow.** Warm speech-end-to-first-audio median is 2.894 s against 0.9 s
  (AGENT-OVERHAUL STATUS current position). The 2026-10-01 native baseline median was 4.776 s.
- **The wake word misses.** 17/24 hits with 3/32 false accepts against a 0.8 bar.
- **Google setup is nerd-shaped.** Workspace setup installs `gws`, authorises a Google
  Cloud project and signs in through Terminal (`Sources/NextNotes/Agent/WorkspaceInstaller.swift`),
  and the Google Calendar path asks for the person's own OAuth client id and secret
  (`Sources/NextNotes/UI/Settings/CalendarSettingsTab.swift`, the "Client secret" field).
  Every persona above needs mail and calendar, so this is the biggest gap against the promise.
- **No Workspace write has ever completed live**, so send/create paths are unproven. (Checked
  2026-10-04 in `action-receipts.json`: the one approved write, an `append_doc` on
  2026-09-20, fired and failed with no saved result.)
- **Proactive journeys are not built.** P4-04 (pre-meeting brief), P4-05 (owed items) and
  P4-06 (morning offer, nudges) are open; durable jobs, recovery and retry are open.
- **First-run still downloads a ~5 GB notes model.** `OnboardingBrainStep` fetches
  `NotesModels.spec` (Gemma 4 E4B, 4,977,171,584 bytes). The owner's own 256 GB-class Mac had
  8.5 GiB free on 2026-10-04 with about 12.7 GB of model files in its Models folder.
- **No speed or size tricks are in use yet.** The pinned llama.cpp (b10621, `Package.swift`)
  exposes LoRA adapters and an MTP context type in `llama.h`, but the app calls neither;
  native tool calling is off by default (`Settings.agentNativeToolCalling`).
- Not notarized, so a downloaded copy is refused by Gatekeeper; Windows has never run on
  hardware; the screenshot/vision path has never seen real pixels.

Prior speed and quality measurements on the owner's Mac were taken on the floor hardware,
but under shared load from concurrent agent builds and a nearly full disk. They are
diagnostics, not clean floor runs.

## 4. Model strategy

1. **Bake off on the floor.** Run every candidate through the real code paths on the
   reference machine, with speech recognition and voice running (PL-02).
2. **Pick one winner and ship it silently.** The person never chooses. One resident
   artifact serving several roles is preferred when each role's own gate allows it (PL-03).
3. **Make the winner better than stock.** Prompting, the native-tool grammar, quantization,
   speculative decoding with a draft or MTP head, the prefix cache, and a LoRA fine-tune
   trained on privacy-safe persona data. Each change is kept only if the same benchmark
   shows it helped and nothing regressed (PL-04).

**Candidates under test** (exact artifacts already on the owner's Mac or named in code):

| Candidate | Artifact seen in this repo | Bytes on disk | Floor decode, predicted* |
|---|---|---:|---:|
| Apple Foundation Models | built into macOS; the no-download baseline | 0 | not a GGUF; measured only |
| MiniCPM5-2B | `openbmb/MiniCPM5-2B-GGUF/MiniCPM5-2B-Q4_K_M.gguf` (`AGENTS.md`) | 1,561,318,368 | ~42 tok/s |
| Qwen3-4B-Instruct-2507 | `unsloth--Qwen3-4B-Instruct-2507-Q4_K_M.gguf` | 2,497,281,120 | ~26 tok/s |
| Qwen3.5-4B | `unsloth--Qwen3.5-4B-Q4_K_M.gguf` | 2,740,937,888 | ~24 tok/s |
| Gemma 4 E4B | `gemma-4-E4B-it-Q4_K_M.gguf` (`NotesModels.swift`, SHA-256 pinned) | 4,977,171,584 | ~13 tok/s |
| A code-specialised model | **none is pinned or named in the repo yet**; PL-02 names one | — | — |
| Needle 3 (first-call engine) | `needle3-macos-arm64` + `needle3.cact` | ~36 MB | separate arm, owned by AGENT-OVERHAUL P1-31 |

\* Predicted by the app's own `ModelFitEstimator.tokensPerSecond` (100 GB/s for M2/M3 base
× 0.65 ÷ file bytes). It is arithmetic, not a measurement, and ignores contention from
speech recognition. It already suggests Gemma 4 E4B at Q4_K_M will miss the 20 tok/s
floor and that the 4B models sit right at it — which is why the floor has to be measured.

The candidate list in code is `modelCompareCandidates` in `Sources/NextNotes/NextNotesApp.swift`
(the `--selftest-cleanup app-llm-compare` leg). The code model must fit the floor memory
budget; a 30B-class mixture-of-experts coder does not fit a 16 GB Mac with the app
running. The existing tolerant parser already reads Qwen3-Coder XML tool calls
(AGENT-OVERHAUL `02-PHASE-1-TOOLS.md`), so a coder-family candidate needs no new parser.

## 5. How this roadmap relates to the others

This folder adds a **target audience, a hardware floor and a model decision**. It owns no
new store, ledger, queue, channel, tool manifest, usage log, download manager, runtime or
benchmark harness. Every task extends an existing seam:

| Sibling | What it already owns | What this folder adds |
|---|---|---|
| [AGENT-OVERHAUL](../AGENT-OVERHAUL/00-README.md) | Agent quality gates (quick 9/10, full ≥25/30 twice, owner O01–O10), latency (Phase 2), full duplex (Phase 3), proactive (Phase 4), capacity (P3-07), durable jobs (Phase 6), product exits X01–X11 | Gates judged on the floor machine; persona fixture sets beside O01–O10; persona proactive journeys feed P4-04/05/06 and X06 |
| [SHARED-BRAIN](../SHARED-BRAIN/00-README.md) | Artifact identity, independent roles, request ownership, SB-07 per-role recommendations | The bake-off is SB-07's evidence; the winner becomes the silent recommendation |
| [MODULES-ACTIVATION](../MODULES-ACTIVATION/00-README.md) | Module switches, union-of-requirements setup (MOD-08/09) | The 256 GB disk budget; no model choice in onboarding |
| [WEBSITE-TO-MAC-EXPERIENCE](../WEBSITE-TO-MAC-EXPERIENCE/00-README.md) | Look, motion, first success (UX-09) | Persona copy and examples only for capabilities that work |

Rules carried over without change: one task ledger (`AgentTaskManager`/`AgentTaskStore`),
one channel that starts audio, one tool manifest (`AgentCapabilityManifest`), one usage log
(`usage.jsonl`). Measure with existing `--selftest-*` flags and `--usage-report`; where a
flag cannot measure something the floor needs, extend that flag with a modifier (PL-01)
rather than writing a second harness. No sequential await, fixed sleep, debounce or second
confirmation on a path the user's turn sits on. Fix bugs at the producer.

## 6. File map and order

| File | Tasks |
|---|---|
| `01-PERSONAS-AND-ICP.md` | The ideal customer, the four people and adjacent ones, written as outcomes; capability map and spoken examples (no tasks) |
| `02-FLOOR-BENCHMARK.md` | The floor benchmark specification and PL-01, the one harness extension it needs |
| `03-MODEL-BAKEOFF-AND-DEFAULT.md` | PL-02 bake-off, PL-03 pin the silent default, PL-04 augment the winner |
| `04-PERSONA-JOBS.md` | PL-05 persona evals, PL-06 proactive behaviours, PL-07 file organisation, PL-10 Apple Calendar and Reminders |
| `05-FIRST-RUN.md` | PL-08 onboarding with no technical question, PL-09 Google without Terminal |
| `06-CATCH-UP-AND-ANTICIPATION.md` | PL-11 Catch-up (one routine replacing the morning podcast and digest), PL-12 noticing patterns before the person asks |
| `STATUS.md` | Task states and evidence; update after each task |

**Order:** PL-01 → PL-02 → PL-03 → PL-04. PL-05 can start now (fixtures need no model) and
should land before PL-02's final runs so the bake-off includes persona scores. PL-06 waits
on AGENT-OVERHAUL P4-04/05/06 contracts. PL-07 read/plan steps can start now; its write leg
waits for the receipt/approval seams (AGENT-OVERHAUL P1-21, P6-06). PL-08 and PL-09 can
start now and coordinate with MOD-08, SB-05, UX-09 and X09. PL-10 can start now; PL-05's H
cases give it a red-first check.
PL-11 can start now on the existing scheduler and templates; its offer path is AGENT-OVERHAUL
P4-06's and its voice render stays unproven until a voice is downloaded. PL-12 starts after
PL-05 (it needs persona fixture weeks) and feeds PL-11 and PL-06.

## 7. Open owner decisions

These thresholds are proposed in `02-FLOOR-BENCHMARK.md` and need the owner's yes before a
gate uses them: the memory ceiling, the default-path disk budget, the warm time-to-first-token
budget, and whether a battery-power run is required. Also open: which code model to test,
whether to pursue a verified Google OAuth app (PL-09), and whether an M2 Air must be borrowed
for the floor claim to name M2 as well as M3.

## 8. Glossary

- **Floor machine**: MacBook Air M2 or M3, 16 GB unified memory, 256 GB storage.
- **Decode tok/s**: generated tokens per second after the first token; `usage.jsonl`'s
  `tokensPerSec` is `completionTokens / (totalMs − ttftMs)`.
- **Under load**: speech recognition (and, for C2, the voice reply) running while the model
  decodes. Defined exactly in `02-FLOOR-BENCHMARK.md`.
- **Silent default**: the artifact the app fetches and uses with no choice shown; explicit
  stored choices are still preserved.
- **Augmented**: the winner plus measured improvements (grammar, quantization, draft head,
  LoRA). "Beats stock" means the same benchmark, same corpus, higher score or speed.
