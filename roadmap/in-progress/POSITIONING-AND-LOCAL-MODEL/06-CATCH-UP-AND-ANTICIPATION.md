# Catch-up and anticipation (PL-11, PL-12)

**Owner decision 2026-10-04.** The assistant should feel like it sees what's coming and has
already started on it. Two tasks make that real: one warm **Catch-up** that replaces both the
morning podcast and the morning digest (PL-11), and a read-only pass that **notices** patterns,
recurring deadlines, people's habits and seasonal moments before the person asks (PL-12). Read
`00-README.md` "Voice and personality" and `01-PERSONAS-AND-ICP.md` first.

Both tasks run on the existing routine path. Neither adds a store, scheduler, queue, audio
channel or usage log, and neither can send, share, move, pay for or delete anything.

---

## PL-11 — Catch-up (replaces the morning podcast and the morning digest)

**Goal.** One routine, one warm voice, one to three minutes, most urgent first: what needs
you, what happened, what's coming, what I already prepared — ending with an offer to act
("Want me to send the reminders?"). The person can read it or listen to it. It is titled by the
moment: "Your morning catch-up", "Your Monday catch-up", "While you were out".

**Current state (verified by reading the code, 2026-10-04).**
- `Sources/NextNotes/Agent/Schedules/PodcastTemplate.swift`: title "Your morning podcast"; a
  two-host script ("Host A"/"Host B") about yesterday in sections What happened / Decisions /
  What's next; 4–8 minutes, 600–900 words; weekdays 06:00; reads only `get_agenda`,
  `search_knowledge`, `search_email`; `.notifyAndSpeak`. Its `resultTransform` (wired at
  `AgentScheduler.swift`, `answerTransform: PodcastTemplate.resultTransform(renderer: .live())`)
  turns the script into one audio file through `LongFormRenderer` and announces only one line.
- `Sources/NextNotes/Agent/Schedules/DigestTemplate.swift`: title "Morning digest"; a separate
  newsletter-shaped text digest (Today, The Week Ahead, per-person blocks, Watch these, Around
  Town, mail and notes with source and date, Talk at the Table); same three reads, same time,
  same delivery; `DigestAssembler` renders fixtures deterministically.
- `Sources/NextNotes/Agent/Speech/LongFormRenderer.swift`: file sink only — no playback, never
  touches the live voice graph; yields to meetings, dictation and the ASR/notes lanes; atomic
  write; one clause at a time; Pocket or Kokoro at 24 kHz; a per-clause `speaker` lets a
  two-voice engine pick voices. `AGENTS.md` records that its live synthesis has never rendered a
  real file (no voice model is downloaded on the development Mac).
- `Sources/NextNotes/Agent/Schedules/ScheduledRunner.swift`: runs routines under the reads
  ceiling; `silenceToken = "NOTHING_TO_REPORT"` delivers nothing; the system prompt caps a final
  answer at three sentences, which both templates override in their own prompt text.
- `Sources/NextNotes/Agent/Schedules/AgentSchedule.swift` picks the output budget **by title**:
  1,536 tokens for "Morning digest", 4,096 for "Your morning podcast", 384 otherwise. The render
  transform also matches by title. A moment-based title would silently lose both.
- `Sources/NextNotes/Agent/Schedules/AgentTriggerEvents.swift`: trigger events are
  `meetingNotesReady`, `meetingStarting`, `callStarted`. There is no "back after a weekend or
  absence" event. `AgentScheduler`'s presence rule already reads last keyboard/mouse activity,
  recording, dictation, call and agent-busy state (`ScheduleEnvironment`).
- On demand, `schedule.run_now` already exists.
- Neither template's `restatement()` or `createArguments()` has a production caller — only
  their self-tests. AGENT-OVERHAUL P4-06 already records this and owns the offer path.
- There is no web-reading tool for routines; `--selftest-digest` and `--selftest-podcast` both
  assert their prompts never reach the web.

**Work.**
1. **One template.** Merge the two into a single Catch-up template in the existing
   `Agent/Schedules/` seam (one file kept, the other retired), with one routine prompt:
   sections in priority order — *Needs you* (most urgent first), *What happened*, *Coming up*,
   *Already prepared* (things other approved paths have drafted and are waiting for a yes, such
   as meeting follow-up proposals), and one closing *offer*. 150–450 words, one voice, written in
   the "Voice and personality" rules: first person, names not roles, "I noticed…", "Already
   drafted…". Keep the source-and-date habit from the digest for anything read from mail or notes.
2. **Readable and listenable, one result.** The routine's text is the result (notification,
   Activity, Library). Listening uses the same text through the existing `LongFormRenderer`
   transform with one voice; the text is delivered first and an audio failure never withholds
   it. In a live conversation, "catch me up" speaks the catch-up through the existing voice
   output path (the one channel that starts audio), interruptible like any reply — not by
   playing the file.
3. **Identity is not the title.** Give the template a stable identity the budget and the
   transform match on, and compute the display title from the moment ("Your morning catch-up",
   "Your Monday catch-up", "While you were out"). Fix the title-keyed lookup in
   `AgentSchedule` at its producer. Existing schedules titled "Morning digest" or "Your morning
   podcast" keep working and are treated as Catch-up (legacy titles decode; no stored schedule
   is lost or duplicated). Budget sized for 450 words and clamped to the provider window as today.
4. **Triggers on what exists.** Morning: the existing repeat rule (weekdays, a time).
   Back after time away: add one case to the existing `ScheduleTriggerOccurrence.Event`,
   published from the presence signal the scheduler already reads (first presence after a
   weekend or after a set number of hours away), keyed so one return runs once. On demand:
   "catch me up" runs the same routine now (`schedule.run_now` or the same runner path) — never
   a second implementation.
5. **The closing offer is a question, never an action.** "Want me to send the reminders?" becomes
   a pending offer (AGENT-OVERHAUL P1-02 typed pending intent / P4-06 next-step offer). Saying
   yes starts an ordinary turn whose writes go through the normal approval card. The routine
   itself stays inside its reads-only ceiling.
6. **"What's happening in your world" — optional, off by default.** A section about topics the
   person chose in plain words (their kids' school, their industry, local news). It needs a
   read-only web read for routines that does not exist yet; when built it must be opt-in with the
   network use stated, name its sources, treat page text as untrusted data (the reads-only
   ceiling means injected text cannot cause an action), and leave the default catch-up with no
   web reads so the existing no-web assertions keep holding for everyone who has not opted in.
7. **Per-person shape.** The optional onboarding answer from PL-08 orders sections and picks
   emphasis (the household week, the team, matters due, shoots and deliveries). P4-06 offers the
   Catch-up instead of separately offering a digest or a podcast; P4-12's Apple Intelligence route
   keeps it running on a Mac with no downloaded model.

**Example catch-ups** (illustrative; invented names; each about one minute read aloud)

- *Parent — "Your morning catch-up."* "Morning. One thing needs you before school: the zoo
  permission slip is due today — I found it in Ms. Rivera's email and the form's ready to
  print. Thursday's tight: swim at five and your call runs to four forty-five; Dan usually
  confirms pickup by tonight. Coming up, Maya's birthday is in three weeks — last year you
  booked the party place about now. I've already drafted a yes to the Patels' barbecue on
  Saturday. Want me to send it, or check with Dan first?"
- *Office manager — "Your Monday catch-up."* "Morning. Two things need you: Priya starts today
  and her laptop pickup isn't on anyone's calendar, and Alex asked for the board numbers by
  noon. Over the weekend, the cleaners confirmed the new schedule. This week, expenses close
  Friday — four people still owe theirs. I've already drafted the nudges and the follow-ups
  from Thursday's all-hands. Want me to send the expense reminders?"
- *Legal operations — "Your morning catch-up."* "Good morning. The Ortiz response is due
  Friday — the latest draft is v4, saved Tuesday. Mrs. Chen's signed pages haven't arrived, and
  she's usually a day late, so today's a good day to ask. Next week has three filings, and the
  court closes for the holidays in four weeks. I've drafted the note to Mrs. Chen. Want me to
  send it?"
- *Editor — "While you were out."* "Welcome back. While you were away, Jess moved the
  Brightside delivery to Monday, and the client left notes on the colour in Friday's call —
  they're ready for you. Tuesday's cards are still in Downloads; I've drafted a sort by shoot
  day, nothing moved yet. Want to look at the plan?"

**Acceptance evidence.**
- Red first: new cases in the existing `--selftest-digest` / `--selftest-podcast` runners fail on
  the current templates (two-host, 4–8 minutes, no moment title, no return trigger). If the flags
  are renamed (for example to one `--selftest-catch-up`), rename only through the existing seams:
  the registration in `NextNotesApp.runRequestedSelfTest`, the entries in `Scripts/acceptance.sh`
  and the flag list in `AGENTS.md` (single-writer files — coordinate), with the old flags kept as
  aliases until the acceptance tiers move.
- Scripted runs of the real `ScheduledRunner` over PL-05 persona fixtures: reads only, under
  `.scheduled` authority, nothing waits on `PermissionGate`; most urgent first; 150–450 words;
  silence on an empty day; the closing offer is a pending offer, not an executed write.
- Legacy schedules titled "Morning digest" and "Your morning podcast" load, get the right
  budget and run as Catch-up; nothing is duplicated.
- The return trigger fires once per return, never during quiet hours, a call, a recording or
  dictation (the existing presence rule).
- One-voice render through the existing synthesis spy (the `PodcastSelfTest` pattern): exact
  duration, atomic write, live voice graph idle, nothing played into a call.
- Copy passes `--selftest-ui-strings`, `--selftest-persona` and `PersonaCareEval`;
  `--selftest-schedule`, `--selftest-scheduler`, `--selftest-routine-authority` and
  `--selftest-store-isolation` pass.
- **Recorded as unproven:** the real voice render, until a Pocket or Kokoro voice is downloaded
  and one real file is produced and listened to.

**Must not.** Add a store, scheduler, timer service, queue or second audio path; let the routine
call anything above read risk; auto-play into a call, a meeting, dictation or quiet hours; read
the web by default; keep two routines (digest and podcast) side by side; break or orphan an
existing stored schedule; claim the voice works before a real render.

## PL-12 — Noticing what's coming

**Goal.** Before the person asks, the assistant knows the shape of their weeks: who does what on
which day, the deadlines that come back every month or term, the people who always need a
second reminder, the things that happened "about now" last year. It offers, it never acts, and
it always says how it knows.

**Depends on.** PL-05 (fixture corpora to extend over weeks); feeds PL-11 ("Already prepared",
"Coming up") and PL-06 (offers). Coordinates with AGENT-OVERHAUL P4-05's planned suggestion lane
for dismissals and P4-11 memory review.

**Current state (verified 2026-10-04).** Reads exist: `workspace.get_agenda` for any date
(including a year ago), `search_email`, `search_knowledge`, the knowledge graph's `timeline` and
`expand_node` (graph off by default), `memory.recall`, meeting participants and history. The
Portrait pass (`--selftest-portrait`) mines the graph into insight drafts the person reviews; it
has only run on fixtures. Nothing looks across weeks for recurring patterns in calendar, mail
or files. P4-05's suggestion lane (`MeetingSuggestionStore`, `ProactiveService`) is planned, not
built.

**Work.**
1. A read-only routine on the existing `ScheduledRunner` (weekly, off the turn path, at
   background priority) that proposes *noticed* items with evidence: the dates of the past
   occurrences, or the sentence where the person said it.
2. An evidence bar before anything is offered (proposed: three or more matching occurrences, or
   one explicit statement by the person); below it, nothing is said.
3. Noticed items surface only through the Catch-up and PL-06 offers. Accepting one becomes an
   ordinary memory (existing `NextMemory` with provenance) or schedule (existing `ScheduleStore`)
   after a yes; dismissing one is honoured. Dismissal state extends P4-05's suggestion lane rather
   than adding a store; if a non-meeting home is needed, that decision is recorded with P4-05's
   owner first.
4. Every spoken or written item says how it knows: "the last three Thursdays", "you said in
   September", "last year on the 14th".

**Acceptance evidence.** Persona fixture months (8–12 weeks per person) with planted patterns and
planted near-misses: planted patterns found with their evidence; near-misses not offered
(proposed: at most one wrong "noticed" item per fixture month); dismissed items not offered again;
no write, no cloud call, no owner data; `--selftest-memory`, `--selftest-schedule`,
`--selftest-store-isolation` pass.

**Must not.** Act on a pattern; offer one below the evidence bar; send anything off the Mac;
mine content into memory without the person's yes; add a pattern store, ledger or scheduler; run
on the foreground path or during a voice turn.
