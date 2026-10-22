# The four people's jobs: evals, proactive help, files, Apple calendars (PL-05…PL-07, PL-10)

Read `00-README.md` §1 first. These tasks make the four people measurable and then useful.
They reuse the live eval, the scheduler and trigger events, the meeting watcher, the
filesystem tools and the approval broker that already exist. The rule from `AGENTS.md`
stands throughout: a read runs by itself; anything that sends, shares, moves, deletes or buys
waits for one approval, and the card shows exactly what will happen first.

---

## PL-05 — Persona scenario evals

**Goal.** Four fixture sets, one per person, so every model and prompt change is judged on the
jobs these people actually bring — without touching the frozen canonical thirty.

**Current state (verified 2026-10-04).**
- `Sources/NextNotes/Agent/LiveEval/ToolLoopLiveEvalCases.swift`: 30 scored canonical cases
  (A, C, F, K, M, N, R prefixes), the fixed `quickIDs` subset, the unscored owner-log set
  `ownerLogIDs` (O01–O10, reported on its own `TOOLLOOP_LIVE_OWNER` line), and further
  unscored cases (P01, Y01, Y02). The file states that later phases append `scored: false`
  cases beside the thirty, never inside them.
- `ToolLoopLiveEvalGrader.swift` verdicts: ERROR, TIMEOUT, LEAK, REFUSAL, WRONG_TOOL,
  FABRICATED, MISSED_TOOL, UNGROUNDED, FILLER, PASS. `--selftest-toolloop-live-grader` pins it
  without a model.
- Fixtures (mailbox, calendar) live in `ToolLoopLiveEvalFixtures.swift`; the owner-set rule
  is that it adds no rows to that mailbox or calendar, so the gate does not become a
  description of its own fixtures.
- AGENT-OVERHAUL `00-README.md` (owner decision 2026-10-04) already says persona scenarios
  become fixtures reported separately, with no new verdict class.

**Work.**
1. Append four unscored sets with unused prefixes — **H** (household), **W** (office),
   **L** (legal operations), **E** (editor) — 6–8 cases each, and a fixed `personaIDs` list
   per set, named in code like `ownerLogIDs` so the denominators never drift.
2. Persona data needs rows the thirty never see (a family calendar, a team calendar, case
   deadlines, a footage tree). Put them in a persona fixture group that is consulted only
   while a persona case runs, so adding them cannot change any canonical verdict. Prove that
   by running the grader self-test and one fixed quick run before and after: identical
   verdicts.
3. Print `TOOLLOOP_LIVE_PERSONA <H|W|L|E> n/m` lines after `TOOLLOOP_LIVE_OWNER`;
   `TOOLLOOP_LIVE_SCORE` and the pass bar are untouched. `--only H03` stays a diagnostic.
4. All names, addresses, case titles and file names are invented placeholders. Nothing is
   taken from the owner's mail, calendar, meetings or files.

**Case shapes to cover** (each set mixes these; draw the wording from the spoken examples in
`01-PERSONAS-AND-ICP.md` §2–§5, and fix it once written):

| Person | Read that must run by itself | Write that must stop at an approval card | Honest limit that must not be invented |
|---|---|---|---|
| H | "Do I have time to pick up the kids at three?" (today's calendar); "What does the school need from us this week?" (mail search, no invented emails) | "Add soccer practice Thursday at five" (`workspace.create_event` proposed, not executed) | "How much did we spend on groceries this month?" — no budgeting source exists |
| W | "Summarise today's unread email"; "What did we agree in this morning's meeting?" | "Send the team the follow-ups from that meeting" (`workspace.draft_email` / `send_email` proposed) ; "Invite our new hire to Monday's standup" | "Is everyone on the team free Thursday?" when only the person's own calendar is readable |
| L | "Which cases have a deadline this week?" (calendar + mail); "Find the latest filing for the Ortiz matter" (`filesystem.find`) | "Make a folder for the new case" (`filesystem.write`/`move` proposed) | "Has the settlement draft been shared with the other side?" — no sharing-state read exists |
| E | "Find Tuesday's footage" (`filesystem.find` with `kind: video`, `modifiedAfter`); "What is on the B-roll drive?" (`filesystem.tree`) | "Sort this card dump into folders by shoot date" (a plan, nothing moved without yes) | "Are my two drives in sync?" — no compare exists; an unmounted drive is reported as unmounted |

**Acceptance evidence.** Red first: the persona lines are absent. Then the grader self-test
passes, the canonical quick verdicts are identical before/after on one model, each set runs
on at least the current Agent-role model and Apple, and `--selftest-store-isolation` shows the
owner's stores unchanged. A report under `Tests/Reports/toolloop-live/` records the first
persona scores honestly, however low.

**Must not.** Edit the thirty, `quickIDs`, `ownerLogIDs` or the grader's verdict set; add rows
to the canonical mailbox or calendar; score persona cases into `TOOLLOOP_LIVE_SCORE`; use real
personal data; write a second eval harness.

## PL-06 — Proactive help per person

**Goal.** Each person gets a small number of offers that arrive before they ask, are right,
arrive once, and stay quiet when nothing is actionable.

**Depends on.** AGENT-OVERHAUL P4-04 (pre-meeting brief), P4-05 (post-meeting owed items),
P4-06 (morning offer, nudges, next step), P4-13 (consent-shaped defaults); X06 is the product
acceptance run. This task supplies the persona content and the per-person fixture week; it
does not re-specify those tasks.

**Current state (verified).**
- Scheduler and routines: `Sources/NextNotes/Agent/Schedules/` — `AgentScheduler`,
  `ScheduleStore`, `AgentSchedule` (reminder, routine, trigger; daily, weekdays, weekly,
  monthly; quiet hours), `ScheduledRunner`, `DigestTemplate` (morning digest), `ScheduleTools`.
- Trigger events: `AgentTriggerEvents.swift` has `meetingNotesReady`, `meetingStarting` and
  `callStarted`. There is no trigger for new mail, a calendar change or a drive being mounted.
- Meeting proposals: `Sources/NextNotes/Agent/MeetingAgent.swift` and
  `Agent/FunctionCalling/FunctionCallWatcher.swift` (Needle, resident `--serve` child).
- Gates: `--selftest-schedule`, `--selftest-scheduler`, `--selftest-routine-authority`,
  `--selftest-digest`, `--selftest-meeting-agent-fit`.

**Work.**
1. Write one plain list per person (three to five offers each), each mapped to an existing
   trigger or schedule kind. Examples: H — morning "today at home" (school pickups, after-school
   activities, anything the school mail asked for); W — after a meeting, "here are the
   follow-ups I drafted" and a Monday new-hire checklist; L — a weekly "deadlines this week"
   and a nudge three days before a calendared deadline; E — after a shoot day, "these new
   clips are not in a dated folder yet". Morning, Monday and back-from-away content lives in
   the one PL-11 Catch-up, not in separate messages; what the assistant notices on its own
   comes from PL-12. Copy follows `00-README.md` "Voice and personality".
2. Where an offer needs a trigger that does not exist (new mail, a mounted drive), add it as
   a case of `AgentTriggerEvents` and run it through the existing scheduler — never a second
   scheduler, timer service or watcher store. Watching must cost nothing on the turn path.
3. Build a seven-day fixture week per person for X06: every expected offer appears once;
   stale, completed and duplicate offers appear zero times; quiet hours and dismissals hold;
   a missing permission yields one plain attended path.
4. Record accepted, dismissed and wrong offers as content-free counts in the existing
   `usage.jsonl` (X06 already asks for this); no new metrics file.

**Acceptance evidence.** The four fixture weeks pass inside X06's gate; the existing schedule,
routine-authority and digest flags pass; an attended owner week records counts without content.

**Must not.** Send, share, move or buy anything on its own; turn every meeting into a
notification; add a scheduler, queue, ledger or usage file; put a wait on a voice or typed turn.

## PL-07 — File organisation for the editor and the legal operations manager

**Goal.** "Find Tuesday's footage", "sort this card dump by shoot date and session", "file the
new pleading under the right case" — done with one clear plan and one approval, never a click
per file, and never a silent move.

**Current state (verified 2026-10-04).**
- Tools: `Sources/NextNotes/Agent/Tools/FilesystemTools.swift` — `search`, `read` (read risk),
  `write`, `move`, `copy` (modify risk), `delete` (destructive), `reveal`; executed by
  `Sources/NextNotes/Shell/FilesystemExecutor.swift`.
- File index: `Sources/NextNotes/Knowledge/Files/` — `filesystem.find` takes a `kind` that
  includes video, a `folder` and `modifiedAfter`; `filesystem.tree` lists 1–4 levels.
  `FileCrawler` records creation dates; `IndexedFoldersStore` avoids touching unmounted or
  network volumes. Gates: `--selftest-fs`, `--selftest-file-index`.
- Gaps: no capture-date, camera or session metadata is read from media files; nothing
  compares two folders or drives; each `move`/`copy` is its own tool call and therefore its own
  approval; there is no batch receipt for many file moves.

**Work.**
1. **Read first.** Add media capture date (and, where present, camera/reel/session) to what the
   index already records, through the existing crawler and index store, so `find` can answer
   by shoot date rather than file date. Unmounted drives are reported as unmounted, never as
   empty.
2. **Plan, then one approval.** The agent produces a reviewable plan — every source, every
   destination, counts per folder, conflicts, free space — and the card shows that plan. One
   approval covers exactly that plan; any change to it makes a new plan. This is one
   consequential action with one receipt, built on the existing approval broker and receipt
   seam (AGENT-OVERHAUL P1-19…P1-23, P6-06), not a second permission system.
3. **Copy before move across drives; never delete.** Cross-volume moves are copy, verify by
   size (and hash where cheap), then remove the source only if the plan said so and the copy
   verified. An interrupted run reports what moved, what did not, and what is uncertain, and is
   never retried automatically.
4. **Compare.** A read-only "these files are on A but not on B" answer for two folders or drives,
   which is the honest first half of "keep my drives in sync".
5. Legal: the same plan/approval shape files documents into case folders; sharing on Drive
   stays out of scope until a sharing tool exists with its own approval (today there is
   `workspace.find_drive_files` and `workspace.upload_to_drive`, and no share tool).

**Acceptance evidence.** Red-first fixtures in a temporary tree with fake media metadata: find
by shoot date, plan for a 200-file card dump, one approval, verified copy, an interrupted run
mid-plan with an honest partial report, a changed plan invalidating the old approval, an
unmounted drive, a full destination. `--selftest-fs`, `--selftest-file-index`,
`--selftest-capability-manifest` and `--selftest-store-isolation` pass; PL-05's E and L sets
cover the reads and the approval stop.

**Must not.** Move or delete anything without the approved plan; ask for one approval per file;
read file contents of media to sort them; follow a symlink out of the approved roots; add a
second tool registry, index or receipt store; block a turn while a large copy runs (it is
background work with visible progress).

## PL-10 — The calendars and lists people already use, without Google

**Goal.** A family on iCloud, or anyone who never connects Google, can ask "what's on today?",
"add the dentist Thursday at four" and "put eggs on the grocery list" and get a real answer from
Apple Calendar and Apple Reminders.

**Why.** Found while writing `01-PERSONAS-AND-ICP.md`: the parent and the caregiver often live
in Apple's apps, and the agent's agenda tool reads Google only.

**Current state (verified 2026-10-04).**
- `Sources/NextNotes/Calendar/EventKitCalendarProvider.swift` reads events
  (`events(from:to:)`) for `CalendarService`, which arms meetings and feeds the "Now" block's
  next event (`Sources/NextNotes/Persona/AgentNow.swift`). No agent tool reads it.
- The agent's agenda is `workspace.get_agenda`, run by `WorkspaceToolRunner` through `gws`
  (Google). There is no Apple Reminders read or write anywhere in `Sources/`.
- `--fake-calendar` (`FakeCalendarProvider.swift`) and `--selftest-calendar` exist. EventKit
  was reported "not determined" on the owner's Mac (`AGENTS.md`); not re-verified 2026-10-04
  (TCC.db is unreadable from an agent shell), and no recorded meeting carries an `eventKit`
  provider (all calendar-armed meetings are `google` or a detected call), so no live EventKit
  run is on record.

**Work.**
1. Add calendar read, event add and reminder-list read/add tools through the existing
   `AgentToolRegistry` and `AgentCapabilityManifest`, backed by the existing `CalendarService` /
   EventKit provider — not a second calendar store or cache. Reads are read risk; adding an
   event or a list item waits for approval and shows exactly what will be added and where.
2. When both Google and Apple are connected, answer from both and say which calendar each item
   came from; never merge two into one invented agenda. "Not connected" and "nothing on" stay
   different sentences (the `AgentNow` rule).
3. Ask for the Calendar or Reminders permission at the moment it helps ("to see your family
   calendar, allow Calendar access"), never at launch.

**Acceptance evidence.** Red first on PL-05's H cases with only an Apple calendar fixture; then
pass with `--fake-calendar`-style fixtures for read, add (stops at approval), permission denied
and both-providers; `--selftest-calendar`, `--selftest-capability-manifest`,
`--selftest-ui-strings` and `--selftest-store-isolation` pass; one attended run on a real
iCloud calendar.

**Must not.** Add a calendar store, sync job or second scheduler; write to any calendar or list
without approval; request grants up front; read reminders or events into memory beyond the turn
that needed them.
