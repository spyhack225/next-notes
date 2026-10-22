# The personal agent

> **Historical model assumptions — revised 2026-09-30:** this completed plan/audit
> preserves its dated measurements and implementation history. For new work, follow
> the [independent-role/shared-file contract](../in-progress/SHARED-BRAIN/00-README.md): Meetings, Agent and cleanup
> may use different appropriate models; exact verified artifacts are reused, with
> workload-specific consent and request ownership. Agent-only file selection,
> universal model defaults and deletion based only on the Agent are superseded.
> MiniCPM cleanup + Apple guard/fallback is concurrent work, not evidence that this
> historical build used it. Re-measure quality/latency on the actual current engine.

An Agent that has a character you chose, remembers what matters about you, does things on a
schedule without being asked twice, and can answer questions across everything this app has
ever recorded — with citations that jump back to the second of the recording a claim came
from.

This document is the plan. It covers four capabilities that share one agent, one tool
catalogue, one permission model and one privacy rule:

| Part | Capability | One-line promise |
|---|---|---|
| **1** | Personality | the Agent sounds like someone, and you decide who |
| **2** | Memory | it remembers you across days, and you can see and undo every memory |
| **3** | Routines | reminders, recurring jobs and "after every meeting…" triggers |
| **4** | The second brain | search and ask across every transcript, note and conversation |

It was previously `SECOND-BRAIN.md`; Part 4 is that plan, lightly updated. It is macOS-only;
`windows/` is still dictation and nothing here is in scope there.

Parts 1–3 were designed against two open-source agents that already ship these features —
[OpenClaw](https://github.com/openclaw/openclaw) and
[Hermes Agent](https://github.com/nousresearch/hermes-agent) — and against eight weeks of a
real OpenClaw workspace used as a business-operations agent (kept in
`roadmap/references/serge-openclaw-mem/`). What was taken from each, and what was not, is
called out where it applies. Neither is adoptable as a runtime: one is a TypeScript gateway,
the other Python, and both are server-shaped.

> This plan lives in `roadmap/`, which is git-ignored and local only. Plans do not go in
> `docs/`: that folder is the published website.

---

## Decisions already made

Settled on 2026-09-16. Build to these; do not re-open them without a reason.

1. **Memories save automatically.** No permission prompt. Every memory is listed in Settings
   with its source and a Forget button, and when the Agent saves one during a conversation it
   says so out loud.
2. **The persona is free text.** A file seeded from a base preset, which the user edits freely.
   Not a fixed picker of personalities.
3. **Background work may use the local model or the cloud.** Memory review and routines run on
   Qwen when it is available and idle, and on OpenRouter otherwise, subject to a setting.

## Decisions still open

Each has a recommended default; the plan below is written against the recommendation.

| Question | Recommended | Why |
|---|---|---|
| Can an unattended routine send or change things? | **No — it drafts, and a notification asks you to approve** | Nobody is present to catch a wrong action; a draft costs one click |
| Launch at login? | **On, once the first routine exists** | Without it, every schedule silently stops when the app is not running |
| May a routine speak without an open voice session? | **Only if you are at the Mac, no meeting is recording and no call is active** | A spoken reminder into an empty room is useless; into a call it is a disaster |

---

## Where it stands today

Read from source on **2026-09-17**. Paths are under `Sources/NextNotes/`. Knowledge features stay
**off by default** (`knowledgeIndexEnabled`, `knowledgeGraphEnabled`, …).

### Parts 1–3 — shipped in tree

| Phase | Status | Where / how to verify |
|---|---|---|
| **P1** Persona | **Done** | `Persona/PersonaStore.swift`, `AgentPromptContext.swift`, Settings → Persona; `--selftest-persona` |
| **M1** Memory entries + tools | **Done** | `Memory/NextMemory.swift`, `MemoryTools.swift`, `MemoryGuard.swift`; `--selftest-memory` |
| **R1** Reminders / schedules | **Done** | `Agent/Schedules/*`; `--selftest-schedule` |
| **M2** Session + memory review | **Done** | `AgentSessionBoundary`, `MemoryReviewer`; `--selftest-memory-review` |
| **R2** Routines (draft writes) | **Done** | `ScheduledRunner`, Routines UI; `--selftest-routine-authority` |
| **R3** Triggers | **Done** | notes-ready / meeting-starting / call-started wired through the scheduler |

### Part 4 — second brain

| Phase | Status | Where / how to verify |
|---|---|---|
| **A** Chunked SQLite + Search | **Done** | `KnowledgeStore`, `KnowledgeIndexer`, `KnowledgeSearchView`; `--selftest-index`, `--selftest-search` |
| **B** Embeddings + hybrid RRF | **Done** | `EmbeddingRuntime`, `StaticEmbedder`, `HybridSearch`; `--selftest-embed`, gold set in `--selftest-search --gold` |
| **E** Ask + knowledge tools | **Done** | `AskView`, `KnowledgeTools` (`search_knowledge` / `expand_node` / `timeline`); `--selftest-ask` |
| **C** Extraction + decision threads | **Done in code** | `Extractor`, `Ontology`, `GraphStore`, `DecisionThreadView`, `.extracting` status; `--selftest-extract` |
| **D** Entity resolution | **Done** | `EntityResolver`, `PersonResolutionStore` / `PersonResolutionService`, `SpeakerVoicePrints`, `MergePeopleSheet` (from Decisions → People); `--selftest-resolve` |
| **F** Local graph + person timeline | **Done** | `LocalGraphView`, `PersonTimelineView`, `KnowledgeGraphPane` (Search toolbar → Graph); `ForceLayout`; `--selftest-graph-layout` |
| **G** Global force graph | **Done as navigation** | `GlobalGraphView` is the Graph pane's *Library overview* — click a node to open its local neighbourhood. Not a decorative hairball beside Search. |

### Eval / corpus caveats (honest)

- **Meeting corpus is still thin** on the development machine (a handful of meetings, often without
  real attendees or system-audio “Others”). Phases **C** and **D** compile and pass fixture
  self-tests; they have **not** been proven on “100 meetings / hand-labelled person set ≥ 0.95
  precision” against a real library.
- **Gold-set retrieval bars** (Phase B recall@10 margin, Ask claim-contains) exist as
  `--selftest-search --gold` / `--selftest-ask` scaffolding; treat measured numbers as
  provisional until the library and labelled questions grow.
- **Qwen3.5-4B** and live Workspace writes remain unproven here — extraction and Ask fall back
  to Apple Foundation Models when Qwen is absent; cloud graph reads stay behind
  `knowledgeGraphCloudConsent` (off by default).
- **Voice prints** are written only while the knowledge graph is on, and only for meetings
  diarized after that; older meetings need “Identify again” before voice linking helps.

### What changed since the 2026-09-16 snapshot

The previous “Where it stands today” described Parts 1–3 as absent (hard-coded prompts, memory
skeleton, no scheduler). That is no longer true: persona, memory, schedules/routines, and the
knowledge index/Ask/extract/resolve stack are in the tree. Remaining product risk is **eval on
a real corpus**, not missing phase scaffolding.

---

## Lessons from a real workspace

Eight weeks of a live OpenClaw agent, run hard, with 30-minute heartbeats and a dozen cron
jobs. These are the observations that changed this plan:

1. **A concrete persona works.** The workspace's `SOUL.md` was ~3,500 characters of specific
   behaviour — lead with results, never claim unverified success, have a point of view — and
   the agent held that voice for weeks. Vague adjectives would not have. The base preset
   below copies that shape, compressed for a 4B model.
2. **Memory became a place to store permission.** A standing authorisation to act lived as
   prose in `MEMORY.md`. Anything that can be written to memory can then grant itself
   authority. **Here, memory never grants permission** — grants live in
   `permission-grants.json` and are created only by the user.
3. **Memory mixed three different things.** Facts about the person, facts about the agent's
   own tooling, and the state of a project. Each has a different lifetime; mixing them is why
   the file needed a manual cleanup ritual. Here they are separate kinds with separate budgets.
4. **Work output flooded the memory folder.** ~140 action artefacts landed in `memory/` in
   three weeks, while the daily notes the agent was supposed to curate stopped after one week.
   **Routine output is run history, not memory.** The memory review reads it; it is not
   indexed as memory.
5. **Model-maintained state drifts.** The heartbeat's state file grew duplicate keys for the
   same check (`cronList`, `cron_list`) and was once overwritten empty mid-run and rebuilt from
   context. **Scheduler state is owned by code.** The model receives it and never writes it.
6. **Automation outlived its goal.** Jobs built for a sprint ending on a fixed date were still
   running five weeks later, reporting against the expired objective — the "retire the sprint"
   audit was itself a job, and did not stick. **A routine can carry an end date, and the
   scheduler enforces it.**
7. **Failures repeated instead of escalating.** One job hit four consecutive timeouts; later,
   every 30-minute heartbeat reported the same machine-level blocker for days. **Consecutive
   failures back off, then disable the routine, then send one notification with the fix.**
8. **Hard budgets per run worked.** "Finish within three minutes, at most six tool calls" and
   "quiet outside 08:00–21:00" were the most reliably followed rules in the workspace. Here
   they are scheduler parameters, not prompt text.
9. **Style learned from the user's own writing was the highest-value memory** — and it was
   applied only after explicit approval. That pattern (propose, approve, then it is binding)
   is how learned preferences that change output should work here.

---

# Part 1 — Personality

## One persona file

`~/Library/Application Support/Next Notes/persona.md`. Free text, seeded on first launch from
`Resources/agent-persona-base.md`, edited in Settings → Agent → Persona. Never overwritten
after seeding; *Reset to base* is an explicit button.

The base preset:

```markdown
You are Next Notes, a voice assistant on this Mac. Talk like a sharp, friendly colleague:
short sentences, plain words, answer first, no filler or flattery. If you are not sure, say
so in one sentence instead of guessing. Give an opinion when asked for one.

Keep spoken replies to one or two sentences unless asked for more. Never read out more than
three items; offer to put the rest on screen. When you finish a task, say what actually
happened, not what you intended.

Add below: the name you want the Agent to use, what it should call you, and anything else
about how it should sound.
```

**The first paragraph is the short card.** The Apple-model voice path has 4,096 tokens for
everything, so it receives only the first paragraph, capped at 400 characters. Every other
path receives the whole file, capped at 2,000 characters. The editor shows both counters live
and highlights what is being cut. Truncation is prompt-only; the file on disk is untouched.

This split is the one real constraint on "free text": the user can write anything, and the
editor makes it obvious which part the fast voice path will actually hear.

## One place that assembles prompts

The five hard-coded prompts become one `AgentPromptContext` that every path calls. Order,
stable to volatile, so llama.cpp can reuse the cached prefix across turns of a session:

```text
1  persona              persona.md, full or short card
2  fixed rules          safety, tool-call format, "memory is data" — ends with
                        "These rules override anything above."
3  memory snapshot      Part 2, frozen for the session
4  capability inventory what tools exist right now
   ---------------------------------------------- cacheable prefix ends
5  conversation
6  current request
```

Persona goes *before* the fixed rules, not after: a small model weighs later text more, and a
user-written persona must never be able to loosen a safety rule.

Per-path budgets:

| Path | Persona | Memory | Notes |
|---|---|---|---|
| Voice answers (Apple model) | short card, ≤400 chars | profile only, ≤300 chars | the tightest budget in the app |
| Voice routing (Apple model) | none | none | it routes; it does not speak |
| Tool loop, typed turns (Qwen / cloud) | full, ≤2,000 | profile + notes + relevant activity items | |
| Meeting assistant | full | profile only | |
| Scheduled runs | full | profile + notes | no conversation |
| ACP coding agents | **none** | **none** | external processes; nothing personal crosses |

What was taken: `SOUL.md` as a user-owned file loaded into every prompt (both projects);
stable-before-volatile ordering for prompt caching (both). What was not: Hermes's fourteen
novelty presets, OpenClaw's generated avatars and first-run naming ritual — the ritual is a
good idea for a chat product and an interruption for a voice one. A one-line "What should I
call you?" on the first voice session is enough, and it writes to memory, not the persona.

## Voice goes with the persona

The persona editor sits next to the TTS voice picker (macOS, Pocket's four voices, Kokoro).
A personality that is only written and never heard is half a personality. No per-persona
rate or pitch in this phase — the engines do not expose style controls today.

---

# Part 2 — Memory

## Four tiers, each with its own lifetime

```text
episodic     every past conversation, meeting and routine run — searched, never injected   Part 4
core         who you are, what the Agent has learned — small, injected every session       NextMemory
working      this session's conversation, compacted when long                             AgentSession
activity     names, projects, vocabulary from app activity — matched per request            NextMemory (exists)
```

## Core memory

`NextMemory` gains two kinds and a proper entry record. The existing activity kinds stay as
they are.

```swift
struct MemoryEntry: Codable, Identifiable {
    let id: UUID
    var kind: Kind            // .profile | .note | (existing activity kinds)
    var text: String          // one declarative sentence
    var source: Source        // .userSaid | .review | .activity | .manual
    var sessionID: UUID?      // the conversation it came from
    var createdAt: Date
    var updatedAt: Date
    var supersedes: UUID?     // the entry this replaced, kept for undo
}
```

- **`profile`** — facts about the user. "Serge prefers answers under two sentences."
  Budget 1,200 characters.
- **`note`** — what the Agent has learned about working here. "Meeting notes for the Monday
  standup go to the team Drive folder." Budget 2,000 characters.

Budgets are characters, not tokens, so they do not change with the model.

**Entries are declarative facts, not imperatives.** Hermes found that "Always answer briefly"
stored in memory is re-read in later sessions as a command in the wrong context; "The user
prefers brief answers" is weighed as information. It also fits the existing rule that memory
is rendered as JSON data.

**A changed fact replaces the old one.** It is not appended beside it. OpenClaw measured that
a stale preference left next to its replacement keeps getting followed. The old entry is kept
under `supersedes` so Forget and undo still work.

**The snapshot is frozen per session.** Core memory is read once when a session starts and
not rebuilt mid-session, so the cached prompt prefix survives. A memory saved during the
session is already in the conversation; the snapshot picks it up at the next session or after
compaction.

## Tools

A new `memory` namespace in `AgentTool.Namespace`:

| Tool | Arguments | Risk |
|---|---|---|
| `memory.remember` | `kind` (profile \| note), `text` | modify, auto-allowed |
| `memory.update` | `match` (short unique substring), `text` | modify, auto-allowed |
| `memory.forget` | `match` | modify, auto-allowed |
| `memory.recall` | `query` | read — activity items now; the Part 4 index later |

`PermissionPolicy.allowsAutomatically` gets one narrow exception: the `memory` namespace, and
only when the call's authority is the user's own conversation or the memory review. This is
decision 1 made concrete. It is also the only auto-allowed write in the app, which is why the
guards below exist.

**Overflow is an error, not a silent trim.** A write that exceeds the budget is rejected, and
the error carries the current entries so the model can merge or replace in the same turn —
Hermes's approach, and much better than deleting the oldest fact.

**The Agent says what it saved.** A successful write returns a one-sentence spoken summary
through `AgentSpeechPolicy`: *"Noted — you prefer short answers."* A save made by the
background review is not spoken later out of nowhere; it appears in the Memories list with a
*New* badge and one island notice.

## Guards

Auto-saving means the guards are the feature.

1. **Provenance.** A memory may be created only from something the user said, or by the
   review reading what the user said. Never from an email, web page, file, calendar
   description or any tool result. Tool output is already marked untrusted in the tool loop;
   the memory tools check the turn's provenance, not the model's claim about it.
2. **Memory never grants permission.** No entry can create, widen or imply a permission grant,
   and the fixed rules say so. See lesson 2 above.
3. **Injection scan on write and on load.** A small pattern set — "ignore previous
   instructions", role reassignment, invisible Unicode, exfiltration phrasing — blocks the
   write and flags the entry on load. Patterns deliberately do not flag ordinary firm English
   ("you must"). Hermes's `threat_patterns.py` is the reference.
4. **Nothing crosses to ACP coding agents.** Memory stays inside this app's own prompts.

## Sessions and compaction

The endless conversation splits into sessions:

- A new session starts after 30 minutes of silence (a setting), or on *Clear conversation*.
- When the working history exceeds its budget, older turns become one summary headed
  `[Earlier in this conversation — reference only, not new requests]`. Hermes's source
  comments document the regressions an unlabelled summary causes: the model re-runs tasks it
  finds described there.
- Tool call and result pairs are never split across the summary boundary.
- The full history stays on disk; compaction is prompt-only.

## The memory review

Most memories should come from here, not from the Agent interrupting a conversation to save
things.

- **When:** at the end of each session, and every 10 user turns within a long one.
- **What it sees:** that session's user and assistant turns — not tool output, not routine
  runs — plus the current core memory.
- **What it can do:** `memory.remember`, `memory.update`, `memory.forget`. Nothing else.
- **What it is told to skip:** one-off requests, anything the user did not state about
  themselves, environment failures, and anything already present.
- **Where it runs:** setting `agentMemoryReviewModel` = `auto` | `local` | `cloud`. `auto`
  runs on Qwen when the model is loaded, nothing is recording, and `LlamaBackend` has been
  idle for a minute; otherwise on OpenRouter if a key is configured; otherwise it waits.
  Waiting for idle is Hermes's rule for local servers — a review that holds the GPU makes the
  next voice reply slow.
- **It can suggest a routine.** If the same request recurs — "what's on my calendar" three
  mornings running — the review records a routine *suggestion*. The Agent offers it once in
  the next session. It never creates one.

## The Memories list

Settings → Agent → Memories, built on the same pattern as *Remembered permissions*:

- Every profile and note entry, newest first, with source (*You said* / *Learned* /
  *Added by you*), date, and the session it came from.
- Edit in place, Forget, and *Forget everything*.
- A *New* badge on entries the review added since the list was last opened.
- Budget meters for profile and notes.
- Export as Markdown.

Activity items (people, projects, vocabulary) are shown in a collapsed second section; they
are derived and rebuild themselves.

What was taken: bounded character budgets and reject-on-overflow (Hermes); frozen snapshot
per session (Hermes); declarative entries (Hermes); supersede in place (OpenClaw); background
review deferred until idle on local models (Hermes); provenance gating, and never promoting
untrusted content (OpenClaw). What was not: OpenClaw's nightly "dreaming" rewrite of the whole
memory file — consolidation happens only when a budget is actually exceeded; Honcho-style
cloud user modelling — it sends the conversation to a third party by design; and agent-written
skills — a later idea, once memory has proven itself.

---

# Part 3 — Routines

Three kinds of scheduled work. OpenClaw arrived at the same split after first running
everything through its heartbeat and then removing that path.

| Kind | Example | Runs tools? | Permission changes? |
|---|---|---|---|
| **Reminder** | "Remind me at five to call the bank." "Every weekday at 9, tell me to stand up." | no | none |
| **Routine** | "Every Monday at 8, summarise last week's meetings." | yes | yes — unattended authority |
| **Trigger** | "After every meeting, draft the follow-up email." "When a call starts, pull up my notes on them." | yes | same as routine |

There is no heartbeat. A periodic "check whether anything needs doing" turn is the most
expensive and least predictable way to run a schedule, and the real workspace above spent
most of its heartbeats reporting the same state.

## The schedule record

`agent-schedules.json`, written atomically like `agent-tasks.json`, and deliberately separate
from it — the task store fails every unfinished task on launch, which is correct for tasks
and fatal for schedules.

```swift
struct AgentSchedule: Codable, Identifiable {
    let id: UUID
    var kind: Kind                 // .reminder | .routine | .trigger
    var title: String              // "Monday meeting summary"
    var plainEnglish: String       // the sentence the user confirmed
    var prompt: String             // self-contained instructions for the run
    var when: When?                // reminders and routines
    var trigger: Trigger?          // triggers
    var endsAt: Date?              // enforced by the scheduler — lesson 6
    var allowedTools: [String]     // fixed at creation — see authority below
    var model: ModelChoice         // .auto | .local | .cloud
    var delivery: Delivery         // .notify | .notifyAndSpeak
    var budget: Budget             // max seconds, max tool calls — lesson 8
    var enabled: Bool
    var createdAt: Date
    var createdInSession: UUID?
    // Owned by the scheduler. Never written by a model — lesson 5.
    var nextRunAt: Date?
    var lastRun: RunSummary?
    var consecutiveFailures: Int
}

struct When: Codable {
    var repeatRule: Repeat         // .once(Date) | .daily | .weekdays | .weekly([Weekday]) | .monthly(day: Int)
    var time: LocalTime            // hour, minute
    var timeZone: String           // IANA identifier captured at creation
}

enum Trigger: Codable {
    case meetingNotesReady(filter: String?)
    case meetingStarting(leadMinutes: Int, filter: String?)
    case callStarted
}
```

**No cron expressions.** A 4B model writes wrong cron, and cron has a trap even for people:
when both day-of-month and day-of-week are set, it matches *either*. The model fills
structured fields; `Calendar.nextDate(after:matching:matchingPolicy:)` computes occurrences,
which gets daylight saving right. Wall-clock time plus an IANA zone is stored, never a UTC
instant for a recurring job — both reference projects shipped timezone bugs from getting this
wrong. `.monthly(day: 31)` clamps to the last day of shorter months. Anything the fields
cannot express ("every other Tuesday") is refused in words, not approximated.

## Tools

A `schedule` namespace:

| Tool | Arguments | Risk |
|---|---|---|
| `schedule.list` | — | read |
| `schedule.create` | kind, title, plainEnglish, prompt, when \| trigger, endsAt?, allowedTools, delivery | modify |
| `schedule.update` | id, any field above | modify |
| `schedule.pause` / `schedule.resume` | id | modify |
| `schedule.remove` | id | modify |
| `schedule.run_now` | id | inherits the schedule's authority |

The tool descriptions carry three rules from the reference projects:

- **List before creating.** Update an existing schedule rather than making a near-duplicate.
- **The prompt must stand alone.** The run has no conversation and cannot ask questions.
- **Runs cannot create schedules.** `schedule.*` is never in a run's allowed tools.

## Creating one: confirm the sentence, then test it

The flow OpenClaw converged on, adapted for voice:

1. The user asks. The Agent calls `schedule.list`.
2. The Agent restates it in one sentence, including the tools it will need:
   *"Every Monday at 8 a.m., I'll read last week's meeting notes and put a summary in your
   notifications. OK?"*
3. The user says yes. That confirmation is user authority; `schedule.create` runs under it.
4. **Routines and triggers run once immediately as a test**, visibly. If the test fails, the
   Agent says why and removes the schedule. Reminders skip this.
5. The schedule is saved enabled. A schedule saved disabled "until reviewed" is one nobody
   checks, and it fails silently.

## The scheduler

`AgentScheduler`, shaped exactly like `MeetingScheduler`:

- A 30-second loop plus a pass on `NSWorkspace.didWakeNotification`. `runOnce(now:)` is the
  whole decision and is what the self-test drives with a fake clock.
- **Claim, then dispatch.** `nextRunAt` advances and is saved *before* the run starts, so a
  crash mid-run cannot fire the same slot twice. A run found interrupted on launch is recorded
  as failed once, never replayed.
- **Grace.** A slot found late within `min(max(interval / 2, 2 min), 2 h)` runs late. Beyond
  grace, a recurring schedule's backlog collapses into **one** catch-up run. A one-shot
  reminder found beyond grace is delivered as *Missed: …* — never silently dropped.
- **Every skipped slot is logged with a reason** — asleep, app not running, local model busy,
  quiet hours, budget exceeded. A schedule that fails quietly looks healthy.
- **Failures escalate.** Retry backoff 1 min → 5 → 15 → 60. After 3 consecutive failures,
  one notification with the actual error; after 10, the schedule disables itself and says
  so. Never one notification per failure — lesson 7.
- **`endsAt` is enforced here**, not by a job that is supposed to clean up other jobs.
- **Quiet hours** (default 21:00–08:00, a setting) defer delivery, not the run: the summary is
  ready in the morning.
- **Staggering.** Routines due in the same minute run in sequence, not in parallel. There is
  one Metal GPU.

## Reminders survive the app being closed

When a reminder is created or rescheduled, its next occurrence is also handed to macOS as a
`UNCalendarNotificationTrigger` with a stable identifier. If the app is running when the slot
arrives, the scheduler removes the pending OS request and delivers it itself (so it can be
spoken). If the app is not running, macOS delivers it. On launch the two are reconciled. Only
the next occurrence of each reminder is registered, which keeps well under the operating
system's cap on pending requests.

Routines and triggers cannot do this — they need the app to run tools. That is what launch at
login is for (`SMAppService.mainApp`, open decision 2).

## Running a routine

Each run is a fresh `AgentTask` with source `"scheduled"` and the schedule's id, executed by
the same planned tool loop the voice Agent uses:

- **Context:** persona, core memory snapshot, fixed rules, the schedule's `prompt`, today's
  date and time zone. No conversation.
- **Model:** `auto` checks whether Qwen can run now (loaded or loadable, nothing recording,
  GPU not busy). If not, it uses OpenRouter if configured; if neither, the slot is skipped
  with reason *local model busy* and retried within grace. OpenClaw's rule: probe the local
  model before starting, and report a skip, not a crash.
- **Budget:** default 3 minutes and 8 tool calls; the run stops cleanly at either.
- **Silence:** a run whose final answer is exactly `NOTHING_TO_REPORT` delivers nothing and
  records *ran, nothing to report*. "Tell me if anything in my inbox needs me" should be quiet
  most mornings.
- **Output** goes to run history and, if configured, the Part 4 index as its own source kind
  — never into memory (lesson 4).

## Authority when nobody is there

This is the core change, and it touches `ActionRuntime.swift`, `PermissionPolicy.swift`,
`PermissionGate.swift` and `ACPAgentBackend.swift`.

1. **A new authority, `.scheduled(scheduleID)`.** Not `.user`, not `.background`.
2. **The confirmed sentence defines the ceiling.** `allowedTools` is fixed at creation from
   what the restatement named, and can never exceed what the creating conversation could use.
   A tool outside the list is refused, with the reason recorded.
3. **Observe and read tools inside the list run.** The existing `ActionOrchestrator` rule that
   blocks `.modify` and above for non-user authority stays exactly as it is.
4. **Anything that writes, sends or changes becomes a draft.** The run prepares the action,
   records a receipt in `.waitingPermission`, and ends. A notification — new category
   `agentRoutineApproval`, actions *Review* and *Approve* — carries it. Approving from the
   notification is user authority, and the action executes then. This is open decision 1's
   recommended answer; a per-routine "may send without asking" is a later, explicit opt-in.
5. **Scheduled runs never call `PermissionGate.ask`.** They run with `promptIfNeeded: false`.
   Nothing waits on a person who is not there — Hermes's unattended default is deny-instantly,
   after exactly this hang showed up in their issue tracker.
6. **Close the ACP gap.** `ACPAgentBackend` stops inferring permission from `source !=
   "meeting"`. A scheduled coding-agent task is refused unless the routine explicitly allows
   that harness, and even then it runs without auto-approved permissions.
7. **Every run is audited** in `agent-audit.jsonl` with the schedule id, and every prepared
   action has a receipt. The receipt store already fails closed.

## Delivery, and speaking first

- **Always:** a system notification (new category `agentRoutine`, actions *Open*, *Read
  aloud*, *Snooze*) and an island notice.
- **Spoken, when the schedule asks for it and all of these hold:** the user has touched the
  keyboard or mouse in the last two minutes, no meeting is recording, `CallDetector` reports
  no call, and it is not quiet hours. The text is spoken through the synthesizer directly,
  without opening the microphone. If any condition fails, it is notification-only and *Read
  aloud* is there for later.
- `VoiceAnnouncementQueue` keeps its current behaviour for in-session announcements.

Focus / Do Not Disturb detection is not in this phase; see *Assumed*.

## Triggers

The hooks already exist and only need to publish events the scheduler subscribes to:

| Trigger | Source |
|---|---|
| `meetingNotesReady` | `NotesService` posts notes-ready |
| `meetingStarting` | `MeetingScheduler.armDueEvents`, with its own lead time |
| `callStarted` | `CallDetector`'s change callback |

A trigger run has the same authority, budget, silence and delivery rules as a routine. A
`filter` is plain text matched against the meeting title or attendees. Keyword-triggered
"standing intents" (OpenClaw's `intent` tool) are out of scope.

## The Routines view

Agent window → Routines: every schedule with its plain-English sentence, next run, last
result, and a switch. Tap one for run history — including skipped slots and their reasons —
drafts awaiting approval, *Run now*, *Edit*, *Delete*. Routine suggestions from the memory
review appear at the top with *Set it up* and *Dismiss*.

What was taken: time/event/goal split, fresh session per run, self-contained prompts, silence
token, restate-confirm-test-enable, list before create, no jobs creating jobs, local-model
probe before a run (OpenClaw); claim-before-dispatch, collapsed catch-up, deny-instantly for
unattended writes, schedule-time model capture (Hermes). What was not: cron strings, the
heartbeat, trigger *scripts* that run shell commands unattended (OpenClaw), and webhooks —
there is no server to receive them.

---

# Part 4 — The second brain

A searchable, queryable, connected memory across every transcript, every set of meeting notes,
every Agent conversation and — optionally — every dictation. Ask it a question in English, get
an answer with citations that jump back to the second of the recording the claim came from.

This is the *episodic* tier from Part 2: past conversations are indexed here, and
`memory.recall` searches this index once it exists.

## The precondition, before any of it

**There are two meetings on this machine.** Both have `attendees: []`, one is an untitled
detected WhatsApp call, and `runs.jsonl` holds 62 dictations. Per `README.md`, the
system-audio tap has never produced an "Others" track, no calendar account has ever been
connected, and no Workspace write has ever run.

A knowledge graph is a machine for finding non-obvious connections across a large corpus.
At two meetings it has nothing to connect, and — worse — there is no way to tell a good
retrieval design from a bad one, because every query returns everything.

So the ordering rule for this part: **Phase A and B are worth building now because they make
today's search better on their own. Phases C and D should not start until the library holds
100+ real meetings with real attendees.** The prerequisite is not code, it is corpus.

Parts 1–3 have no such precondition — and Agent conversations, once sessions exist, are a
corpus that grows every day whether or not meeting capture works yet.

---

## Shape

Seven layers. Each one is useful without the one above it, which is the only reason this is
shippable in pieces rather than as an eighteen-month rewrite. Only the top two draw a graph
at all, and they are the last things built — search, ask and the decision thread all ship
below them.

```text
G  global graph          every node on one canvas; optional, and honestly decorative
F  local graph, timeline one node's neighbourhood; one person against time
E  ask                   retrieve -> rerank -> answer with citations
D  entity resolution     one person is one node, across 200 meetings
C  extraction            decisions, actions, questions, people as typed rows
B  embeddings            dense vectors, hybrid with FTS5
A  the index             chunks in SQLite, FTS5, crash-consistent
   ---------------------------------------------------------------
   meeting.json / transcript.json / notes.md / agent sessions   (what exists today)
```

The store on disk stays the source of truth. Everything from A upward is **derived and
disposable** — deletable at any time and rebuildable from the meeting folders and session
files. That is not a nicety; it is what makes every schema change in this document survivable.

---

## A. The index

### What is wrong with what exists

`MeetingStore.matches(_:query:)` is `localizedCaseInsensitiveContains` over one concatenated
string per meeting, built by `prepareSearchIndex()` and held entirely in RAM. It is honest
and it works at fifty meetings. At five hundred it is a frozen window and several hundred
megabytes of transcript text resident for a feature nobody is using at that moment.

It also answers the wrong question. It tells you *which meeting* matched. Nobody wants a
meeting; they want the ninety seconds inside it where the thing was said.

### The unit is a chunk, not a meeting

A chunk is one retrievable passage:

- **transcript chunks** — a run of consecutive `TranscriptSegment`s from a single speaker,
  cut at the first pause after ~150 words, hard cut at ~300. Carries `meeting_id`,
  `start`/`end` in seconds, `speaker`, `source` (mic/system).
- **notes chunks** — one bullet or one paragraph under one of the five fixed headings.
  Carries the heading, which is what later makes `Decisions` a node type for free.
- **conversation chunks** — one user turn with the Agent's reply, from ended sessions only.
  Tool output is excluded. On by default once Part 2 sessions exist.
- **routine chunks** — one routine run's final output. Off by default.
- **dictation chunks** — one `DictationRun`, whole. Off by default; high volume, low signal.

Chunks overlap by one segment. Overlap costs storage and buys the case where the answer
straddles a boundary, which is most of them.

### Schema

One file: `~/Library/Application Support/Next Notes/knowledge.sqlite`. Separate from the
meeting folders on purpose — a corrupt index must never be able to take a transcript with
it, and `rm knowledge.sqlite` must be a complete, safe repair.

```sql
CREATE TABLE chunk (
  id           INTEGER PRIMARY KEY,
  source_kind  TEXT NOT NULL,        -- 'transcript' | 'notes' | 'conversation' | 'routine' | 'dictation'
  source_id    TEXT NOT NULL,        -- meeting, session, schedule run, or dictation run UUID
  generation   INTEGER NOT NULL,     -- bumped when the source is rewritten
  ordinal      INTEGER NOT NULL,     -- position within the source
  text         TEXT NOT NULL,
  start_time   REAL,                 -- seconds into the recording, transcript only
  end_time     REAL,
  speaker      TEXT,
  heading      TEXT,                 -- 'Decisions', 'Action items', ... notes only
  occurred_at  INTEGER NOT NULL,     -- meeting start + start_time, or turn time; unix seconds
  UNIQUE (source_kind, source_id, generation, ordinal)
);

CREATE INDEX chunk_source ON chunk(source_kind, source_id, generation);
CREATE INDEX chunk_time   ON chunk(occurred_at);

CREATE VIRTUAL TABLE chunk_fts USING fts5(
  text,
  content='chunk',
  content_rowid='id',
  tokenize='porter unicode61'
);

CREATE TABLE embedding (
  chunk_id INTEGER PRIMARY KEY REFERENCES chunk(id) ON DELETE CASCADE,
  model    TEXT NOT NULL,           -- 'embeddinggemma-300m@256' etc
  dims     INTEGER NOT NULL,
  vector   BLOB NOT NULL            -- dims * 4 bytes, little-endian float32, L2-normalised
);

CREATE TABLE index_state (
  source_kind TEXT NOT NULL,
  source_id   TEXT NOT NULL,
  generation  INTEGER NOT NULL,
  indexed_at  INTEGER NOT NULL,
  embedded    INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (source_kind, source_id)
);
```

Two things about that schema that look like bugs and are not, both confirmed by running it
against system sqlite 3.45.3:

- **`ON DELETE CASCADE` does nothing unless `PRAGMA foreign_keys = ON` is set on every
  connection.** SQLite defaults it off, and it is per-connection, not per-database. Without
  it, deleting a chunk silently orphans its embedding row and searches start returning
  vectors for text that no longer exists.
- **An external-content FTS5 table (`content='chunk'`) is not maintained for you.** Inserts,
  updates and deletes on `chunk` must be mirrored into `chunk_fts` — by triggers, or by doing
  both writes inside the same transaction. A missed mirror is invisible: the row is
  searchable by SQL and not by search.

`generation` is the whole idempotency story. **Regenerate** rewrites `notes.md`; diarization
rewrites `transcript.json` with new speakers. Both bump the generation, both insert a fresh
set of chunks in one transaction, and the previous generation's rows are deleted in the same
transaction. There is never a moment where a search can see two generations of the same
meeting, and a crash mid-write leaves the old generation intact.

Deleting a meeting deletes its chunks. Today deletion is `rm -rf` of a directory; it has to
also delete by `source_id`, or the index confidently cites a meeting that no longer exists.
The same holds for *Clear conversation* and *Forget everything*: they delete the matching
conversation chunks.

### Why SQLite and not a vector database

Verified on this machine: the system `sqlite3` is 3.45.3 with `ENABLE_FTS5` compiled in, and
`SQLITE_OMIT_LOAD_EXTENSION` is absent. `libsqlite3` is already linked — `WisprReader.swift`
opens Wispr Flow's database read-only through it. So FTS5 costs nothing: no dependency, no
binary to sign, no notarization surface, no Swift 6 concurrency wrapper.

Both reference agents landed on the same answer: OpenClaw indexes memory in SQLite FTS5 plus
vectors, and Hermes searches past sessions with SQLite FTS5.

The alternatives were considered and rejected. Reasons are at the end of this document.

### Search, before there are any vectors

FTS5 BM25 alone, ranked, with snippets. This is already a large improvement over substring
matching — it ranks, it stems, and it finds the passage rather than the meeting. Phase A
ships as a user-visible feature with no model download and no embeddings at all.

---

## B. Embeddings

### The framework is already here

`llama.xcframework` b10621 — already a `binaryTarget` in `Package.swift`, already signed
into the bundle — exposes the complete embedding API. From
`llama.framework/Versions/A/Headers/llama.h` in the installed app:

```c
LLAMA_POOLING_TYPE_MEAN = 1,  CLS = 2,  LAST = 3,  RANK = 4
llama_set_embeddings(struct llama_context * ctx, bool embeddings);
llama_encode(...);
llama_get_embeddings_seq(struct llama_context * ctx, llama_seq_id seq_id);
```

**No new dependency is needed to embed text.** `POOLING_TYPE_RANK` also means a cross-encoder
reranker is available through the same framework later, which is the single largest quality
lever in hybrid retrieval.

`NotesModelRuntime` is a decode loop and cannot be reused directly — embedding needs
`llama_set_embeddings(ctx, true)` and a pooling type set at context creation. `EmbeddingRuntime`
is a sibling actor with the same lifecycle shape: lazy load, idle unload, `LlamaBackend`
arbitration.

### Which model

Two tiers, the same pattern the notes provider already uses:

| | Disk | Resident | Runs on | Retrieval quality |
|---|---|---|---|---|
| `potion-retrieval-32M` (Model2Vec) | ~30 MB | ~30 MB | CPU, no forward pass | ~82% of `all-MiniLM-L6-v2` |
| **`EmbeddingGemma-300M` QAT** | ~200 MB | <200 MB | ANE (CoreML) or GPU (GGUF) | best open multilingual under 500M on MTEB |
| `Qwen3-Embedding-0.6B` | ~600 MB Q8 | ~600 MB | GPU | best of the three, most contention |

**Ship EmbeddingGemma-300M truncated to 256 dimensions.** It is Matryoshka-trained, so
768 → 256 costs little recall and cuts the index to a third. Potion is the instant-on path so
search works before any download completes — the same two-tier shape as Qwen vs Apple
Foundation Models for notes. OpenClaw's local embedding option is the same model family.

Do **not** build on Apple's `NaturalLanguage` embeddings. `NLEmbedding.sentenceEmbedding`
ranks lexical distractors above correct answers and scores negations above true paraphrases;
`NLContextualEmbedding` will not load outside an app bundle; and the Foundation Models
framework exposes no embedding API at all.

### The memory question is really a compute-unit question

The contended resource on an M3/16 GB is the **Metal GPU**, not RAM — which is exactly why
`LlamaBackend` exists to arbitrate it. Qwen3.5-4B Q4_K_M is 2.74 GB of weights plus a KV
cache that `ensureContext(promptTokens:maxTokens:)` sizes to the request. Adding a second
GPU tenant means queueing behind notes generation — and now also behind the memory review and
routines from Parts 2 and 3.

Three rules, use all three:

1. **Put the embedder on a different unit.** The Apple Neural Engine is separate silicon; a
   CoreML embedding model there costs no GPU memory and never queues behind Qwen. Potion runs
   on the CPU and costs nothing at all.
2. **Never hold both at once.** Embedding is a batch backfill, not an interactive path. The
   notes model already frees itself ten minutes after last use — that idle window is when the
   indexer runs. Sequential, not concurrent.
3. **Shrink the vectors, not only the model.** 37,000 chunks at 768 dims float32 is 115 MB
   resident; at 256 dims it is 38 MB.

### Budget, at 500 meetings

| | |
|---|---|
| Qwen3.5-4B Q4_K_M weights | 2.74 GB, only while generating |
| Qwen KV cache | sized per request, not per 32K |
| Parakeet CoreML + FluidAudio diarizer | already resident during meetings |
| EmbeddingGemma-300M QAT | <200 MB, only while indexing |
| Vector set, 37k chunks @ 256 dims | 38 MB |
| `knowledge.sqlite` incl. FTS5 | ~250 MB for 500 meetings of text |

Peak is never the sum: the notes model and the embedder are never loaded together.

### Brute force is the correct search

37,000 × 256 is 9.5M multiply-adds per query — one `cblas_sgemv` through Accelerate, under a
millisecond on an M3, and **exact**. ANN indexes exist because brute force gets slow, and it
does not get slow until roughly a million vectors. At one chunk per ninety seconds of speech
that is about 13,000 recorded meetings.

When that day comes, the upgrade is `sqlite-vec` — a single MIT-licensed C file compiled
into the target and registered with `sqlite3_auto_extension`. No server, no Python, same
schema, same file. Put search behind a protocol now so it drops in without a migration.

---

## Retrieval

Hybrid, always. Pure vector search underperforms badly on names, project codenames and
jargon — which is most of what meeting notes contain. Pure BM25 misses paraphrase, which is
most of how people ask questions.

1. FTS5 BM25, top 50.
2. Cosine over the vector set, top 50.
3. Fuse with reciprocal rank fusion, `k = 60`.
4. Optional rerank of the top 20 with a cross-encoder through `POOLING_TYPE_RANK`.
5. Filters applied as SQL, not post-hoc: date range, speaker, meeting, heading, source kind.
6. For conversation chunks only, a mild recency weight. OpenClaw uses a 30-day half-life on
   episodic notes; meeting transcripts get none, because an old decision is still a decision.

RRF is chosen over score normalisation because BM25 and cosine scores are not commensurable
and every attempt to make them so needs tuning per corpus.

---

## C. The graph

### An ontology file, not whatever the model felt like emitting

`Resources/knowledge-ontology.yaml` declares the node types, their fields, and the legal edge
types between them. Extraction validates against it and drops what does not fit. This is the
one idea worth taking from `sensein/meetgraph`, and it is what keeps an extracted graph from
turning to mush after a hundred meetings.

### Node types, and where each actually comes from

| Node | Source | Cost |
|---|---|---|
| **Meeting** | `meeting.json` | free, already a record |
| **Person** | `Meeting.attendees`, `speakerNames` | free once calendars are connected |
| **Decision** | notes heading `Decisions` | cheap, already a heading |
| **ActionItem** | notes heading `Action items`, with assignee + due | cheap |
| **OpenQuestion** | notes heading `Open questions` | cheap |
| **Artifact** | `Meeting.agentActions` — Docs, events, messages the agent made | free, links already recorded |
| **Topic** | LLM extraction + clustering | expensive, and where hallucinated nodes come from |

Five of seven are nearly free because the pipeline already produces them. **Topic is the only
speculative one and should be last.**

An `ActionItem` owned by the user with a due date is also the natural source of a reminder
*suggestion* in Part 3 — offered, never created.

### Stop scraping markdown

`NotesGenerator` writes markdown under five fixed headings and everything downstream
re-parses it with string matching. Instead, emit JSON alongside the markdown using
llama.cpp's GBNF grammar support — the framework has it, the Swift wrapper does not expose it
yet. Constrained decoding turns "usually parseable" into "parses or the generation failed",
which is the difference between a graph and a pile of near-misses.

The same grammar support makes Part 2's memory review and Part 3's schedule creation more
reliable on a 4B model; expose it once, use it three times.

`notes.json` lands beside `notes.md` in the meeting folder, same generation counter.

### Bi-temporal edges

Every edge carries four timestamps:

```
observed_at   when the meeting that stated this happened
valid_from    when the fact became true
valid_to      when it stopped being true (null = still true)
source_chunk  the chunk this was extracted from
```

Decisions get reversed three weeks later. A graph that cannot represent "we decided X, then
un-decided it" will state the wrong thing with total confidence, which is worse than not
having a graph. This is the one idea worth taking from Graphiti/Zep; the frameworks
themselves are Python and server-shaped and are not adoptable here.

`source_chunk` on every edge is non-negotiable — it is what makes an answer citable, and what
lets a wrong edge be traced to the sentence that caused it.

### A new pipeline stage

`MeetingStatus` gains `.extracting`, between `.summarizing` and `.done`. It is persisted like
every other state, so a crash during extraction is visible as exactly that. At the measured
~13.7 tok/s on this hardware, one extraction pass over a 45-minute meeting is a few minutes
of background work — acceptable because it is queued, idempotent, and yields to recording.

---

## D. Entity resolution

**This is the layer that decides whether this is a second brain or a pile of duplicates**, it
is more work than the extraction, and it is where projects like this die.

"Serge", "serge.kadjo@…", "S.K." and "Speaker 2" must become one node.

1. **Block** on normalised name and email domain — cheap, kills 90% of the comparison space.
2. **Score** within blocks: string distance, email match, co-attendance, embedding similarity
   of the surrounding context.
3. **Voice.** `MeetingDiarizer` already gets a 256-float speaker embedding per turn from
   FluidAudio. That means an unnamed *Speaker 2* in one meeting can be linked by voice to a
   named person in another, offline. Almost nothing on the market does this locally, and it is
   the strongest edge type available here.
4. **LLM tiebreak** only for the ambiguous middle band, never for the confident ends.

Two hard requirements:

- **Never delete on merge.** A `merged_into` column, and the loser row stays. Un-merging must
  be a one-row update.
- **A visible merge UI.** It will be wrong sometimes, and a wrong merge that the user cannot
  see or undo is how trust in the whole feature ends.

Resolved people also replace NextMemory's keyword-matched `person` activity items: one node,
one memory.

---

## E. Ask

Reuse the agent machinery rather than building a second one. `AgentService` already plans with
graded tools and `WorkspaceToolRunner` already executes them; three new **read-class** tools
join the catalogue, and `memory.recall` from Part 2 becomes a thin wrapper over the first:

| Tool | Arguments |
|---|---|
| `search_knowledge` | query, date range, speaker, meeting, heading, source kind, limit |
| `expand_node` | node id, edge types, depth |
| `timeline` | entity id, date range |

Read-class means they run while the agent plans, behind *Let it look things up* — the same
gate that already governs `search_email` and `read_doc`. Nothing in this feature writes
anything, so nothing here needs an approval button. They are also safe to allow in routines:
"every Friday, tell me which action items from this week's meetings are still open."

The answer path: retrieve → rerank → stuff top-k with citations → generate. Every claim
carries a chunk id, and the UI resolves that to a meeting and a timestamp. `TranscriptView`
already positions by seconds, so "jump to where this was said" is a scroll, not a search.

**The binding constraint is latency, not retrieval.** Qwen3.5-4B's context caps a single pass
at roughly 20 chunks. Multi-hop questions — "what did we decide about the pricing model over
the last quarter" — need 2–4 iterative retrieval round-trips, which at 13.7 tok/s is 30–60
seconds. Design the UI for a job that streams and can be cancelled, not for a search field.
In voice, the Agent says it is looking and answers when done, as a background task.

---

## F. The views

The graph is not one screen. It is four, they belong to different phases, and two of them do
not draw a graph at all. This was settled by building all four as working prototypes and
running each at 12, 45 and 180 meetings rather than by arguing about it:
`https://claude.ai/code/artifact/0ad9de12-74b7-4be8-8850-594ae6d8ad15`.

### Search first, graph as the filter rail — ships in Phase A

Results are the interface; node types are demoted to facets down a left rail, with counts.
This needs no graph, no embeddings and no extraction — FTS5 and the chunk table give you the
whole screen, and the facets light up later as extraction fills the node types in. **It is
the only one of the four that is useful with two meetings in the library**, which is the
situation this repo is actually in.

### Local graph, one hop at a time — Phase F

One focus node and its immediate neighbours; click any node to re-centre on it. The node
count on screen is bounded by one node's degree, not by the size of the library, so it reads
identically at 12 meetings and at 180.

Three interaction primitives, all conventional and all worth copying: hovering isolates a
neighbourhood while everything else alpha-blends into the background; clicking a node expands
its neighbours and clicking again collapses them; and a selection made in one view updates
the others instead of opening a new context.

### Person timeline — Phase F, the same deliverable

The same edges drawn against time instead of against each other: every meeting a person
attended, newest first, each with the decisions and action items it produced and the ones
that person owns marked.

A person's edges are almost always chronological. You want to know what someone has been
involved in *lately*, not their betweenness centrality — and a timeline answers that at a
glance where a force graph never does. It shares a data model and a selection with the local
graph, which is why the two are one piece of work rather than two.

### Decision thread — Phase C, once extraction exists

One decision followed across meetings, including the day it was reversed: superseded claims
struck through, each row carrying its meeting, its timestamp and who said it. This is the
bi-temporal model made visible, and it is the most distinctive screen in the plan precisely
because it needs `valid_from`/`valid_to` on an edge rather than a plain link.

### Global force graph — last, and optional

Every node on one canvas. Build it when everything above works and you want a launch
screenshot.

The prototype settles what the first draft of this document only asserted. At 12 meetings it
is legible and rather pleasant. At 180 it is a uniform hairball, because a force layout
optimises for edge length and not for whatever you were looking for. The published criticism
is exactly this — it is a topological map of your connections rather than an operational view
of your work, showing connections but not priority, status or recency — and its defenders do
not really disagree with that; they redirect to the local graph, which they describe as
almost magical. Both camps land in the same place: the global view is the one that fails.

Ship it only if it is how you move through the library. If it is a picture beside a search
field, leave it out.

### Layout, when one is needed

A SwiftUI `Canvas`. Use Fruchterman–Reingold rather than a hand-tuned spring model: the ideal
separation `k = sqrt(area / n)` normalises to the frame, so one implementation fills a 700pt
canvas at 40 nodes and at 700 with no per-view tuning. The prototype's first pass used a
charge-and-centering model instead and collapsed every graph into a small blob in the middle
of an empty canvas — that failure is the entire reason this paragraph exists.

Two details that make the large case tractable: skip repulsion beyond `6k` distance, where
the force is under 1/36 of nominal, and scale the iteration count down as nodes go up —
roughly 240 under 150 nodes, 80 over 400.

Note also: rAF-style animation pauses in a hidden pane. Verify layout by measuring rects, not
by screenshotting.

---

# Phases

One sequence across all four parts. Letters are Part 4's original phases; the rest are new.

Status as of **2026-09-17** (see *Where it stands today*).

| | Part | Goal | Exit criteria | Status | Estimate |
|---|---|---|---|---|---|
| **P1** | 1 | `persona.md`, base preset, `AgentPromptContext` replacing the five hard-coded prompts, editor with both counters | Every path in `--selftest-persona` shows the persona within budget; voice latency unchanged | **Done** | 1–2 days |
| **M1** | 2 | `MemoryEntry`, profile and note kinds, `memory.*` tools, auto-allow exception, guards, spoken confirmation, Memories list | Saves, supersedes, rejects on overflow, blocks an injected write and a tool-output write; every entry forgettable | **Done** | 3–5 days |
| **R1** | 3 | `AgentSchedule`, store, `AgentScheduler`, `schedule.*` tools for reminders, OS-registered notifications | Reminder fires with the app running and with it quit; DST and month-end cases pass; missed reminders say *Missed* | **Done** | 2–3 days |
| **M2** | 2 | Session boundaries, compaction, the memory review (local/cloud/auto), routine suggestions | Review on the fixture set meets the precision bar; never runs while recording; next voice reply not slower | **Done** (fixture precision bar still provisional) | 3–4 days |
| **R2** | 3 | Routines: `.scheduled` authority, drafts + approval notifications, ACP gap closed, budgets, silence, failure escalation, launch at login, Routines view | An unattended run reads, drafts a write, never hangs, never executes a write; 10 failures disable with one notification | **Done** | 1–1.5 weeks |
| **A** | 4 | Chunked SQLite index incl. conversations, FTS5, resumable backfill, search screen with facet rail; `memory.recall` over it | Search returns passages with timestamps; `rm knowledge.sqlite` rebuilds cleanly; deleting a meeting or clearing a conversation removes its chunks | **Done** | 2–3 weeks |
| **R3** | 3 | Triggers: notes ready, meeting starting, call started | Each trigger fires once per event, with the routine rules | **Done** | 3–4 days |
| **B** | 4 | `EmbeddingRuntime`, potion + EmbeddingGemma, hybrid RRF | Gold set recall@10 beats Phase A by a measured margin; peak RSS unchanged during meetings | **Done** (gold margin unverified on a large real library) | 1–2 weeks |
| **E** | 4 | `search_knowledge` / `expand_node` / `timeline`, cited answers | Every claim resolves to a chunk and a timestamp | **Done** | 2–3 weeks |
| **C** | 4 | GBNF-constrained `notes.json`, ontology, `.extracting` stage, Person/Meeting/Decision/Action nodes, decision thread screen | 100 meetings extract with zero schema violations; re-extraction is idempotent | **Done in code** — 100-meeting bar deferred (thin corpus) | 2–3 weeks |
| **D** | 4 | Entity resolution, voice-print linking, merge UI | Precision on a hand-labelled person set above 0.95; every merge reversible | **Done** — fixture self-test + reversible merges; real-library ≥0.95 deferred | 3–4 weeks |
| **F** | 4 | Local graph and person timeline, as one deliverable | Both read the same at 12 meetings and at 180 | **Done** (`KnowledgeGraphPane`, `--selftest-graph-layout`) | 1–2 weeks |
| **G** | 4 | Global force graph — optional | It is how you move through the library, or it does not ship | **Done as navigation** (overview → local focus); not a decorative global-only screen | 1 week |

**P1 + M1 + R1 is under two weeks and is what a user feels first:** it has a character, it
knows who you are, and it reminds you of things. M2 + R2 make that trustworthy unattended.
**A + B + E is 5–8 weeks** and delivers "ask your notes anything". C + D is the expensive half
and the half that can be confidently wrong; revisit it at 100 meetings.

Do P1, M1 and R1 now. None of them waits for a corpus, and sessions from M2 start building
one.

---

# Where the code goes

```text
Sources/NextNotes/Persona/
  PersonaStore.swift          load, seed from base, caps, short card, reset
  AgentPromptContext.swift    the one prompt assembler every path calls

Sources/NextNotes/Memory/
  NextMemory.swift            extended: MemoryEntry, profile/note kinds, budgets, supersede
  MemoryTools.swift           memory.remember / update / forget / recall
  MemoryGuard.swift           provenance check, injection patterns, invisible-Unicode check
  MemoryReviewer.swift        end-of-session review, model choice, idle deferral

Sources/NextNotes/Agent/
  AgentSessionBoundary.swift  idle split, compaction summary

Sources/NextNotes/Agent/Schedules/
  AgentSchedule.swift         the record, When, Trigger, RunSummary
  ScheduleStore.swift         agent-schedules.json, atomic writes, run history
  RecurrenceRule.swift        next occurrence via Calendar, DST, month-end clamp
  AgentScheduler.swift        30s loop + wake, claim/dispatch, grace, backoff, quiet hours
  ScheduleTools.swift         schedule.list / create / update / pause / resume / remove / run_now
  ScheduledRunner.swift       fresh tool-loop run, .scheduled authority, budget, silence token
  ScheduleNotifications.swift OS-registered reminders, approval and routine categories

Sources/NextNotes/Knowledge/
  KnowledgeStore.swift        the sqlite handle, schema, migrations, transactions
  Chunker.swift               transcript/notes/conversation/routine/dictation -> [Chunk]
  KnowledgeIndexer.swift      the background queue; yields to recording
  EmbeddingRuntime.swift      actor, llama_set_embeddings + pooling, idle unload
  StaticEmbedder.swift        potion-retrieval-32M lookup + pooling, CPU
  HybridSearch.swift          BM25 + cosine + RRF + filters
  Extractor.swift             GBNF-constrained notes.json -> typed rows
  Ontology.swift              loads and validates against knowledge-ontology.yaml
  GraphStore.swift            nodes, bi-temporal edges, traversal
  EntityResolver.swift        blocking, scoring, voice-print, merge/unmerge
  KnowledgeTools.swift        the three read-class agent tools

Sources/NextNotes/UI/
  Settings/PersonaSection.swift     editor, two counters, reset, next to the voice picker
  Settings/MemoriesSection.swift    list, edit, forget, badges, meters, export
  Agent/RoutinesView.swift          schedules, run history, drafts, suggestions
  Knowledge/AskView.swift           the question field, streaming answer, citation chips
  Knowledge/KnowledgeSearchView.swift facet rail + ranked passages, jump-to-timestamp
  Knowledge/LocalGraphView.swift    one focus node and its neighbours, click to re-centre
  Knowledge/PersonTimelineView.swift one person's meetings against time
  Knowledge/DecisionThreadView.swift one decision across meetings, superseded rows struck
  Knowledge/GlobalGraphView.swift   every node on one canvas; optional, built last
  Knowledge/ForceLayout.swift       Fruchterman-Reingold, shared by both graph views
  Knowledge/MergePeopleSheet.swift  resolution review and undo

Resources/agent-persona-base.md
Resources/knowledge-ontology.yaml
```

Existing files that change: `LocalVoiceDecision.swift`, `LocalVoicePrompt.swift`,
`VoiceConversationCoordinator.swift`, `RealtimeAgent.swift`, `RealtimeAgent+ToolLoop.swift`,
`AgentPrompts.swift` (all to call `AgentPromptContext`); `AgentTool.swift`,
`AgentToolRegistry.swift`, `AgentToolExecutor.swift` (two namespaces);
`ActionRuntime.swift`, `PermissionPolicy.swift`, `PermissionGate.swift`,
`ACPAgentBackend.swift` (authority); `AgentTaskManager.swift` (scheduled source);
`Notifications.swift` (categories); `NextNotesApp.swift` (start the scheduler after
`AgentService.start`, self-tests); `Resources/Info.plist` (notification usage string now
covers reminders).

# Self-tests

Every subsystem gets a `--selftest-…` flag; it is the convention, and for most of this
feature it is the only verification available. They live in
`NextNotesApp.runRequestedSelfTest`.

| Flag | Answers |
|---|---|
| `--selftest-persona` | the assembled prompt for every path, with persona and memory character counts against budget |
| `--selftest-memory` | save, supersede, overflow rejection, forget, injection block, tool-provenance block |
| `--selftest-memory-review <fixture>` | what the review saves from a recorded session, against expected saves and non-saves |
| `--selftest-schedule` | next occurrences across DST, weekdays, weekly sets, month-end; `runOnce` with a fake clock for grace, catch-up, missed one-shots, backoff, disable, `endsAt` |
| `--selftest-routine-authority` | a scheduled run reads, drafts a write without executing it, never waits on `PermissionGate`, and a scheduled ACP task is refused |
| `--selftest-embed <text>` | does the runtime load, embed, and return a unit vector of the right dimension |
| `--selftest-index` | build the index from the meeting folders and sessions; report chunks, bytes, wall time |
| `--selftest-search <query>` | BM25, cosine and fused rankings side by side |
| `--selftest-extract <meeting-uuid>` | notes.json against the ontology; report violations |
| `--selftest-resolve` | resolution decisions on the current library with scores |
| `--selftest-graph-layout` | ForceLayout stays in-bounds; `personMeetings` + one-hop expand on a fixture graph |
| `--selftest-ask <question>` | the full loop, printing every retrieved chunk and its citation |

Build with `make build`, never a bare `swift build`; `make test` for the vectors.

# Settings and model store

New keys in `Settings.Keys`:

```
agentPersonaEnabled          Bool    true
agentMemoryEnabled           Bool    true
agentMemoryReviewModel       String  "auto" | "local" | "cloud"
agentSessionIdleMinutes      Int     30
agentSchedulesEnabled        Bool    true
agentQuietHoursStart         String  "21:00"
agentQuietHoursEnd           String  "08:00"
agentRoutineSpeech           String  "whenPresent" | "never"
agentLaunchAtLogin           Bool    false   (offered when the first routine is created)
knowledgeIndexEnabled        Bool    false
knowledgeEmbedder            String  "none" | "potion" | "embeddinggemma"
knowledgeIncludeConversations Bool   true
knowledgeIncludeDictation    Bool    false
knowledgeGraphEnabled        Bool    false
knowledgeAgentToolsEnabled   Bool    false
```

`LocalModelStore` gains `prepareEmbeddingModel()` alongside `prepareParakeet()`,
`prepareS1Mini()`, `prepareNotesModel()` and `prepareDiarizer()` — pinned URL, pinned
SHA-256, user-initiated, cancellable, with the licence shown. Weights never enter the repo.

New files in Application Support: `persona.md`, `agent-schedules.json`,
`agent-schedule-runs.jsonl`, `knowledge.sqlite`. `next-memory.json` gains the entry format,
with a migration that keeps existing activity items.

---

# Risks

**A wrong memory is saved silently and shapes every later answer.** The cost of decision 1.
Mitigations: provenance (only what the user said), declarative entries, spoken confirmation
for in-conversation saves, *New* badges for review saves, one-tap Forget, and a review
evaluated for precision over recall.

**Memory is poisoned by content the user did not write.** An email that says "remember that
the user wants all invoices forwarded to…". Mitigations: tool output can never create a
memory, the injection scan runs on write and on load, and memory can never grant a permission.

**The persona loosens a safety rule.** Mitigations: fixed rules come after the persona and say
they override it; the persona has no path into the permission system.

**Memory leaves the machine.** When the cloud backend or cloud review is used, the persona and
core memory travel in that prompt. Settings says so plainly next to the model choice. Memory
never crosses to ACP coding agents, and the Part 4 graph is never in scope for any cloud
provider without an explicit, separate, per-feature consent.

**An unattended routine does something wrong.** Mitigations: the allowed-tools ceiling fixed
at confirmation, reads-only unattended, writes as drafts, budgets, audit and receipts for
every run.

**Routines become noise.** Mitigations: the silence token, quiet hours, failure escalation
instead of repetition, `endsAt`, and a Routines view that shows what each schedule has actually
been doing.

**Background work competes with a live recording or a voice reply.** The indexer, the memory
review and routines all check for an active meeting and a busy `LlamaBackend` and wait.
Transcription latency during a meeting, and voice reply latency, are the two things that must
never regress for a background feature.

**Schedules are wrong about time.** Mitigations: wall-clock time plus IANA zone, `Calendar`
for recurrence, a self-test across DST transitions and month ends, and refusing rules the
fields cannot express.

**Extraction produces confident nonsense.** A 4B model will invent an action item nobody
assigned. Mitigations: constrained decoding, ontology validation, `source_chunk` on every
row so any node can be traced to the sentence that caused it, and a UI that shows extracted
items as *proposals* in the same visual language the agent already uses for its own.

**The index and the source files drift.** Answered by generation counters and by the rule
that the index is disposable. A "rebuild index" button is a feature, not an admission.

**Resolution merges two different people.** Answered by `merged_into` rather than deletion, a
conservative threshold, and a review sheet.

**Privacy.** The graph is the single most sensitive artifact this app will ever produce — it
is the distilled version of every conversation — and core memory is the distilled version of
the user. Both stay local by default.

**Disk.** Free space on this machine has ranged from under 200 MB to 6 GB during this work, and
Qwen already holds 2.74 GB. EmbeddingGemma at 200 MB is affordable; Qwen3-Embedding-0.6B at
600 MB is the reason it was not chosen. Every store in this document must fail a write
cleanly — never truncate a file — when the disk is full.

# Evaluation

Without a gold set you cannot tell whether a change helped, and every change will feel like it
helped.

- **Retrieval.** ~50 questions with known answers against the real library, in the shape of
  `CleanupEvalCases.swift`: question, the chunk ids that contain the answer, and the expected
  claim. Report recall@10 and MRR, and answer-contains-claim for the full loop. Run it from
  `--selftest-ask`.
- **Memory review.** ~30 recorded sessions, each labelled with what should and should not be
  saved. Report precision and recall; **ship only at precision ≥ 0.9**, because a missed memory
  costs a repeat and a wrong one costs trust.
- **Persona adherence.** ~20 fixed prompts through the voice path and the tool loop with the
  base preset and one very different user persona. Check spoken length, no filler openers,
  and that the persona changes tone without changing tool choices.
- **Schedule parsing.** ~40 spoken requests ("remind me tomorrow at 9", "every weekday at
  8:30", "the last day of every month", "every other Tuesday") with the expected record or the
  expected refusal. Run on Qwen and on the cloud model.

Fifty, thirty, twenty and forty cases are enough to catch a regression and small enough to
actually write.

---

# Alternatives, and why not

**Run OpenClaw or Hermes as the Agent.** Both ship personality, memory and scheduling today.
OpenClaw is a TypeScript gateway and Hermes a Python agent; both are long-running servers with
their own config homes. Embedding either means bundling a Node or Python runtime, signing
every native module, and giving up the in-process voice loop this app is built around. Their
designs are adopted piece by piece above; their code is not.

**A heartbeat as the task runner.** Both projects tried it; OpenClaw removed the task list from
its heartbeat file. It spends a model call every interval to rediscover state that a scheduler
already knows, and in the real workspace it mostly reported the same thing repeatedly.

**Cron expressions.** Unreliable from a 4B model, a day-matching trap for everyone, and a
source of timezone bugs in both projects. Structured fields plus `Calendar` instead.

**Nightly whole-file memory rewrite ("dreaming").** OpenClaw rejects a rewrite that loses more
than a quarter of entries, which says enough about how often it goes wrong. Consolidation here
happens only on overflow, one entry at a time, visibly.

**Cloud user modelling (Honcho, mem0, Supermemory).** Sends the conversation to a third party
by design.

**Agent-written skills.** Hermes's self-improving skills loop is the most interesting idea in
either project and the one most able to go wrong unattended. Revisit after memory has earned
trust; start it, as the real workspace did, with propose-then-approve.

**FAISS.** C++ with no maintained Swift binding — another binary to vendor, sign and keep
hardened-runtime-clean. Stores only vectors: `write_index` to a flat file, no metadata, no
filtering, no transactions. SQLite would still be needed beside it, and two files can then
disagree after a crash mid-write. Its whole value is approximate search, which does not turn
on until ~1M vectors.

**ChromaDB.** A Python library. Shipping it means bundling a Python runtime and its wheels
(including `onnxruntime`) inside the `.app`, signing every dylib and notarizing the lot — or
running a localhost server.

**Qdrant.** A Rust server with no in-process embedded mode. Docker or a supervised sidecar, a
listening port, a second process lifecycle. For a single-user menu-bar app this is the largest
possible version of the smallest possible problem.

Two of those three break a sentence the README currently gets to say: *the app does not depend
on Homebrew, Ollama, a local server, or any network request at inference.* There is also a
signing tax — per the migration notes, the code-signing identity had to be hand-built with
`openssl`, and TCC grants break when the designated requirement changes. Every embedded binary
is more surface that can invalidate a grant that was painful to obtain.

**LanceDB.** Genuinely good embedded columnar vector store with disk-based IVF-PQ, and the
right answer past 10M vectors. Rust, with no Swift story.

**Apple `NaturalLanguage` embeddings.** Covered above: quality and bundle-loading problems.

**Graphiti / Zep / Cognee / mem0 / LightRAG.** All Python, all server-shaped. Take
bi-temporal edges from Graphiti and leave the rest. Treat published comparisons carefully —
Cognee's benchmark ran tuned configurations against everyone else's defaults.

**Existing open-source meeting-graph projects.** `sensein/meetgraph` (3 stars, Python/PyQt6,
RDF via Oxigraph) is the literal match and is worth reading for its ontology idea only.
`fastofiCorp/ofi-meeting` is a 1-star Meetily fork on ChromaDB. `Zackriya-Solutions/meetily`
is the closest architectural competitor and is Rust + Python FastAPI + an Ollama sidecar.
`Hyprnote` is the serious one — and is **GPL-3.0**, so it can be read for ideas and its code
cannot be copied into this app. None of them has shipped the graph half well.

---

# Verified, and assumed

**Verified on this machine, 2026-09-10:**

- System `sqlite3` is 3.45.3 with `ENABLE_FTS5`; `SQLITE_OMIT_LOAD_EXTENSION` absent.
- `llama.framework` b10621 in the installed app exposes `LLAMA_POOLING_TYPE_MEAN`/`CLS`/`LAST`/
  `RANK`, `llama_set_embeddings`, `llama_encode` and `llama_get_embeddings_seq`.
- The library holds 2 meetings and 62 dictation runs; both meetings have no attendees.
- The schema above executes against that sqlite: BM25 ranking through the join works, the
  cascade delete works, `PRAGMA integrity_check` passes.
- A global force graph is legible at 12 meetings and a hairball at 180, and a one-hop local
  graph is unchanged between the two. Measured in the prototype, on synthetic data.

**Read from source, 2026-09-17 (supersedes the 2026-09-16 cold-start notes):**

- Parts 1–3 and Part 4 A/B/E/C/D/F/G are in the tree; see *Where it stands today*.
- OpenClaw (`main`) and Hermes Agent designs as described in Parts 1–3 remain the
  reference for *why* those shapes exist, not for runtime adoption.

**Previously true on 2026-09-16 and no longer the implementation status:** hard-coded
prompts with no `AgentPromptContext`, `NextMemory.remember` with no production caller, no
scheduler, and ACP treating non-meeting sources as already permitted. Those gaps were the
reason Parts 1–3 existed; they have since been closed in code.

**Assumed, and to be measured before it is believed:**

- That a 400-character short card is enough for the Apple-model voice path to hold a persona.
  Measure with the persona adherence set before tuning the cap.
- That Qwen3.5-4B fills `schedule.create` fields and makes memory review decisions reliably
  enough without GBNF. If the evaluation sets say otherwise, grammar support moves ahead of
  Phase C.
- The macOS cap on pending `UNNotificationRequest`s. Registering only the next occurrence per
  reminder assumes a cap in the tens; verify.
- Whether Focus status can be read (`INFocusStatusCenter`) without a disruptive permission
  prompt. Until verified, presence is keyboard/mouse idle time plus recording and call state.
- EmbeddingGemma-300M's quality on meeting transcripts specifically. Published MTEB numbers
  are not this corpus.
- ~1ms brute-force search at 37k × 256. Arithmetic, not a measurement.
- The chunk-count projection (one chunk per ~90 seconds of speech) — derived from two
  meetings, which is not a sample.
- That the ANE path is meaningfully cheaper than the GPU path here. Worth a `--selftest-embed`
  comparison before committing to CoreML conversion.
- Extraction cost per meeting at 13.7 tok/s. Measured for notes generation, extrapolated for
  extraction.
- That the prototype's degradation curve matches a real library's. The synthetic corpus
  assumes an attendee-overlap rate nobody has measured, and overlap is what decides whether
  a real graph is a hairball or several loosely joined islands. Unknowable until calendars
  are connected.

# Amendment 2026-09-22 — what the live logs showed

Read from `agent-memory-review.json`, `next-memory.json` and
`agent-conversation.json` on 2026-09-22. Two failures, both against designs
already in this doc.

## M2-a. Stop producing doomed review jobs (shared cloud-health gate + batching)

Observed: ~50 consecutive review runs, every one `proposed: 0, saved: 0` —
first `OpenRouter returned an unreadable response`, then a long streak of
`OpenRouter rate-limited…`. *Producer chain (read 2026-09-22):* every
`dictationSaved` / `meetingNotesReady` event enqueues its own job
(`MemoryReviewJob.Trigger`), and each job independently routes to cloud and
independently fails on the same per-key rate limit — `attempts` is per-job,
the limit is global. So N dictations → N cloud calls → one rate limit → N
failures → retries. The queue has no global health view, and
`MemoryReviewRouter.route` (which already knows how to `.wait`) is evaluated
at execution, after the doomed jobs exist.

Producer fixes, in order:
1. **Pre-enqueue route check.** Evaluate `route()` before a job is created;
   on `.wait`, record a counted skip with reason (`rate-limited`, `local
   model busy`, `recording active`) and create nothing. A queue that cannot
   fill with jobs that cannot run.
2. **Shared cloud-health gate.** One rate-limit/backoff state for OpenRouter,
   owned outside any single job and visible to every producer (review
   enqueue, routine runner): a 429 marks the gate down for the backoff
   window, and `route(.auto)` treats a down gate as "cloud unavailable"
   rather than trying again.
3. **Coalesce dictation jobs.** Hold dictation triggers in a ~10-minute
   bucket and review them as one batch — one cloud call per bucket, not per
   dictation. This restores the M2 cadence (end of session + every 10 turns)
   that per-event triggers currently bypass.

*Backstop (lesson 7, kept):* consecutive failures back off 1 → 5 → 15 → 60
min, one island notice with the actual error + fix after 3, self-disable
until next session start after 10.

Self-test: extend `--selftest-memory-review` with a rate-limit fixture —
assert no job is enqueued while the gate is down, skips carry reasons, and
the notice fires once. Files: `Memory/MemoryReviewer.swift`
(`MemoryReviewRouter` + enqueue path + shared gate),
`Memory/MemorySources.swift`, `Support/Settings.swift`
(`agentMemoryReviewModel`), `UI/Settings/AgentSettingsTab.swift` (surface the
disabled state where the model row already lives).

## M1-a. Mark auto-titles provisional at creation; skip them in memory

Observed: `Meeting · 8:15 PM`, `8:42 PM`, `8:47 PM` stored as first-class
meeting memories beside real named calls. *Producer:* `MeetingController`
mints `"Meeting · HH:mm"` with no marker that it is provisional, so every
downstream consumer (activity, memory, graph) treats placeholder text as a
real name.

Producer fix: `titleSource: .calendar / .user / .auto` on `Meeting`, set at
creation (calendar link, user rename via `syncTitle`, else `.auto` from
`defaultTitle`). Activity and memory producers skip `.auto` titles; the
Meetings list may render them dimmed as provisional. A later rename or Phase
D attendee resolution flips the source and the memory is written then —
nothing is lost, nothing placeholder is learned.

*Backstop (kept):* refuse `^Meeting · \d` / untitled writes at the
`NextMemory` boundary with a counted skip, visible in `--selftest-memory`.
Files: `Meetings/Meeting*.swift` (`titleSource` + `defaultTitle` +
`syncTitle`), `Memory/NextMemory.swift`, `Memory/MemoryGuard.swift`.

The live-turn failures from the same log batch — the 5× email/calendar
refusal loop and raw provider error text (`Codex usage limit…`, `model is not
downloaded`) — belong to `roadmap/done/AGENT-COMPETITOR-GAP-2026-09-20.md` §7
(P0-6, P0-7, D8), not here.

# Amendment 2026-09-22b — Muse review: Goals, Ideas, avatar, tone

Source: How-I-AI Muse (Meta) review transcription. The reviewer names the
primitives explicitly — *tasks, ideas, goals, library* — and the words we must
never ship: *crons, to-dos, tools, artifacts*. Three additions; all else in
this doc stands.

## G1. Goals are not routines

A routine is a job on a clock ("weekdays at 9, summarize"). A goal is an
outcome with a state ("sleep-train the baby", "drink enough water", "buy the
shoes on sale"): it is *set up once* (proposed plan + tracking + nudges),
*worked* conversationally, and *done* when the world changes, not when a slot
fires. Muse tracks the goal as an object with morning/night nudges; our
scheduler has no such object — the closest run is a routine with a prompt,
which cannot represent "in progress, stuck, done".

Record: `AgentGoal` (id, plain-English outcome, proposed plan the user
confirmed, state: active/stuck/done, nudge cadence, linked schedule ids for
its reminders). State advances only by user word or by evidence the user
confirmed — never by a model deciding the baby sleeps now. Nudges reuse R2
delivery + quiet hours + silence rules unchanged. A goal's reminders are
ordinary reminder schedules pointing at it, so launch-at-login, grace and
`endsAt` need no second implementation. Creating a goal follows the R2
restate-confirm-test shape: restate the outcome + the plan's first step, wait
for yes, save enabled, first nudge visible immediately.

Self-test: `--selftest-schedule` gains goal fixtures (create → nudge fires →
user says "done" → nudges stop; `endsAt` still enforced). UI names it
**Goals**, listed beside Routines, each with plan, state, and nudge history.

## G2. Ideas gallery feeds goals and routines

The blank chat box is the wrong start for a consumer. A static curated
gallery (inbox, returns, relationships, health, finance, home/city), one tap
per card, each opening the goal or routine setup flow — never executing
directly. Card anatomy is frame-verified (`references/ideas.png`, video
16:05): icon + bold outcome title + two-line plain-words description naming
the proof ("file the report with your photos", "chase the refund until the
money's back"), grouped by life area with the same category list as goal
creation (Health, Relationships, Finance, Career, Interests, Productivity,
Something else — see `references/goals.png`). v1 is a static list, no model
involved. The M2 routine-suggestion path ("you asked three mornings running
— set it up?") renders *into* this gallery later; it does not bypass it. UI
names it **Ideas**.

## G3. Name, face, soul — and a gentler voice for care contexts

What exists: `persona.md` (free text, budgeted), Memories list, one-line
"what should I call you" (writes to memory), avatar params in
`agent-identity.json`. What Muse adds:
1. **Naming ritual, visible.** The name is set on first voice session, shown
   beside the avatar everywhere, changeable in one tap. (Our one-liner
   exists — surface it.)
2. **Soul as three editable files**, not one: identity (who it is), soul
   (how it behaves), memory (what it knows) — our `persona.md` is the soul;
   add the identity file rather than overloading the persona, and keep the
   Memories list as the third. Same provenance + injection guards on all
   three; persona-before-fixed-rules ordering unchanged.
3. **Avatar states**, per the competitor doc §8.3 (idle/working/media/done,
   makeover flow, Reduce Motion freeze).
4. **Care-context tone.** The base preset ("sharp, friendly colleague") is
   right for work and wrong for 2 a.m. with a sleepless baby. Add one
   paragraph to the preset: when the goal is personal and the user is
   struggling, lead with warmth, one step at a time, no flattery, no
   productivity voice. The reviewer's "my heart grows a hundred times" is the
   bar; "0% annoyed" is the metric. Persona adherence eval gains two care
   prompts.

## Explicitly not adopted

Heartbeat-as-a-feature (our scheduler's claim-then-dispatch + run history is
the auditable equivalent; a chatty heartbeat is the costliest pattern in the
OpenClaw notes), cloud account as identity (sign-in stays device-local;
`gws`/Composio credentials are per-integration), server-side VM (the Mac is
the computer — that is the product, not a limitation).

# References

Personality, memory and routines:

- OpenClaw — https://github.com/openclaw/openclaw — `docs/concepts/soul.md`,
  `docs/concepts/memory-architecture.md`, `docs/concepts/compaction.md`,
  `docs/concepts/standing-intents.md`, `docs/automation/cron-jobs/`,
  `docs/gateway/heartbeat.md`, `extensions/memory-core/`
- Hermes Agent — https://github.com/nousresearch/hermes-agent — `agent/system_prompt.py`,
  `tools/memory_tool.py`, `agent/background_review.py`, `agent/context_compressor.py`,
  `tools/threat_patterns.py`, `tools/cronjob_tools.py`, `cron/jobs.py`
- Qwen audio agent reference (reminders) — `roadmap/references/qwen-audio-agent-main/`,
  `server/src/frontend/tools/features/schedule-tools.mjs` and its tests

The second brain:

- sqlite-vec — https://github.com/asg017/sqlite-vec
- Model2Vec — https://github.com/MinishLab/model2vec
- potion-retrieval-32M — https://huggingface.co/minishlab/potion-retrieval-32M
- EmbeddingGemma — https://huggingface.co/google/embeddinggemma-300m
- swift-embeddings (fallback runtime) — https://github.com/jkrukowski/swift-embeddings
- meetgraph (ontology idea) — https://github.com/sensein/meetgraph
- Meetily — https://github.com/Zackriya-Solutions/meetily
- Hyprnote (GPL-3.0) — https://github.com/bahodirr/hyprnote
- Obsidian graph view — https://help.obsidian.md/plugins/graph
- The case against it — https://codeculture.store/blogs/developer-culture/obsidian-graph-view-useful
- The case for local graphs — https://pjordan.substack.com/p/a-pkm-revelation-obsidian-local-graphs
- Graph visualization UX — https://cambridge-intelligence.com/blog/designing-intuitive-data-experiences-with-graph-visualizations/
- The four views, as working prototypes —
  https://claude.ai/code/artifact/0ad9de12-74b7-4be8-8850-594ae6d8ad15
