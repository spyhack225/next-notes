# Phase 4 — proactive and useful (P4-01 … P4-13, P4-07a)

## Current implementation boundary — 2026-10-03

P4-01, memory lineage P4-07a, bounded routine producer P4-12, event-ready brief
P4-04a and Knowledge fitting P4-08a/b have recorded proof. Their parent/product
exits remain separate. P4-07 now has actual committed typed/voice hooks: staged155
RED13/70 →156 PASS70, six related flags pass and review precision is unchanged.
Native caption/full/CORE/live statement/latency remain open; quick156 fails3/10.
The existing explicit Remember directive remains P1 work. P4-08 now has an actual typed
library route: original161 RED18/59 → fixed162 PASS59, with seven related flags PASS.
Reader cache/prompt budgets and Assembler output now have163 RED17/51 →164 PASS51
and nine latest related invocations PASS. Scheduled forwarding, loaded capacity and
native source-chip interaction remain open; the initial three-read timing failure is
retained despite passing original/recheck. Hosted meeting brief,
owed items, digest/nudges, first-use consent and actual review quality remain open.
P4-11 reviewer/harvest71, decisions/totals63, provider-capacity28 and modal-environment60 now have actual original/fixed producer proof. Third-party preference provenance, loaded factory/native/real-model review quality remain open. P4-10 same-reader fitting and earlier asks pass31 in185 after original184 fails9; transcript-owned evidence passes89 in189 with five related flags. Compact prompt/catalogue/rounds and persisted/native owner acceptance remain open. Preference-subject repair now passes189 in205 after qualified204 fails4; prior292 and six related flags including both unchanged merge/correction flows pass, preserving scripted recall25/27. Live/loaded/native/full parent memory acceptance remains open.
See STATUS and [the complete remaining contracts](REMAINING-WORK.md#agent-answers-memory-and-proactive-behavior).

## Implementation sequencing amendment — owner decision 2026-10-01

Read [README §4.1](00-README.md#41-implementation-eligibility-and-quality-gates--owner-decision-2026-10-01).
Implementation follows the task's actual contracts and isolated production-path
proof; an inherited aggregate quality failure does not block an independent
foundation. Required quick/full evaluations keep their real verdicts and bars.
Phase acceptance, model/default promotion and product-readiness claims remain
gated. This amendment changes entry sequencing, not implementation state.

## Model ownership amendment — 2026-09-30

The owner approved independent appropriate models for Agent, meeting notes and
Dictation cleanup, reusing exact verified artifacts through the existing library.
Read [SHARED-BRAIN](../SHARED-BRAIN/00-README.md) and
[MODULES-ACTIVATION](../MODULES-ACTIVATION/00-README.md) before changing
model selection/loading/download/deletion. Their revised SB tasks own artifact
identity, role independence and request binding; this roadmap owns Agent behavior,
latency/full duplex and capacity. Coordinate shared files in BUILD-ORDER.

Existing one-resident-file/Agent-centric descriptions below are baseline or migration
constraints, not permission to force meetingNotes or cleanup onto the Agent choice.
Keep existing tokens and per-role cloud IDs/consent. MiniCPM cleanup + Apple guard/
fallback is concurrent OpenCode work; reuse its verified file, not its settings or
prompt. An awaited deferred swap cannot execute as if the requested file loaded.
Do not add a runtime/store/queue per module or sacrifice a voice lease to background
work. Same weights can serve independent requests; separate contexts/residency are
measured capacity decisions under P3-07. Implementation/gate states remain unchanged.

Paths are relative to `Sources/NextNotes/` unless they start with `Resources/`, `Scripts/`,
`Tests/` or `roadmap/`. `ToolLoop` means `Agent/RealtimeAgent+ToolLoop.swift`, `Coordinator`
means `Agent/VoiceConversationCoordinator.swift`. Every `file:line` below was re-read in the
working tree on 2026-09-23. Lines move: grep the quoted symbol if a line number no longer
matches.

**Memory order inside this phase (added 2026-09-25):** the three memory tasks are not independent.
Run **P4-07a** (provenance survives the write) first, then P4-07, then P4-11. P4-07a is the
prerequisite for both: it is the write path P4-07 writes through, and it is the only thing that
lets P4-11 stop the review echoing a fact without also erasing where the fact came from. Nothing
else in this phase depends on the order. `roadmap/backlog/memory-lifecycle-consolidation-roadmap.md`
is sequenced behind all three.

---

## Overview

"D-report item Px-y" in a **Finding(s)** line is report D's own recommendation number, **not** a
task id of this roadmap.

### What the user sees today

The agent answers too little, knows too little about "now", and never speaks first.

| Measure (source) | Today |
|---|---|
| Real requests since 09-14 with a substantive first reply (`agent-audit.jsonl`, D §4) | **42 of 153 (27%)** |
| Clean requests fully useful, hand-graded (D §4) | **3 of 20** |
| Agent-initiated turns in the log (D §4) | **0**; the only unprompted speech is a background job the user started |
| Routines / goals / triggers on this Mac (D §0.4) | **0 / 0 / 0**; no `agent-schedules.json`, no `agent-goals.json` |
| Morning digest and podcast callers (D §5) | only `DigestSelfTest` and `PodcastSelfTest` call `createArguments()` |
| `meetingStarting` trigger instances | none by default; the event is published every 30 s tick (`MeetingScheduler.runOnce`, `Meetings/MeetingScheduler.swift:123`) and nobody listens |
| Memory facts after 200 review runs (D §3) | **2** |
| Typed first-pass history | 2,500 characters (`ToolLoop:382`), session reset after **30 idle minutes** (`AgentSessionBoundary.defaultIdleMinutes`, `Agent/AgentSessionBoundary.swift:22`) |
| Prompts that know today's date, the next meeting or the active app | only the planner (`"Today is …"`, `ToolLoop:715`) and the routine runner (`"Now: …"`, `Agent/Schedules/ScheduledRunner.swift:446`). The typed first pass, the voice answer and the voice router know none of it |

Real turns this phase fixes (all from D §2 and §4, `agent-audit.jsonl`):

- 09-14 11:16 voice, "What's the content of my calendar for today?" → agenda for **2023-10-27**.
- 09-23 17:18 typed, "Who am I?" → *"I'm Will, Serge's autonomous alter ego…"* (the model answered about itself).
- 09-22 00:57 typed, "What is the LLM under the hood?" → *"I don't have visibility into that detail."*
- 09-14 20:52 voice, "What about your tools?" → *"I couldn't interpret that."* ×4.
- 09-23 06:37 typed, "Remind me tomorrow at 9 to …" → *"Could you tell me the exact name of the reminder…"*
- 6 recorded meetings, 0 `proposals.json`, and no way to say "here is what you owe".

### Goals

1. Every prompt that speaks to the user knows the date, the time zone, the next two events,
   what is recording, the front app, running work and pending approvals (P4-01).
2. One identity per prompt, answers as long as the persona asks for, acting on the likely
   reading, and a voice card that carries the persona's "Voice" section (P4-02, P4-03).
3. Longer, fitted context: library questions answered by a fitted `KnowledgeAsker` on typed
   turns too, memory and page budgets scaled to the model, explicit statements saved to memory
   (P4-07, P4-08; the history budget itself moved to P1-18, H-audit 2026-09-23).
4. A capable model for typed and background work, behind its own consent (P4-09).
5. The agent speaks first, within caps: a pre-meeting brief, a post-meeting "what you owe"
   wrap, owed-item nudges, a morning-digest offer and one next-step offer after an answer
   (P4-04, P4-05, P4-06).
6. (H-audit 2026-09-23) The background machinery those features stand on actually runs on this
   Mac: the post-meeting review fits Apple Intelligence's window and reads the asks (P4-10), the
   memory review stops echoing and keeps short facts (P4-11), routines run on Apple Intelligence
   with a template-sized answer (P4-12), and a signed-in user gets the proactive meeting
   features by default, each still behind an approval or a real consent card (P4-13).

### Order and dependencies

**Preferred working order (H-audit 2026-09-23; entry revised 2026-10-01):** ~~P4-01~~ (moved to Phase 1, 2026-09-27) → P4-03 → P4-02 → P4-08 → P4-07a → P4-07 → P4-11 → P4-09 → P4-12 → P4-10 → P4-04 → P4-05 → P4-13 → P4-06.

The arrows above are a recommended sequence, not extra hard dependencies. P4-07a
may start independently from P0-11; only P4-07a → P4-07 → P4-11 is the required
memory chain. Follow the explicit contracts in the table and task text.

| Order | Task | Hard dependencies | Why this order |
|---|---|---|---|
| 1 | P4-01 Now block | P1-01 (eval exists), P0-18 (prefix reuse) | every later prompt change and every proactive item reads it |
| 2 | P4-03 prompt rewrite | P1-01, P1-02 (typed tool-less pass removed), P1-03 (manifest) | graded by the live eval; P1-02 decides which prompt variants still exist |
| 3 | P4-02 router sees previous exchange | P2-02 (single streamed decision), P4-03 | P2-02 may replace `routePlan`; apply there |
| 4 | P4-08 fitted `KnowledgeAsker`, memory and Assembler budgets | P4-01, P1-18 (history budget, moved to Phase 1) | the Now block takes budget from the same window |
| 4a (independent start) | P4-07a durable provenance | P0-11; existing guarded write seam | lossless legacy decoding and provenance privacy first; no P4-08 prerequisite |
| 5 | P4-07 explicit memory | P4-07a, P0-11 (self-tests stay out of real memory) | P4-07a runs first |
| 6 | P4-11 memory review stops echoing, keeps short facts | P4-07a, P4-07, P0-11 | shares `Tests/Fixtures/memory-review.json` with P4-07; do it right after |
| 7 | P4-09 capable model routing | P0-01, P0-03, P0-14, P0-17, P0-19, P0-20, P1-01 | P0-03 makes roles resolve only to answerable models; P0-17/P0-19 make a cloud model usable and private |
| 8 | P4-12 routines on Apple Intelligence, template-sized output | — | P4-04 and P4-06 build on routines/triggers that must not skip on a Mac with no GGUF or cloud |
| 9 | P4-10 post-meeting review fits a small window | P0-20b (usage rows), P1-10a (runtime window) | probe first; P4-05 and P4-13 send more meetings through this pass |
| 10 | P4-04 pre-meeting brief | P4-01, P0-11, P4-12 | builds the proactive sink, ledger and settings the next three reuse |
| 11 | P4-05 post-meeting wrap + suggestion lane | P4-04, P4-10, P0-20b | reuses sink, ledger, owed-item parser; reads the usage rows first |
| 12 | P4-13 consent-shaped defaults | P1-16, P4-10, P4-04 | turns the proactive features on for signed-in users only once they work and their cards stay visible |
| 13 | P4-06 digest offer, nudges, next-step offer | P4-04, P4-05, P4-12, P1-02 (typed pending intent), P1-03, P4-02 | the digest needs P4-12's route and budget; soft: P4-13's attended first-use consent, without which a new digest never reads mail |

**How the live eval is used.** P1-01's `--selftest-toolloop-live` grades every prompt change.
P4-01, P4-02, P4-03, P4-08 and P4-09 must each record the eval score before and after in
`STATUS.md`. Use `--quick` (P1-01 step 8b, 10 fixed cases, target ≤ 20 min) before and after each
task. Full 30-case runs are for P4-03, which changes every prompt, and for the Phase 4 exit gate.
The bare `--selftest-toolloop-live` lines in this file's **Verify** blocks mean `--quick`, except in
P4-03 and at the gate. A change that lowers the score by more than one request is reverted or fixed
before it is marked done. The eval's case list lives in P1-01's
`Agent/LiveEval/ToolLoopLiveEvalCases.swift`. Eight behaviours matter to this phase; three are
already scored P1-01 cases (tighten their grading here, do not duplicate them), and five are new
**`scored: false`** extra cases (P1-01 step 8), so the core score stays `n/30`:

| Case (id) | Pass when |
|---|---|
| "What's the date today?" (new, D01) | reply contains today's date; no tool call needed |
| "What's next on my calendar?" under a fixture calendar (new, D02) | names the fixture event with no tool round, or with one `get_agenda` call |
| "Who am I?" (existing N01) | names the user (grounding), never "I'm <agent name>…" |
| "What model are you running on?" (existing N02) | names the resolved model's display name |
| "What can you do?" then "what about your tools?" then "use them" (new, D03) | third turn produces a tool call or a spawned task, never a deflection |
| "Remind me tomorrow at 9 to call the bank" (existing R01) | `schedule.create` is called; add: reply says how to undo |
| "I'm the CEO of ProductFlo" (new, Y03) | the fact is saved to the eval's temporary memory |
| "Summarise what we decided in my last meeting" (typed, new, K04) | answered through `KnowledgeAsker` with a citation marker |

**How proactive speech is delivered.** P3-04 builds `OutputScheduler` (`AgentDelivery` modes
`context | respond | interrupt`), the only component that may start audio in a live voice
session. Until P3-04 is merged:

- Proactive items go to an **island card and a notification only**. They are never spoken
  while a voice session is open (`AgentCaptureController.shared.isSessionActive`).
- Outside a voice session they are spoken only when the user picked "Show and say it" for
  that item *and* the reminder presence rule passes (`LiveScheduleEnvironment`,
  `Agent/Schedules/AgentScheduler.swift:1267`: input in the last 2 minutes, no recording, no
  dictation, no call, agent idle). This path already speaks reminders through
  `AgentSpeechSynthesizer.shared.speak` (`LiveScheduleDelivery.deliver`, `:1286-1295`).

After P3-04 lands, a proactive item raised during a live session becomes
`OutputScheduler.shared.enqueue(DeliveryItem(task: TaskID("proactive-<occurrence key>"), kind: .proactive, …))`
— P3-04's API (Phase 3 file §2.6) takes a `DeliveryItem`, not an `OutputRequest`; add the case
`proactive` to `DeliveryKind` in the first Phase 4 task that needs it (P4-04), delivered in mode
`.respond` with the result priority. The
frontend phrases it under the "not a new request" instructions. Nothing in this phase calls
`RealtimeAudioSession.speak` or `VoiceAnnouncementQueue.enqueue` directly.

### Exit gate for Phase 4

All must hold on one build:

1. `--selftest-now-block`, `--selftest-proactive`, `--selftest-meeting-agent-fit` (P4-10, H-audit
   2026-09-23) → `*_OK`.
2. `--selftest-persona`, `--selftest-digest`, `--selftest-podcast`, `--selftest-memory-review`,
   `--selftest-ask`, `--selftest-assemble`, `--selftest-model-roles`, `--selftest-voice-turn-routing`,
   `--selftest-schedule`, `--selftest-routine-authority`, `--selftest-function-calls` → `*_OK` with the
   new cases in this file (P4-08, P4-11, P4-12 and P4-13 extend the last seven; H-audit 2026-09-23).
   `--selftest-memory-review` prints `MEMORY_REVIEW_ECHO_SHARE` < 0.15.
3. `--selftest-toolloop-live` ≥ 25/30 on the resolved model (scored set), N01, N02 and R01 PASS,
   the five extra cases D01, D02, D03, Y03, K04 PASS (`TOOLLOOP_LIVE_EXTRA 5/5`), and no regression against the score recorded at Phase 1's exit.
4. `--selftest-ui-strings`, `--selftest-avatar`, `--selftest-island` → `*_OK`.
5. `make acceptance TIER=core` → no CORE entry newer red than at Phase 3's exit.
6. Observation after one real weekday (not CI, recorded in `STATUS.md`): `agent-audit.jsonl`
   has at least one `kind: proactive` row per calendar meeting with attendees, and zero
   proactive rows inside quiet hours.
7. (H-audit 2026-09-23) `--selftest-agent <meeting folder> --agent-provider apple` prints
   `AGENT_FIT policy=production … fits=yes` on this Mac's meeting folders (P4-10), and the
   `meeting.proposals` rows in `usage.jsonl` for meetings after P4-10 carry no `errorClass`
   `contextTooSmall`.

### Rules from AGENTS.md that apply to every task here

- The Agent's name is never in a prompt. "You are <name>." comes only from `AgentGrounding`
  (`Persona/AgentGrounding.swift:67`).
- The first paragraph of `Resources/agent-persona-base.md` and
  `PersonaStore.builtInBaseText` (`Persona/PersonaStore.swift:66-86`) stay byte-identical;
  `--selftest-persona` fails if they drift.
- `PersonaCareEval` pins "no technical detail" and "no filler or flattery" into every
  user-facing path. Change it in the same commit as any rule that touches those words.
- A self-test never writes the user's real stores (`RunLog`, `agent-tasks.json`,
  `agent-audit.jsonl`, memory, `persona.md`, schedules). Use the isolated `.shared` stores
  (they already switch to a temp directory under `SelfTest.isRunning` — `PersonaStore`,
  `ScheduleStore`, `ReminderSuggestionStore`) or pass seams. `AgentTaskManager.shared` and
  `AgentAuditLog` are **not** isolated until P0-11: go through a seam.
- On the conversational path a deterministic gate may only add, never subtract.
- A finished feature with no call site looks exactly like a working one: grep for callers of
  every new seam before marking it done.
- Adding a field to a `Codable` record that is on disk needs `decodeIfPresent` in a
  hand-written `init(from:)` (`Meeting` precedent in `Meetings/MeetingModels.swift`).
- `MainActor.assumeIsolated` crashes; use `await MainActor.run`.
- UI strings: no `cron`, `artifact`, tool ids, schema keys (`UI/UIStringsLint.swift`).
- Views contain no literal values; add `DS` tokens (`UI/DesignSystem.swift`).
- Build with `make build`, install with `make install OPEN=0`, run self-tests one at a time
  in the foreground with `Scripts/run-selftest.sh`.

---

### P4-01 — Cached "Now" block in every prompt

> **Runs in Phase 1 (owner decision, 2026-09-27).** The live log audit
> (`roadmap/done/agent-analysis-2026-09-23/J-live-log-audit-2026-09-27.md` L11, L13) found the Agent
> quoting a 2023 agenda for "today", and telling side talk "the clock reads 1:45 AM on 2026-09-23"
> about three and a half hours off. Both dependencies (P1-01, P0-18) are done. The id stays P4-01.
> **Land it before P2-01 records Phase 2's baseline**, so the latency phase measures the prompt that
> ships. `--selftest-now-block` joins the Phase 1 exit list, and P1-27's O07 is its live check.
> The 2026-10-01 amendment supersedes blanket Phase 3 entry gating. Other tasks
> follow their explicit Depends on lines; provenance can start independently,
> while live proactive behavior still requires its consent and functional gates.

**Finding(s):** Q7 (D §3, D-report item D:P1-11, not this roadmap's P1-11)  **Effort:** 1.5 days  **Depends on:** P1-01, P0-18 (llama prefix reuse: the section order below only saves prefill once the runtime reuses the prefix; before P0-18 every call re-prefilled from zero, G N2)  **Unblocks:** P4-02, P4-03, P4-04, P4-06, P4-08

**Why (what the user experiences today):** "What's on my calendar for today?" by voice on
09-14 returned an agenda for 2023-10-27, and "what's next?" always costs a tool round. The
typed first pass and the voice answer lane carry no date at all (D §3 table: "Date / time: no"
for the typed first pass, the voice route and the voice answer). Without "now" the agent cannot
say "you have a call with Margaret in 10 minutes", which is what every proactive task in this
phase needs.

**Files you will change:**
- new `Persona/AgentNow.swift` (facts, cache, renderer, publisher)
- `Persona/AgentPromptContext.swift` (new `NowShape` in `Budget`, new `now` section)
- `Agent/RealtimeAgent+ToolLoop.swift` (`publishGrounding()` also publishes Now; planner drops its own "Today is" line)
- `Agent/Schedules/ScheduledRunner.swift` (replace its `Now:` line with the shared block)
- `Calendar/CalendarService.swift` (publish after `refresh()`)
- `Meetings/MeetingScheduler.swift` (publish on each `runOnce`)
- `NextNotesApp.swift` (start the publisher; register `--selftest-now-block`)
- new `Persona/AgentNowSelfTest.swift`
- `Persona/PersonaSelfTest.swift` (`inOrder` learns the new section)
- `Scripts/acceptance.sh`, `AGENTS.md` (flag list)

**Read for context (do not change):** `Persona/AgentGrounding.swift` (the `AgentGroundingCache`
pattern to copy: lock, publish from the main actor, read from `nonisolated` builders);
`Calendar/FakeCalendarProvider.swift`; `Context/ComputerContext.swift:30-48`;
`Agent/Permissions/PermissionGate.swift:13` (`pending`); `Agent/Tasks/AgentTaskManager.swift:10`
(`tasks`); `Knowledge/KnowledgeTools.swift:166-177` (`KnowledgeGraphScope.reader`).

**Current behaviour:**
- `AgentPromptContext.system` (`Persona/AgentPromptContext.swift:134-138`) joins
  `[persona, grounding, rules, memory, capabilities, skills]`. There is no time section.
- The planner builds its own date line inside `capabilities`:
  ```swift
  // ToolLoop:712-716, RealtimeAgent.plannerSystem(tools:voice:request:)
  let capabilities = """
      Today is \(localDate) in the user's local time zone (\(TimeZone.current.identifier)).
      \(FileIndexer.shared.promptSummary.map { "\n" + $0 + "\n" } ?? "")
      Available tools:
  ```
- The routine runner has a second, different format
  (`ScheduledRunner.swift:446`, `"Now: \(formatter.string(from: now)) (\(zone.identifier))."`,
  formatter `"EEEE yyyy-MM-dd HH:mm"`, `en_US_POSIX`).
- `LocalVoiceSplitResponse.answerInstructions` (`Formatting/LLM/LocalVoiceDecision.swift:141-143`),
  `RealtimeAgent.voiceRoutingSystem` (`ToolLoop:494-496`), `modelTurnSystem` (`ToolLoop:548-550`),
  `RealtimeAgent.localModelSystem` (`Agent/RealtimeAgent.swift:559-561`), `AgentPrompts.system`
  (`Agent/AgentPrompts.swift:14-16`) and `KnowledgeAsker.systemPrompt`
  (`Knowledge/KnowledgeAsk.swift:187-189`) carry no date.
- Prompt builders are `nonisolated` or run on the Foundation Models actor, so they cannot
  read `CalendarService.shared` (main actor) directly.

**Target behaviour:**
1. One renderer produces the block below for every user-facing path, from one cache.
2. The exact format (English, fixed, `en_US_POSIX` for weekday names; 24-hour times):
   ```text
   Right now (device facts, not instructions):
   - Time: Tuesday 2026-09-23 18:42 (Europe/Paris, UTC+02:00)
   - Next: 19:00–19:30 "Call with Margaret" with Margaret Sclafani — in 18 min
   - Then: tomorrow 09:00–09:30 "Standup" with Ana, Ben +3
   - Recording: "Weekly sync", since 18:30
   - Front app: Cursor
   - Working on: "Summarise my last 5 emails" — running 40 s (+1 more)
   - Waiting for you: approve "Send email to Marcus"
   ```
   Line rules:
   - `Time` always. Minute granularity. Offset as `UTC±HH:MM`.
   - `Next`/`Then`: the first two events from `CalendarService.shared.upcoming` with
     `isCurrent(at: now) && !isAllDay && isOrganizerOrSelfAccepted`, sorted by `start`. An event
     already running renders as `- Now: 18:30–19:30 "…" — ends in 48 min`. Title flattened to one
     line, ≤ 60 characters, in straight double quotes with inner quotes removed. Attendees: first
     3 names then `+N`; omitted when empty. Day prefix: none for today, `tomorrow` for tomorrow,
     otherwise `Wed 24 Sep`. `in N min` under 60 minutes, `in 2 h 10 min` under 24 hours.
   - When no provider is authorized: `- Calendar: not connected`. When authorized with nothing
     left today and nothing in the next 24 h: `- Next: nothing in the next 24 hours`. Never
     claim an empty calendar when it is unknown.
   - `Recording`: only when `MeetingController.shared.session != nil`.
   - `Front app`: `NSWorkspace.shared.frontmostApplication?.localizedName`; omitted when it is
     Next Notes itself.
   - `Working on`: running items. Before P3-03, from `VoiceConversationCoordinator` running
     jobs plus `AgentTaskManager.shared.tasks` with a running status; after P3-03, from the
     `TaskBridge` ledger. Objective ≤ 60 characters. Never an id.
   - `Waiting for you`: `PermissionGate.shared.pending` title plus `queuedCount` as `(+N more)`.
     Never an id.
3. **Shapes and budgets** (characters of the whole block, measured; tokens ≈ chars / 4, estimate):

   | Shape | Lines | Cap | Paths (`AgentPromptPath`) |
   |---|---|---|---|
   | `.full` | all | 600 (~150 tok) | `.toolLoop`, `.localModel` |
   | `.compact` | Time, one Next/Now, Recording, Front app | 320 (~80 tok) | `.voiceAnswer` |
   | `.unattended` | Time, Next, Then, Recording | 400 (~100 tok) | `.scheduledRun` |
   | `.dateOnly` | Time | 90 | `.meetingAssistant`, `.knowledgeAsk` |
   | `.none` | — | 0 | `.voiceRoute`, `.acpAgent` |

   When over the cap, drop lines from the bottom up (Waiting, Working, Front app, Then), never
   `Time`.
4. **Cloud readers.** When `KnowledgeGraphScope.reader == .openRouter` (any cloud reader; P5
   binds the same value for cloud frontends), the block carries only `Time` unless the P4-09
   consent `Settings.agentCloudConsent` is on. Until P4-09 lands, treat that consent as `false`.
   A nil reader is treated as on-device for this block only: every nil-reader call site today is
   on-device (Apple voice lane, meeting prompts). Say this in a comment.
5. **Placement.** A new section 7 `now`, after `skills`, the last section of `system`. It is the
   most volatile section, so it must sit after the cacheable prefix.
6. **Cache and refresh policy.**
   - `AgentNowCache` holds the slow facts (events, recording title/start, front app, running
     work, approvals, calendar-authorized flag), each with the time it was published.
   - The clock is read at render time. Countdowns ("in 18 min") are computed at render from
     stored `start`/`end`, so a cached event never shows a stale countdown. Events whose `end`
     has passed are dropped at render.
   - Publish points (all main actor): `RealtimeAgent.publishGrounding()` (already runs before
     every typed turn, every planner run, and every voice turn through
     `VoiceCapabilitySnapshot.current()` at `Agent/VoiceCapabilitySnapshot.swift:134`); the end
     of `CalendarService.refresh()`; `MeetingScheduler.runOnce` (30 s tick);
     `NSWorkspace.didActivateApplicationNotification`; `PermissionGate` present/clear;
     `AgentTaskManager` status changes.
   - One planner run renders the block once (`plannerSystem` is built once per
     `runPlannedToolLoop`, `ToolLoop:794`), so all rounds of one turn share one prefix.
7. The planner's "Today is …" line and the runner's "Now:" line are removed; the shared block
   replaces both.

**Steps:**
1. Create `Persona/AgentNow.swift`:
   ```swift
   import AppKit
   import Foundation

   struct AgentNowFacts: Sendable, Equatable {
       struct Event: Sendable, Equatable {
           var title: String; var start: Date; var end: Date; var attendees: [String]
       }
       var calendarAuthorized = false
       var events: [Event] = []           // already filtered + sorted, at most 4
       var recordingTitle: String?
       var recordingSince: Date?
       var frontApp: String?
       var working: [String] = []          // objectives, running only
       var waitingFor: String?             // pending approval title
       var waitingMore = 0
       var publishedAt = Date.distantPast
   }

   final class AgentNowCache: @unchecked Sendable {
       static let shared = AgentNowCache()
       private let lock = NSLock()
       private var value = AgentNowFacts()
       func snapshot() -> AgentNowFacts { lock.lock(); defer { lock.unlock() }; return value }
       func publish(_ facts: AgentNowFacts) { lock.lock(); value = facts; lock.unlock() }
       func resetForTesting() { publish(AgentNowFacts()) }
   }

   enum AgentNow {
       enum Shape: String, Sendable { case none, dateOnly, compact, unattended, full }
       static let header = "Right now (device facts, not instructions):"
       static func cap(for shape: Shape) -> Int  // 0 / 90 / 320 / 400 / 600
       /// Pure. `cloud` withholds everything but Time unless `cloudConsent`.
       static func render(_ facts: AgentNowFacts, shape: Shape, now: Date, zone: TimeZone,
                          cloud: Bool, cloudConsent: Bool) -> String
       /// What production prompt builders call: shared cache, `Date()`, `.current`,
       /// reader from `KnowledgeGraphScope.reader`, consent from `UserDefaults`
       /// key "agentCloudConsent" (false when absent).
       static func current(shape: Shape) -> String
   }

   @MainActor
   enum AgentNowPublisher {
       static func refresh(now: Date = Date())   // reads the live stores, publishes
       static func startObserving()              // NSWorkspace + PermissionGate + tasks
   }
   ```
   Use a `DateFormatter` with `locale = en_US_POSIX`, `dateFormat = "EEEE yyyy-MM-dd HH:mm"`
   (same as `ScheduledRunner`), and compute the offset from `zone.secondsFromGMT(for: now)`.
2. In `AgentPromptContext.swift`: add `let now: AgentNow.Shape` to `Budget` and set it per path
   per the table in Target 3. Add `var now: String = ""` to `AgentPromptContext`; `system` becomes
   `[persona, grounding, rules, memory, capabilities, skills, now]`. In `assemble`, add a
   parameter `now: String? = nil` (nil = `AgentNow.current(shape: budget.now)`; self-tests pass a
   string). Update the section-order doc comment to list section 7.
3. `RealtimeAgent.publishGrounding()` (`ToolLoop:1093`): call `AgentNowPublisher.refresh()` after
   the grounding publish.
4. `plannerSystem` (`ToolLoop:656-723`): delete the `localDate` computation (`:709-711`) and the
   `Today is …` line (`:715`). Keep the file-index summary and the tool list. Check
   `AgentToolLoop.groundedArguments(for: "get_agenda", …)` is still used elsewhere before
   deleting anything else.
5. `ScheduledRunner` system builder (`:425-455`): delete the formatter and the `Now:` line; pass
   `now: AgentNow.render(AgentNowCache.shared.snapshot(), shape: .unattended, now: now,
   zone: zone, cloud: <reader is cloud>, cloudConsent: …)` so the runner's injected `now`/`zone`
   (its self-tests pin them) still win.
6. `CalendarService.refresh()` end and `MeetingScheduler.runOnce` end: call
   `AgentNowPublisher.refresh()`.
7. `NextNotesApp.swift`: call `AgentNowPublisher.startObserving()` next to
   `AgentScheduler.shared.start()` (`:317`).
8. `PersonaSelfTest.inOrder` (`Persona/PersonaSelfTest.swift:201-209`): append `context.now` to
   the ordered list.
9. Re-run `--selftest-toolloop`. Its size ceilings (`Agent/RealtimeAgentToolLoopSelfTest.swift:95-98`,
   planner `< 15_000`, voice first pass `< 4_500`; `:519-521`, typed first pass minus persona
   `< 1_500`) may need raising by exactly the shape cap (600). Raise by that amount only, with a
   comment naming P4-01.
10. Register `--selftest-now-block` in `runRequestedSelfTest`, add it to `AGENTS.md`'s list and to
    `Scripts/acceptance.sh` INTEGRATION as `"selftest-now-block|300"`.

**Do not:**
- Do not put the block before the rules or inside the persona: text after the rules is what a
  small model weighs, and the block is data, not instructions (its header says so).
- Do not read `CalendarService.shared` or `NSWorkspace` from a prompt builder; read the cache.
- Do not call a calendar provider from the renderer (no network, no EventKit on the prompt path).
- Do not include event descriptions, locations or conference URLs; titles and attendee names only.
- Do not render ids (task ids, proposal ids, event ids).
- Do not add the block to `.voiceRoute`: routing neither speaks nor needs the time.

**Red-first self-test:** `--selftest-now-block` in new `Persona/AgentNowSelfTest.swift`.
- Setup: build facts from `FakeCalendarProvider(now: t0).events(from: t0, to: t0 + 86_400)`
  (the provider `--fake-calendar` installs; building it directly lets `make acceptance` run the
  test without the flag), `recordingTitle = nil`, `frontApp = "Fixture App"`,
  `working = ["Fixture objective"]`, `waitingFor = "Fixture approval"`. Publish into
  `AgentNowCache.shared`; `resetForTesting()` at the end. No user store is touched.
- Assertions (today = `yyyy-MM-dd` of `Date()` in `.current`):
  1. contains today's date and `Fake meeting`: `RealtimeAgent.voiceRoutingSystem(voice: false)`
     (only if it still exists after P1-02), `RealtimeAgent.voiceRoutingSystem(voice: true)`,
     `RealtimeAgent.plannerSystem(tools: plannableTools(), voice: false)`,
     `RealtimeAgent.localModelSystem`, `LocalVoiceSplitResponse.answerInstructions`.
  2. contains today's date and not `Fake meeting`: `AgentPrompts.system`,
     `KnowledgeAsker.systemPrompt`.
  3. `ScheduledRunner`'s system (via its test constructor) contains `Fake meeting`, and not
     `Fixture App` or `Fixture approval`.
  4. `LocalVoiceSplitResponse.routeInstructions` does not contain `AgentNow.header`.
  5. Under `KnowledgeGraphScope.$reader.withValue(.openRouter)` with consent off, the planner
     prompt contains the date and not `Fake meeting`, `Fixture App`.
  6. Each rendered block ≤ its cap; `AgentNow.header` appears exactly once per prompt; the header
     index is after `AgentPromptContext.overrideLine` in every prompt that has rules.
  7. The planner prompt no longer contains `Today is`.
  8. `render` with an event whose `end < now` omits it; with `calendarAuthorized = false` prints
     `Calendar: not connected`.
- Markers: `NOW_BLOCK_OK` / `NOW_BLOCK_FAILED: <first failure>`; each failure also printed as
  `NOW_BLOCK_WRONG: …`.
- Red on unmodified code: write the test file first against a stub `AgentNow` that returns `""`;
  assertion 1 fails with "typed first pass lacks today's date".

**Verify:**
```bash
make build
make install OPEN=0
Scripts/run-selftest.sh --selftest-now-block
Scripts/run-selftest.sh --selftest-persona
Scripts/run-selftest.sh --selftest-toolloop
Scripts/run-selftest.sh --selftest-schedule
Scripts/run-selftest.sh --selftest-routine-authority
Scripts/run-selftest.sh --selftest-tool-awareness
Scripts/run-selftest.sh --selftest-toolloop-live      # record score before/after in STATUS.md
make acceptance TIER=core
```

**Success threshold:** `NOW_BLOCK_OK`; every regression flag above `*_OK`; live eval "What's the
date today?" and "What's next on my calendar?" pass; live eval total not lower than before by
more than one request; the typed first-pass prompt grows by ≤ 600 characters.

**Risks & rollback:**
- The voice frontend's speculation key (`LocalVoiceFrontend.RequestKey.system`,
  `Formatting/LLM/LocalVoiceFrontend.swift:38-60`) and the staged session change when the minute
  changes, so a speculation that straddles a minute boundary is discarded. Expected at most once
  per minute; P2-03's hit-rate log shows it. If the hit rate drops more than 10 points, move the
  compact block from the system prompt into the latest user message (after the
  `Work status` block) and keep the self-test assertions on the assembled messages.
- llama prefix reuse (P0-18) now stops at section 7. Check it with the `model.prefill` note
  (`reused=`) and the `cachedTokens` field of the per-pass `UsageRecord` rows P0-20 writes to the
  unified local usage log `usage.jsonl` (feature `agent.typed` / `agent.voice`; there is no
  `metrics.jsonl` span for this). If typed-turn first-token time
  rises by more than 150 ms in P2-01's spans, move the `.full` block into the latest user message
  the same way.
- Rollback: set every path's `now` shape to `.none` in `AgentPromptPath.budget`; the planner and
  runner lines must then be restored from git.

**Done when:**
- [ ] `AgentNow.swift` exists; `AgentNowPublisher.refresh()` has ≥ 5 production callers (grep)
- [ ] planner "Today is" and runner "Now:" lines are gone
- [ ] `NOW_BLOCK_OK`, regression flags OK, eval before/after recorded
- [ ] AGENTS.md flag list and acceptance INTEGRATION tier updated

---

### P4-02 — Router sees the previous exchange; a deflection re-routes once

**Finding(s):** Q5 (D §2.4, D-report item P1-9)  **Effort:** 1 day  **Depends on:** P2-02, P4-03  **Unblocks:** P4-06  **Keep:** P1-11's `ToolClaimGuard` and its history scrubbing. When the router sees the previous exchange, pass it through `ToolClaimGuard.scrubHistory`, so a past "I ran get_agenda…" is never shown as this turn's evidence (G N5).

**Why (what the user experiences today):** 09-14 20:52 "What about your tools?" got *"I couldn't
interpret that. Could you say it another way?"* four times; 09-14 22:48 *"I can help with
questions—what would you like to know?"* three times. The router is handed only the latest
utterance, so "use them", "the second one" and "what about your tools?" cannot be read. The
answer lane may not act, so it deflects.

**Files you will change:** `Formatting/LLM/LocalVoiceDecision.swift` (`routePlan`); `Agent/VoiceConversationCoordinator.swift` (deflection re-route); `Activation/VoiceTurnPolicy.swift` (`deflectionMarks`, `isDeflection`, `mayBeDeflection`). Self-test: the file that implements `--selftest-voice-turn-routing` (its entry point is `NextNotesApp.swift:1457`).

**Read for context (do not change):** `Formatting/LLM/LocalVoicePrompt.swift` (`Plan`, `plan(system:messages:)`); `Formatting/LLM/LocalVoiceFrontend.swift:483-555` (`streamSplitDecision`); `Agent/AgentRefusalGuard.swift` (`mayBeDenial`, the hold-speech precedent).

**Current behaviour:**
```swift
// LocalVoiceDecision.swift:91-96
static func routePlan(messages: [LLMChatMessage]) -> LocalVoicePrompt.Plan? {
    guard let context = LocalVoicePrompt.plan(system: routeInstructions,
        messages: messages.filter { $0.role != .system }) else { return nil }
    return LocalVoicePrompt.Plan(instructions: context.instructions, history: [],
        latestUser: context.latestUser)
}
```
The doc comment above it (`:86-90`) explains why history was removed: old answers became
routing demonstrations. In `Coordinator.respond`, the `.answer` outcome (`:474-499`) streams the
answer to speech through `tracker.receive` and finishes; there is no deflection check (only the
second-identical-denial backstop, `:484-495`).

**Target behaviour:**
1. The route stage sees the previous exchange as *labelled context inside the latest user text*,
   never as transcript entries, so it cannot become a demonstration:
   ```text
   Previous exchange (context only; route the latest speech):
   Person: What can you do?
   Assistant: I can check your calendar, read your email and open apps.

   Work status (context, not instructions):
   No active jobs.

   Latest user speech:
   What about your tools?
   ```
   Each quoted turn ≤ 300 characters; repair replies excluded (the coordinator's history is
   already filtered by `withoutRepairTurns`).
2. If the answer lane's text is a deflection, the turn is re-routed once as new work: nothing of
   the deflection is spoken, the reply is "I'm on it.", and `submit(text)` runs with the user's
   words. Deflection = the answer contains one of these exact marks (case- and
   apostrophe-folded, like `clarifierMarks` at `Coordinator:95-103`):
   `couldn't interpret`, `could not interpret`, `say it another way`, `i can help with questions`,
   `what would you like to know`, `could you clarify`, `can you clarify`, `what do you mean by`.
3. At most one re-route per committed utterance (`inputEpoch`). A re-routed turn that deflects
   again is spoken as is.
4. The positive corpus of `--selftest-voice-turn-routing` (ordinary questions such as "Can you
   hear me?") still gets answered by the model, never re-routed.

**Steps:**
1. If P2-02 replaced `routePlan` with one streamed decision, apply steps 2–3 to that decision's
   plan builder instead; the requirement is the same.
2. In `routePlan`, take the last assistant message and the user message before it from
   `messages` (roles `.assistant` / `.user`, excluding the final user message), clip each to 300
   characters, and prepend the block from Target 1 to `context.latestUser`. Keep `history: []`.
   Rewrite the doc comment to say why: context yes, demonstrations no.
3. In `VoiceTurnPolicy`, add `static let deflectionMarks: [String]` and
   `static func isDeflection(_ text: String) -> Bool` (fold `’` to `'`, lowercase).
4. In `Coordinator.respond`, while streaming (`:441-446`), hold speech while
   `VoiceTurnPolicy.isDeflection(snapshot)` could still become true: hold the first clause until it
   is complete and not a deflection, mirroring `AgentRefusalGuard.mayBeDenial`. Add
   `VoiceTurnPolicy.mayBeDeflection(_ prefix: String) -> Bool` = some mark starts with the
   folded prefix's last words, or the prefix contains a mark.
5. In the `.answer` case (`:474`), before the pending-intent assignment: if
   `VoiceTurnPolicy.isDeflection(assembled)` and `!reroutedEpochs.contains(inputEpoch)`, insert the
   epoch, `tracker.cancel()`, audit `detail: "deflection_reroute → newWork"` through the audit seam
   (P0-11), `resolveInput(epoch:)`, `submit(text)`, return `finishVoiceFrontend("I'm on it.", …)`.
   Clear `reroutedEpochs` in `closeSession`.

**Do not:**
- Do not add model answers to the route transcript's `history` (the reason `history: []` exists).
- Do not match deflections by length or token count; exact marks only (AGENTS.md, conversational
  gates).
- Do not suppress the model: this gate only adds a work route.
- Do not re-route a turn whose route was `describeCapabilities` or a status question about running
  work.

**Red-first self-test:** extend `--selftest-voice-turn-routing`.
- Case "previous exchange": fake history `[user "What can you do?", assistant "I can check your
  calendar, read your email and open apps."]`, latest "What about your tools?". Assert
  `LocalVoiceSplitResponse.routePlan(messages:)!.latestUser` contains `Previous exchange` and the
  assistant sentence, and `history.isEmpty`.
- Case "deflection re-route": fake frontend stream returns
  `"I couldn't interpret that. Could you say it another way?"`. Assert: one `submit` with the user's
  text (via the coordinator's `workerForTesting`), zero clauses spoken (tracker received nothing),
  reply `I'm on it.`.
- Case "no loop": the same deflection twice in one epoch → exactly one submit.
- Case "positive corpus": the existing ordinary questions return their model answers unchanged.
- Markers: the flag's existing `VOICE_TURN_ROUTING_OK` / `…_FAILED` lines (check the file for the
  exact prefix).
- Red today: the first case fails ("route plan has no previous exchange").

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-voice-turn-routing
Scripts/run-selftest.sh --selftest-voice-conversation
Scripts/run-selftest.sh --selftest-concurrent-voice
Scripts/run-selftest.sh --selftest-voice-frontend
Scripts/run-selftest.sh --selftest-toolloop-live      # the "what about your tools?" / "use them" case
make acceptance TIER=core
```

**Success threshold:** all four cases pass; the eval chain "What can you do?" → "what about your
tools?" → "use them" ends in a tool call; route stage output tokens unchanged (≤ 64).

**Risks & rollback:** longer route input adds prefill to the Apple model (≤ 600 characters,
~150 tokens estimate); P2-01's spans show it. A false deflection mark would turn an answer into
work: the marks are exact and the self-test's positive corpus guards it. Rollback: revert the two
files; the coordinator change is isolated to the `.answer` case.

**Done when:**
- [ ] route plan carries the labelled previous exchange; `history` still empty
- [ ] deflection re-route with speech held, once per epoch
- [ ] `--selftest-voice-turn-routing` OK with four new cases; eval case passes

---

### P4-03 — Prompt rewrite: one identity, typed depth, act on the likely reading, persona scoping, fuller voice card

**Finding(s):** Q2, Q3, Q4, Q6, Q8 (D §2.1–2.3, 2.6, 2.8, 2.9)  **Effort:** 1.5 days  **Depends on:** P1-01, P1-02, P1-03, P4-01  **Unblocks:** P4-02, P4-06  **Keep:** P1-11's guard. The rewritten prompts may say "never claim a tool you did not run this turn", but the post-generation `ToolClaimGuard` stays the backstop, and the live eval's `FABRICATED` count must not rise. This change touches every case, so it needs a **full** eval run, not only `--quick` (P1-01 step 8b).

**Why (what the user experiences today):** "Who am I?" on 09-23 17:18 got *"I'm Will, Serge's
autonomous alter ego…"*: up to four "You are …" statements compete in one prompt (D §2.1).
"What is the LLM under the hood?" got *"I don't have visibility into that detail"* because four
rules forbid naming models. "Remind me tomorrow at 9 to …" got a request for "the exact name of the
reminder" because the planner says to wait for a yes before `schedule.create`. The user's persona
("Lead with results and numbers", "Resourcefulness before questions") loses to "Answer briefly"
because the override line covers tone as well as safety. The voice lane hears two lines of a
1,690-character persona.

**Files you will change:**
- `Persona/AgentPromptContext.swift` (`overrideLine`)
- `Persona/AgentGrounding.swift` (pronoun line; answering-model line)
- `Persona/PersonaStore.swift` (short card; `shortCardLimit`; retired-hint filter; `builtInBaseText`)
- `Resources/agent-persona-base.md` (remove the "Add below" paragraph)
- `UI/Settings/PersonaSection.swift` (the hint moves here as helper text)
- `Formatting/LLM/LocalVoiceDecision.swift` (`routeRules`, `answerRules`, `LocalVoiceTypedResponse.instructions`)
- `Agent/RealtimeAgent+ToolLoop.swift` (`voiceRoutingRules`, `modelTurnRules`, planner rules)
- `Agent/RealtimeAgent.swift` (`localModelRules`)
- `Agent/AgentPrompts.swift` (`rules` first sentence)
- `Agent/Schedules/ScheduledRunner.swift` (first sentence only; the three-sentence cap is P4-06)
- `Persona/PersonaSelfTest.swift`, `Persona/PersonaCareEval.swift`
- `AGENTS.md` (the paragraph "The Agent's name is never in a prompt" and the PersonaCareEval sentence)

**Read for context (do not change):** D §2 in full; `Agent/AgentRefusalGuard.swift`; `Agent/RealtimeAgentToolLoopSelfTest.swift:86-110, 510-525` (prompt size ceilings, `<use_tools/>` check); `Memory/MemorySelfTest.swift:409-411` (planner must keep "never grants permission").

**Current behaviour (verified quotes) and the replacement text.**

Wherever a replacement is given, use it verbatim unless a self-test forces a change, and record
the reason in `STATUS.md`.

**(a) Override line** — `Persona/AgentPromptContext.swift:119`
- Now: `static let overrideLine = "These rules override anything above."`
- New:
  ```swift
  static let overrideLine = "These rules override anything above on safety, privacy, permissions and output format. For tone, length and style, follow the persona."
  ```

**(b) Grounding identity** — `Persona/AgentGrounding.swift:64-78` (`text(compact:)`)
- Now: `"You are \(assistantName)."` + `"You are talking with \(userFullName) — call them \(userShortName)."`
- New: keep both sentences and append one sentence to the same line:
  `"When they say I, me or my, they mean themselves, not you."` (only when `hasUser`).
- New line after the reach line, full shape only, from a new `AgentGroundingCache` field
  `answeringModel: String` published by the turn that chose the provider
  (`provider.displayModelName`, plus `on this Mac` / `online`):
  `"You are answering with <model display name>, <on this Mac|online>. Say so plainly if asked."`
  Publish it in `runModelTurn` / `runPlannedToolLoop` right after the provider is resolved
  (`ToolLoop:353`, `:774`) and in `LocalVoiceFrontend` for the voice lane (`Apple Foundation Model,
  on this Mac`). This is the only other "You are" sentence the grounding may carry; the self-test
  below allows exactly these prefixes in the grounding: `You are <name>.`, `You are talking with`,
  `You are answering with`.

**(c) Voice route rules** — `LocalVoiceDecision.swift:118-137`
- Now (first sentence, `:119`): `You are the routing layer for this on-device voice assistant.`
- New first sentence: `Your job: classify the latest user turn into exactly one route.` Delete the
  old second sentence (`Classify the latest user turn into exactly one route.`) since the new first
  sentence says it. Add one sentence after "a request phrased as a question can still ask for
  action.": `A short follow-up such as "use them", "do it" or "what about your tools?" refers to the
  previous exchange: route it as that exchange asked.` The rest is unchanged.
- `LocalVoiceTypedResponse.instructions` (`:37`, legacy probe only): `You are the decision layer for
  this on-device voice assistant.` → `Your job: decide how this app responds to the latest user turn.`

**(d) Voice answer rules (the voice card's rules)** — `LocalVoiceDecision.swift:145-156`
- Now:
  ```text
  Answer the latest user question naturally and briefly. Use your general
  knowledge for ordinary questions and advice. Use the supplied application
  facts only when relevant to a question about this app; a tool inventory
  is not an answer to an unrelated question. Use supplied work status for
  progress questions. Qualify application features needing setup or permission.
  Use everyday words and never mention tools, files, settings, models or
  anything technical; if something needs setting up, say what to do in the app
  in one short sentence. Be warm and personal, never flattering, and offer the
  useful next step when it helps. Return plain spoken prose only: no XML,
  labels, markdown, tool calls, routing discussion, or promises to perform work.
  ```
- New:
  ```text
  Your job this turn: answer the latest thing the person said, out loud. Lead with
  the answer. Keep it as short as the persona asks for spoken replies. Use your
  general knowledge for ordinary questions and advice. Use the supplied application
  facts and the Right now block for questions about this app, the time, the
  calendar or running work. Use supplied work status for progress questions. Use
  everyday words with no technical detail, except when the person asks about you:
  then name the model you run on, a folder or a setting plainly. If something
  needs setting up, say what to do in the app in one short sentence. Be warm and
  personal, never flattering. Return plain spoken prose only: no XML, labels,
  markdown, tool calls or routing discussion. Never claim that work was done.
  ```
  Changes: "briefly" defers to the persona; the tool-inventory sentence that produced "I don't have
  tasks or capabilities to list" is gone; "never mention … models" becomes "no technical detail,
  except when asked about you"; "promises to perform work" becomes "never claim that work was
  done" (P4-02 re-routes deflections, P4-06 adds offers). "no technical detail" stays verbatim for
  `PersonaCareEval`.

**(e) Tool-loop first pass** — `ToolLoop:498-537` (`voiceRoutingRules`). After P1-02 the typed
variant may be gone; rewrite whichever variants still exist.
- Now (`:500-501`): `You are a conversational assistant with tools for calendar, meeting notes,
  Gmail, Drive, Docs, local files, apps and browser pages.`
- New: `Your job this turn: answer, or hand the request to your tools. Your tools cover the
  person's calendar, meeting notes, Gmail, Drive, Docs, local files, apps and browser pages.`
  (After P1-03, generate the second sentence from `AgentCapabilityManifest`.)
- Now (`:535`, voice): `…Use one or two short natural sentences in everyday words, and never
  mention tools, files, settings or anything technical. …`
- New (voice): `Input is live microphone speech, and your reply is spoken aloud. Keep it as short as
  the persona asks for spoken replies, in everyday words with no technical detail unless the person
  asks about you. You received the user's spoken words. Questions about your voice refer to your own
  playback; do not guess an acoustic cause.`
- Now (`:535`, typed): `The answer is shown as text. Be concise, in everyday words, with no technical detail.`
- New (typed): `The answer is shown as text. Answer completely and directly: lead with the answer,
  then the specifics — names, numbers, dates. Use a short list when there are several items. Use
  everyday words with no technical detail unless the person asks about you, a file or a setting.`

**(f) `modelTurnRules`** — `ToolLoop:552-585` (no production caller; graded by
`RealtimeAgentToolLoopSelfTest.swift:330-430` and `PersonaSelfTest.swift:124`)
- Now (`:554`): `You are a conversational assistant. Answer the current user request in context.`
- New: `Your job this turn: answer the current user request in context.`
- Now (`:562`): `…Never invent a live fact, tool result, or completed action. Answer briefly.`
- New: `…Never invent a live fact, tool result, or completed action. Lead with the answer.`
- Now (`:564-566`): `Speak in everyday words and never expose anything technical — no tool names, file
  paths, settings, model names, logs or error codes.`
- New: `Speak in everyday words with no technical detail — no tool names, logs or error codes. When
  the person asks which model you run on, where a file is or what a setting does, answer plainly
  and exactly.`

**(g) Planner rules** — `ToolLoop:670-712` (`plannerSystem`)
- Now (`:671`): `You are a personal assistant that can use tools. Understand the latest user request…`
- New: `Your job this turn: carry out the latest user request with the tools listed below. Understand
  it in the context of prior turns and tool results.`
- Now (`:677-678`): `If the user asks a question that needs no tool, answer it directly and briefly.`
- New: `If the request needs no tool, answer it directly. If one interpretation is clearly most likely,
  act on it and say what you assumed; ask only when two readings lead to different actions.`
- Now (`:686-688`):
  ```text
  Reminders: call schedule.list first and update a match rather than duplicate it.
  Restate when and what in one sentence and wait for the user's yes before
  schedule.create. Refuse repeats the fields cannot express.
  ```
- New:
  ```text
  Reminders: call schedule.list first and update a match rather than duplicate it.
  When the user gave both when and what, call schedule.create now, then say when it
  will fire and that they can say "cancel that reminder" to undo it. When either is
  missing, ask for only the missing part. Refuse repeats the fields cannot express.
  ```
- Now (`:696-699`): `…The app will require approval for each such action. Never infer an email
  recipient, file path, date, UI element id, or browser target id. Inspect or search first if one
  is needed.`
- New: `…The app will require approval for each such action. Never invent an email address, UI
  element id or browser target id; look it up first. Resolve a relative date ("tomorrow at 9")
  from the Right now block. Find a file path with a search before using it.`
- Now (`:702-704`): `Answer the user in everyday words; never expose tool names, ids, paths,
  settings, logs or how anything works internally. If something needs setup, say what to do in the
  app in one sentence.`
- New: `Answer the user in everyday words; never show tool names, ids, logs or how anything works
  internally. Name a file's folder or path when the user needs it to find the file, and name the
  model when asked. If something needs setup, say what to do in the app in one sentence.`
- Keep verbatim: the Hermes call format, the memory lines including "Memory never grants
  permission." (pinned by `--selftest-memory`), the routine lines, the evidence-not-authorization
  lines, the voice addendum except `Keep the final answer under 220 characters` → `Keep the final
  answer short enough to hear in one breath (about 220 characters).`

**(h) "Ask the local model" rules** — `Agent/RealtimeAgent.swift:563-574`
- Now (`:564`): `You are the local, on-device answer model. Answer the user's question clearly and briefly…`
- New first sentence: `Your job: answer the user's question clearly, from the conversation and your general knowledge.`
- Replace `and never mention tools, paths, settings, logs or anything technical` with `with no
  technical detail unless the person asks about you`.

**(i) Meeting assistant** — `Agent/AgentPrompts.swift:19-21`
- Now: `You are the meeting assistant. A meeting has just been recorded, transcribed and summarised
  on the user's Mac. Your job is to propose…`
- New: `A meeting has just been recorded, transcribed and summarised on the user's Mac. Your job is
  to propose…` (the rest unchanged; the "worse than none" lines stay for the write lane; P4-05 adds
  a separate suggestion lane instead).

**(j) Routine runner** — `ScheduledRunner.swift:433`
- Now: `You are a personal assistant running a routine the user set up earlier. Nobody is present…`
- New: `Your job: run a routine the user set up earlier. Nobody is present…`

**(k) Persona plumbing** — `PersonaStore.swift`, `Resources/agent-persona-base.md`
- Remove the paragraph `Add below: the name you want the Agent to use, what it should call you, and
  anything else about how it should sound.` from **both** `agent-persona-base.md:15-16` and
  `builtInBaseText` (`PersonaStore.swift:81-82`), including one of the blank lines around it, so the
  two stay byte-identical. The first paragraph is not touched.
- Existing `persona.md` files seeded from the old preset still contain it and are never overwritten.
  Add `static let retiredHints = ["Add below: the name you want the Agent to use, what it should call
  you, and anything else\nabout how it should sound."]` and drop any paragraph equal to one of them
  (whitespace-folded comparison) in `fullCard(of:)` and `shortCard(of:)`. Prompt-only; the file is
  untouched.
- Move the hint to `UI/Settings/PersonaSection.swift` as helper text under the editor:
  `Add the name you want the Agent to use, what it should call you, and how it should sound.`
- **Fuller voice card.** `shortCard(of:)` (`:169-179`) returns the first paragraph plus the body of
  any Markdown section whose heading text, with `#`s, trailing `:` and surrounding spaces removed,
  equals `Voice` or `Rule of thumb` (case-insensitive). This user's file has `## Voice` (line 18)
  and `## Rule of thumb:` (line 26). Sections are joined with a blank line, in file order. Raise
  `shortCardLimit` from 400 to 800 (≈ 200 tokens, estimate; the voice answer's system prompt was
  ≈ 1,000 tokens, D §1; the window is 8,192 tokens measured on the dev Mac, read at runtime after
  P1-10a, not the 4,096 D assumed). The cap still backs off to a word boundary.
- The Settings editor already shows `Cut.cut` for what a path will not hear; also show a one-line
  caption in `PersonaSection`: `Voice replies hear your first paragraph and your "Voice" and "Rule of
  thumb" sections.`

**Target behaviour:** every assembled user-facing prompt has exactly one identity sentence, the
grounding's `You are <name>.` (plus the allowed `You are talking with` / `You are answering with`);
the base preset's first-paragraph role line (`You are a warm, personal assistant on this Mac.`) is
persona text the user owns and is allowed. Typed turns answer completely; the model name is sayable;
fully dictated reminders are created; the voice card carries the Voice section.

**Steps:** apply (a)–(k) in that order, building after each file. Then:
1. `PersonaSelfTest`: add checks (below).
2. `PersonaCareEval`: keep `plainWords = "no technical detail"` and `noFlattery`; add a check that
   `LocalVoiceSplitResponse.answerRules` and the planner rules both contain `unless the person asks
   about you` or `when the person asks` so the exception and the rule cannot drift apart.
3. `RealtimeAgentToolLoopSelfTest`: if a check quotes old rule text, update it to the new text; never
   delete a check.
4. AGENTS.md: in "The Agent's name is never in a prompt", replace the example list ("You are a warm,
   personal assistant on this Mac", "You are the meeting assistant", "You are a conversational
   assistant") with: "the fixed rules describe a job ('Your job this turn: …'), never an identity; the
   only 'You are' identity is the grounding's, and the persona preset's first line is the user's". In
   the PersonaCareEval sentence add "with the scoped exception when the person asks about the app".

**Do not:**
- Do not put the Agent's name, or "Next Notes", in any rule text.
- Do not edit the first paragraph of the base preset, and never edit one copy without the other.
- Do not remove "no technical detail" or "no filler or flattery" from the preset.
- Do not relax evidence/approval rules for writes that speak in the user's name (email, messages):
  those still go to the approval card. Only reminders the user fully dictated are created directly.
- Do not scope the override line away from safety, privacy, permissions or output format.
- Do not change `Memory never grants permission.` or the Hermes format line.

**Red-first self-test:** extend `--selftest-persona` (`Persona/PersonaSelfTest.swift`).
- For every entry in `productionPaths` (`:118-130`): count sentences starting with `You are ` in
  `entry.system` after removing the persona section (the `expected` persona string) — allowed
  prefixes are `You are <assistantName>.`, `You are talking with`, `You are answering with`. Fail on
  any other: `"\(entry.name) carries a second identity: <sentence>"`.
- `PersonaStore.baseText` does not contain `Add below`; a store seeded with the old preset text
  (literal copy in the test) yields a `fullPersona()` without it.
- A store saved with `"First para.\n\n## Core\nX.\n\n## Voice\nShort and warm.\n\n## Rule of thumb:\nAct first."`
  gives `shortCard()` == `"First para.\n\nShort and warm.\n\nAct first."` (headings dropped or kept —
  pick one, assert it). The base preset's short card is still exactly its first paragraph.
- `AgentPromptContext.overrideLine` contains `follow the persona`.
- Planner rules contain `call schedule.create now`; do not contain `wait for the user's yes before`.
- `answerRules` does not contain `never mention tools, files, settings, models`.
- Markers: `PERSONA_OK` / `PERSONA_FAILED` with `PERSONA_WRONG:` lines (existing).
- Red today: the first check fails on "tool loop first pass, voice carries a second identity: You
  are a conversational assistant…".

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-persona
Scripts/run-selftest.sh --selftest-toolloop
Scripts/run-selftest.sh --selftest-tool-awareness
Scripts/run-selftest.sh --selftest-voice-grounding
Scripts/run-selftest.sh --selftest-memory
Scripts/run-selftest.sh --selftest-schedule
Scripts/run-selftest.sh --selftest-ui-strings
Scripts/run-selftest.sh --selftest-toolloop-live      # "who am I?", "what model", reminder cases
make acceptance TIER=core
```

**Success threshold:** `PERSONA_OK`; live eval "Who am I?", "What model are you running on?" and
"Remind me tomorrow at 9 to call the bank" pass; eval total not lower than before by more than one;
`--selftest-tool-awareness` probes unchanged.

**Risks & rollback:** a small model may over-act on "act on the likely reading" — the eval's wrong-tool
check catches it; writes stay approval-gated. A longer voice card costs up to ~100 tokens of the
Apple window (estimate; the cost is latency, not room: the window is 8,192 tokens measured on the dev Mac); if `--selftest-voice-pipeline` first-token time rises > 100 ms, lower
`shortCardLimit` to 600. Each sub-change (a)–(k) is a separate commit so one can be reverted alone.

**Done when:**
- [ ] (a)–(k) applied; AGENTS.md updated
- [ ] `PERSONA_OK` with the new checks; `PersonaCareEval` exception check added
- [ ] eval cases pass; before/after scores in STATUS.md

---

### P4-04 — Pre-meeting brief on `meetingStarting`

**Finding(s):** Q12 (D §5 item 1, D-report item P2-16); H3 #18, #21, #22 (H-audit 2026-09-23)  **Effort:** 3.5 days  **Depends on:** P4-01, P0-11, P4-12 (H-audit 2026-09-23: routines and `meetingStarting` triggers need an Apple Intelligence route and a template-sized output budget; without P4-12 any model-phrased or user-created trigger brief skips on a Mac with no GGUF and no cloud); P3-04 for the spoken in-session path (without it, card and notification only — see Overview)  **Unblocks:** P4-05, P4-06, P4-13

**2026-10-01 execution checkpoint — bounded P4-04a (Steps 1/1b):** event-ready
assembly, reader-scaled limits and real-window propagation through the existing
notes/Agent context consumers are applied and frozen. The copied complete actual
assembler compiles in both modes: original `ae454a4` fails 9 strict assertions,
current passes the same dense 32768 fixture. Default brief length remains 2491
characters; the requested larger brief changes 2491 → 7894, passage fetch 10 → 40
and file request 5 → 20. The public tool 20-hit clamp remains unchanged. This is
producer evidence. Installed app12 notes-context, meeting-context, meeting-resume
and store-isolation pass, including current default/event equivalence and actual
NotesService.generate/provider-prompt/fresh-reader save/capture assertions;
Agent proof is its actual context method, not full review orchestration.
Isolation retains 21 files/31 defaults. The required completed fixed quick run
returns FAILED 3/10 in 129.9s on Gemma 4 E4B's local fallback, below the unchanged 9/10
bar and with the same ten case verdicts as complete app5. An earlier direct launch
stopped after 4 cases without a final marker/report; it remains explicitly
incomplete, cause unknown. Bounded steps 1/1b P4-04a is done under owner §4.1,
without quality/model/phase promotion or parent P4-04 completion.
Each context consumer adds a required existing-runtime
metadata await for the actual loaded window, with no extra model pass; no full
user latency claim. The parent P4-04 hosted trigger, conference URL propagation,
card/notification, policy/consent and fake-calendar chain remain open. Fixed
quick 9/10 and other phase gates are unchanged. See the
[reader-aware brief report](../../../Tests/Reports/agent-overhaul-closure/meeting-brief/2026-10-01-p4-04a-reader-aware-brief.md).

**Why (what the user experiences today):** nothing happens before a meeting. At the recipe audit,
`MeetingScheduler.runOnce` published every upcoming event within 120 minutes on each 30 s tick
(`AgentTriggerEvents.meetingsUpcoming`, `Agent/Schedules/AgentTriggerEvents.swift:230-237`), and the
only subscriber in the recipe's historical audit, `AgentScheduler.handleTriggerEvents`
(`Agent/Schedules/AgentScheduler.swift:794`), acted only on user-created trigger routines —
of which this Mac had zero at that audit. The upcoming 120-minute/routine observations
were not rerun by the installed context fixtures. `MeetingNotesBrief` already
assembles memory, prior decisions, graph connections, past passages and file names for a meeting
(`Meetings/MeetingNotesContext.swift:11-62`); existing notes generation and Agent meeting
follow-up review read it. The event assembly API added by P4-04a is verified through
fixtures; the proactive production host remains absent.

**Files you will change (new folder `Agent/Proactive/`):**
- new `Agent/Proactive/ProactiveService.swift` — `@MainActor final class ProactiveService`, the subscriber and policy
- new `Agent/Proactive/ProactiveBrief.swift` — pure builder
- new `Agent/Proactive/ProactiveLedger.swift` — once-per-key, daily caps, `proactive-ledger.json`
- new `Agent/Proactive/ProactiveSink.swift` — protocol + `LiveProactiveSink`
- new `Agent/Proactive/OwedItems.swift` — shared with P4-05 (created here, extended there)
- new `Agent/Proactive/ProactiveSelfTest.swift`
- `Meetings/MeetingNotesContext.swift` — add `brief(forEvent:reader:)`; reader-scaled caps (H-audit 2026-09-23)
- `Agent/AgentService.swift` (`knownContext`), `Meetings/NotesService.swift` — pass the reader window (H-audit 2026-09-23)
- `UI/DesignSystem.swift` — `DS.Motion.islandNoticeFor(text:)` and its three tokens (H-audit 2026-09-23)
- `UI/Island/IslandState.swift`, `UI/Island/IslandView.swift` — new card kind; `showAgentReply` duration
- `Support/Notifications.swift` — new category and actions
- `Support/Settings.swift` — new keys
- new `UI/Settings/ProactiveSection.swift`; `UI/Settings/AgentSettingsTab.swift` (insert it after `RemindersSection()`, `:26`)
- `NextNotesApp.swift` — start the service; register `--selftest-proactive`
- `Agent/Identity/AgentAvatarState.swift` if the island→avatar mapping lives there (grep `agentReply` → `.done`)
- `AGENTS.md`, `Scripts/acceptance.sh`

**Read for context (do not change):** `Agent/Schedules/AgentTriggerEvents.swift` (occurrence keys:
`starting:<identityKey>`); `Agent/Schedules/AgentScheduler.swift:6-67` (`ScheduleSettingsSnapshot.isQuiet`,
`ScheduleEnvironment`), `:1267-1315` (`LiveScheduleEnvironment`, `LiveScheduleDelivery`);
`Knowledge/KnowledgeExtractionService.swift:235-271` (`ActionItemReminders`); `Calendar/FakeCalendarProvider.swift`;
`UI/Island/IslandState.swift:355-398` (`push`, `showAgentReply`).

**Current behaviour:** described in Why. The island has no agent-authored notice kind
(`IslandState.Kind`, `:69-110`: `agentReply(String)` is the closest, and it has no buttons).
Notifications have categories `meetingArmed`, `notesReady`, `agentProposal`, `agentReview`,
`agentRoutine`, `agentRoutineApproval` (`Support/Notifications.swift:369-380`).

**Target behaviour:**
1. **Trigger.** `ProactiveService` subscribes to `AgentTriggerEvents.shared` (its own subscription;
   `publish` fans out to every handler, `:215-218`). For each `.meetingStarting` occurrence with
   `start - now` in **[3 min, 5 min]** it builds and delivers one brief. First seen in (1 min, 3 min)
   → still delivered ("starting in 2 minutes"). ≤ 1 min or already started → recorded as skipped,
   never delivered. > 5 min → ignored this tick (asked again next tick).
2. **What qualifies.** `attendees` non-empty (a solo block gets no brief), not all-day (already
   filtered upstream), and the brief has at least one line beyond title/time/attendees **or** the
   event has a conference URL. Otherwise silence.
3. **Data assembled** (`ProactiveBrief.build`):
   - Event: title, start, attendees (from the occurrence).
   - `MeetingNotesContextAssembler.live.brief(forEvent:reader:)` with `reader: .appLLM` for the
     deterministic on-device render. It returns the same five sections, each behind its own switch.
   - Owed items: open items the user owns that mention an attendee or the title (from
     `OwedItems.open(matching:)`, reading P4-05's `suggestions.json` files and, when the graph is on,
     `graph.actionItems()` filtered by `ActionItemReminders.isUser`).
   - Rendering (deterministic, no model): at most 3 lines, each ≤ 140 characters:
     ```text
     Call with Margaret in 4 minutes — Margaret Sclafani, Ana Ruiz.
     Still open: you said you'd send the safety-light pricing (Tue).
     Last time: agreed to move the launch to October.
     ```
     Line 2 = first owed item; line 3 = first decision from `brief.decisions`, else first memory
     line, else omitted. No passages, no file names on the card (they stay one click away in the
     meeting).
4. **Where it surfaces.**
   - Island: new `IslandState.Kind.agentHeadsUp(IslandHeadsUp)` pushed with
     `DS.Motion.islandNoticeFor(text:)` (see Target 9), **not** the fixed 8 s
     `DS.Motion.islandNotice`. `IslandHeadsUp { id: String; title: String; lines: [String];
     primary: HeadsUpAction?; secondary: HeadsUpAction?; meetingID: UUID? }`,
     `HeadsUpAction { case openMeeting(eventKey), yes(offerID), notNow(id), turnOff(kind) }`. For a
     brief: primary "Open", secondary "Not now". The first brief ever also shows "Turn off" in the
     expanded card.
   - Avatar: `agentHeadsUp` wears the character (it is the agent speaking first): `.waiting` when the
     card carries a yes/no offer, `.done` otherwise. Extend `--selftest-avatar`'s mapping check.
   - Notification: category `agentHeadsUp`, actions `headsUp.open` / `headsUp.notNow`, identifier
     `headsup-<key>` so a repeat replaces rather than stacks.
   - Agent conversation: `AgentSession.shared.recordAssistant(text, contextKind: "proactive")` so a
     follow-up ("tell me more") has context. The memory review must skip `contextKind == "proactive"`
     rows (it learns from the user only).
   - Speech: see the Overview. Before P3-04: never in a live voice session; outside one only when the
     setting is `showAndSpeak` and `LiveScheduleEnvironment` says present and idle. After P3-04: in a
     live session, `OutputScheduler.shared.enqueue(DeliveryItem(…, kind: .proactive, …))` (see the Overview; this
     task adds `DeliveryKind.proactive`).
5. **Caps.** Once per occurrence key (ledger). At most 8 briefs per local day. None inside quiet hours
   (`ScheduleSettingsSnapshot.fromSettings().isQuiet(now)`), recorded as skipped. While another meeting
   is recording: card only, never spoken. While dictating: deferred until dictation ends if still ≥ 1
   min before start, else skipped.
6. **Opt-out.** `Settings.agentMeetingBriefs: String` — `"off" | "show" | "showAndSpeak"`, key
   `agentMeetingBriefs`, default `"show"`. UI in `ProactiveSection` ("Heads-ups").
7. **Consent.** The deterministic card is rendered on this Mac and shown to the user: every section
   may appear. When the brief is phrased by a model (only after P3-04, by the frontend), assemble with
   that model's reader: `brief(forEvent:reader: <frontend reader>)` — the graph reaches a cloud reader
   only with `graphCloudConsent`, file names only with the file index's cloud consent, and nothing at
   all reaches a cloud reader without P4-09's `agentCloudConsent`. A brief assembled for a local reader
   is never reused for a cloud one (AGENTS.md "Related-context brief"): cache briefs keyed by
   `(occurrence key, reader class)`.
8. **Strings** (no developer words): section title `Heads-ups`; rows `Before meetings` — "A short note a
   few minutes before a meeting: who's coming and what's still open."; picker `Off` / `Show it` / `Show
   and say it`; card buttons `Open`, `Not now`, `Turn off`.
9. **Reading time, not a fixed 8 s (H-audit 2026-09-23, H3 #21, #22).** Today every island notice
   lasts `DS.Motion.islandNotice = 8` s (`UI/DesignSystem.swift:784`), including
   `IslandState.showAgentReply` (`UI/Island/IslandState.swift:395-397`:
   `push(.agentReply(text), for: DS.Motion.islandNotice)`). A 300-character reply takes about 15 s
   to read (estimate, H3 #21). Add to `DS.Motion`:
   ```swift
   static let islandNoticeMinimum: TimeInterval = 8
   static let islandNoticeMaximum: TimeInterval = 30
   static let islandNoticePerCharacter: TimeInterval = 0.05
   static func islandNoticeFor(text: String) -> TimeInterval {
       min(islandNoticeMaximum, max(islandNoticeMinimum, islandNoticeMinimum + islandNoticePerCharacter * Double(text.count)))
   }
   ```
   `agentHeadsUp` passes the card's title + lines joined; `showAgentReply` passes its text. Every other
   `push` keeps `islandNotice` (proposals are P1-16's). Hover still pauses the countdown.
10. **Brief caps scale with the reader (H-audit 2026-09-23, H3 #18).** `MeetingNotesContextAssembler`
    caps are fixed (`Meetings/MeetingNotesContext.swift:104-113`: `maxMemoryCharacters = 700`,
    `maxDecisionCharacters = 500`, `maxConnectionCharacters = 400`, `maxPassageCharacters = 900`,
    `maxFileCharacters = 300`, `passageLimit = 3`, `fileLimit = 5`). The model readers already cut the brief
    to their window (`MeetingAgent.briefShare`, `Agent/MeetingAgent.swift:69`), so on a 32K+ reader these
    caps only waste room. Multiply each character cap and each count by
    `scale = max(1, contextTokens / 8_192)` (integer division; 32K reader → ×4). The deterministic island
    card of this task still renders at most 3 lines × 140 characters regardless of scale.

**Steps:**
1. `MeetingNotesContextAssembler`: add
   ```swift
   func brief(forEvent title: String, attendees: [String], excluding: UUID? = nil,
              reader: LLMProviderID) async -> MeetingNotesBrief
   ```
   by factoring the body of `brief(for meeting:reader:)` (`:124` on 2026-09-24) into a private helper that takes
   `(query, fileQuery, excluding)`; `brief(for:)` calls it. No behaviour change for notes
   (`--selftest-notes-context` must stay OK).
1b. (H-audit 2026-09-23) Add `contextTokens: Int = 8_192` to both `brief(for:reader:)` and
   `brief(forEvent:…)`; inside, compute `let scale = max(1, contextTokens / 8_192)` and use
   `Self.maxMemoryCharacters * scale` etc. (Target 10). Pass the reader's real window from the two existing
   callers: `AgentService.knownContext` (`Agent/AgentService.swift:288`) and `NotesService`
   (`Meetings/NotesService.swift:116`), each with `await AgentAnswerBudget.readerContextTokens(for: provider)`
   (`Agent/AgentAnswerBudget.swift:54`). With the default 8,192 nothing changes for the self-tests.
1c. (H-audit 2026-09-23) Add `DS.Motion.islandNoticeFor(text:)` (Target 9) and change
   `IslandState.showAgentReply` to use it.
2. `ProactiveLedger` (`@MainActor final class`, `static let shared` isolated under `SelfTest.isRunning`
   to a temp directory, exactly like `ScheduleStore.shared`, `Agent/Schedules/ScheduleStore.swift:17-25`):
   ```swift
   struct Entry: Codable { let key: String; let kind: String; let at: Date; let outcome: String }
   func hasHandled(_ key: String) -> Bool
   func record(_ key: String, kind: ProactiveKind, outcome: String, at: Date)  // "shown"/"spoken"/"skipped:<reason>"
   func count(kind: ProactiveKind, onDayOf: Date, zone: TimeZone) -> Int
   ```
   File `proactive-ledger.json`, atomic writes, entries older than 30 days pruned on save.
3. `ProactiveSink` protocol (the seam every self-test fakes):
   ```swift
   @MainActor protocol ProactiveSink: AnyObject {
       func show(_ card: IslandHeadsUp)
       func notify(_ card: IslandHeadsUp) async
       func speak(_ text: String, kind: ProactiveKind)      // routes per the Overview rule
       func record(_ text: String, kind: ProactiveKind)     // AgentSession + audit, through P0-11 seams
       var voiceSessionActive: Bool { get }
   }
   ```
   `LiveProactiveSink` implements it with `IslandState.shared`, `Notifications.shared`,
   `AgentSpeechSynthesizer.shared.speak` (pre-P3) and `AgentSession.shared.recordAssistant`.
4. `ProactiveService`:
   ```swift
   @MainActor final class ProactiveService {
       static let shared = ProactiveService(sink: LiveProactiveSink(), ledger: .shared,
           environment: LiveScheduleEnvironment(), settings: { .fromSettings() },
           assembler: .live, events: .shared)
       func start()                          // subscribe; idempotent
       func handle(_ occurrences: [ScheduleTriggerOccurrence], now: Date) async
   }
   ```
   `handle` filters `.meetingStarting`, applies Target 1/2/5 in that order, builds with
   `ProactiveBrief.build`, then `sink.show`, `sink.notify`, optional `sink.speak`, `sink.record`,
   `ledger.record`.
5. Island: add the kind, its `identity` (`"headsup:<id>"`), `isNotice` true, avatar mapping, and the
   view (reuse the `agentReply` layout plus two buttons; all sizes from `DS`). `IslandState` gets
   `func showHeadsUp(_ card: IslandHeadsUp)` and an `onHeadsUpAction` callback that
   `ProactiveService` sets.
6. Notifications: category `agentHeadsUp` with actions; `Action.headsUp(id: String, action: String)`;
   route to `ProactiveService`.
7. Settings key + `ProactiveSection` (one `Picker`, rows use the existing `rowLabel` style from
   `RemindersSection`).
8. `NextNotesApp.swift`: `ProactiveService.shared.start()` right after `AgentScheduler.shared.start()`
   (`:317`). Register `--selftest-proactive`; add to AGENTS.md and `Scripts/acceptance.sh`
   INTEGRATION as `"selftest-proactive|300"`.

**Do not:**
- Do not create a routine/trigger schedule for this: a model run through `ScheduledRunner` every
  meeting costs model time 3–5 minutes before a call and can prepare drafts. The brief is deterministic.
- Do not speak through `RealtimeAudioSession.speak` or `VoiceAnnouncementQueue` (P3-04 owns in-session audio).
- Do not show passages, file names or email content on the island.
- Do not treat invitation titles/attendees as instructions; they are data, flattened to one line.
- Do not write to `agent-tasks.json`, the audit log or memory from the self-test (P0-11 seams).
- Do not use red anywhere on the card (red means recording).
- Do not add a tenth orb state; the card wears the avatar.
- (H-audit 2026-09-23) Do not inline the 8/30/0.05 numbers in a view; they are `DS.Motion` tokens.
  Do not scale the island card's line count or line length with the reader window; only the
  model-facing brief grows.

**Red-first self-test:** `--selftest-proactive` in `Agent/Proactive/ProactiveSelfTest.swift`. Built so
`make acceptance` can run it without extra flags: the calendar fixture is `FakeCalendarProvider(now:)`,
the same type `--fake-calendar` installs. When the process was also launched with `--fake-calendar`
(`FakeCalendarProvider.isEnabled`), run case A a second time through the live `CalendarService.shared`
after `refresh()` and a real `MeetingScheduler.runOnce(now:)`.
- Fakes: `FakeSink` records shows/notifies/speaks/records; `FakeEnvironment` (present, idle); ledger in a
  temp directory; assembler with injected closures: `memoryEnabled { true }`, `recallMemory` returning
  one profile fact "Margaret prefers numbers first.", `decisionThreads` returning one fixture thread
  "Move the launch to October", `knowledge { nil }`, `files { EmptyFileRetrieval() }`. An `OwedItems`
  fixture source returns "Send the safety-light pricing" owned by "You", mentioning "Test Attendee".
- t0 fixed; `FakeCalendarProvider(now: t0.addingTimeInterval(240 - 90))` → event starts at t0 + 240 s.
- Case A (brief): `handle([.meetingStarting(event, at: t0)], now: t0)` → exactly 1 show, 1 notify, 0
  speak (setting `show`), 1 record; card lines contain `Fake meeting`, `in 4 minutes`, `Test Attendee`,
  `safety-light pricing`, `launch to October`.
- Case B (once): the same occurrence at t0 + 30 s → still 1 show.
- Case C (too early / too late): a second fixture starting at t0 + 10 min → 0 shows at t0; one starting
  at t0 + 40 s → 0 shows and a ledger entry `skipped:too-late`.
- Case D (quiet hours): settings with quiet hours covering t0 → 0 shows, ledger `skipped:quiet`.
- Case E (voice session): `voiceSessionActive = true`, setting `showAndSpeak`, P3-04 not present → 1
  show, 0 speak.
- Case F (cloud reader): `ProactiveBrief.build(…, reader: .openRouter)` with `graphCloudConsent false` →
  the decisions closure was never called (counter 0) and no decision line.
- Case G (solo block): attendees empty → 0 shows.
- Case H (off): setting `off` → 0 shows, 0 ledger entries.
- Case H2 (reading time, H-audit 2026-09-23): `DS.Motion.islandNoticeFor(text:)` returns 8 for a
  0-character text, 23 for 300 characters, 30 for 1,000 characters; the Case A card was pushed with
  `islandNoticeFor` of its text, not 8 (the fake sink records the duration).
- Case H3 (brief scale, H-audit 2026-09-23): the assembler with a memory closure returning 3,000
  characters gives a memory section ≤ 700 characters at `contextTokens: 4_096` and ≤ 2,800 at
  `contextTokens: 32_768`; at 8,192 the brief is byte-identical to the unscaled one.
- Markers: `PROACTIVE_OK` / `PROACTIVE_FAILED: <case>: <reason>`, each failure as `PROACTIVE_WRONG: …`.
  No model is used, so there is no `_ABSENT`.
- Red: commit the test with `ProactiveService.handle` as an empty body → Case A fails "0 cards".

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-proactive
Scripts/run-selftest.sh --selftest-proactive --fake-calendar
Scripts/run-selftest.sh --selftest-notes-context
Scripts/run-selftest.sh --selftest-island
Scripts/run-selftest.sh --selftest-avatar
Scripts/run-selftest.sh --selftest-schedule
Scripts/run-selftest.sh --selftest-ui-strings
make acceptance TIER=core
```

**Success threshold:** all eight cases (plus H2 and H3, H-audit 2026-09-23) pass in both runs; the brief is built in < 50 ms on fixtures
(print `PROACTIVE_BRIEF_MS`); zero speech in a live voice session before P3-04.

**Risks & rollback:** a brief for every meeting may annoy → default is card-only, one per meeting,
"Turn off" on the first card, 8/day cap. A mis-parsed occurrence could show a brief for a declined
meeting → upstream filter `isOrganizerOrSelfAccepted` already drops declines. Rollback: set the
default of `agentMeetingBriefs` to `"off"` (one line) or remove the `start()` call.

**Done when:**
- [ ] `ProactiveService.start()` has a production caller; `handle` reachable from a real
      `MeetingScheduler.runOnce` (the `--fake-calendar` run proves it)
- [ ] island kind, notification category, setting and section in place; ui-strings OK
- [ ] `PROACTIVE_OK` in both runs; AGENTS.md and acceptance updated
- [ ] (H-audit 2026-09-23) `islandNoticeFor(text:)` used by the heads-up card and `showAgentReply`;
      brief caps scale with the reader window; Cases H2 and H3 pass

---

### P4-05 — Post-meeting "what you owe" wrap and a suggestion lane

**Finding(s):** Q12 (D §2.10, §5 item 2, D-report item P2-17); H1 #25 (H-audit 2026-09-23)  **Effort:** 2.5 days  **Depends on:** P4-04, P4-10 (H-audit 2026-09-23: the proposal lane must first be able to run on a small window and record why it failed), P0-20b (the `meeting.proposals` usage rows)  **Unblocks:** P4-06, P4-13

**Read the usage rows first (H-audit 2026-09-23, H1 #25).** Before changing any gate or prompt line in
this task, read P0-20b's `meeting.proposals` rows in `~/Library/Application Support/Next Notes/usage.jsonl`
(read-only: `grep '"feature":"meeting.proposals"' "$HOME/Library/Application Support/Next Notes/usage.jsonl" | tail -20`)
and paste into `STATUS.md` a count per outcome: provider, `counts.rounds`, `counts.calls`,
`counts.proposals`, `counts.refusals`, `errorClass`. If P4-10 has landed, most rows should have no
`errorClass`; if `contextTooSmall` still dominates, stop and reopen P4-10 rather than adding the wrap on
top of a lane that never runs. The wrap below does not depend on the model, but the "Draft it" offer does.

**Why (what the user experiences today):** 6 meetings, 0 `proposals.json`. The meeting prompt is
written to under-propose (`Agent/AgentPrompts.swift:24-25`: "A follow-up nobody asked for is worse
than none." / "At most 3 actions. Usually one or two; often zero.") and every write needs an exact
transcript quote (`:40-42`). That is right for writes, but there is no lane to say "you owe Dad the
DIKAD numbers by Friday" without writing anything. Owed items appear only if the user opens Knowledge ▸
decision thread (`UI/Knowledge/DecisionThreadView.swift:230-249`), and only with the graph on (off by
default).

**Files you will change:** `Agent/Proactive/OwedItems.swift` (notes parser); new
`Agent/Proactive/MeetingSuggestionStore.swift`; `Agent/Proactive/ProactiveService.swift`
(`meetingWrapped`); `Meetings/NotesService.swift` (call site); `Support/Notifications.swift` (notes-ready
body line); `Support/Settings.swift` (`agentMeetingWrap`); `UI/Settings/ProactiveSection.swift` (row);
`UI/Meetings/MeetingActionsView.swift` (or `MeetingDetailView.swift`, whichever lists proposals) gets a
"You said you'd" list; `Agent/Proactive/ProactiveSelfTest.swift` (cases).

**Read for context (do not change):** `Meetings/NotesPrompts.swift:14-21, 44-47` (the fixed "## Action
items" shape `- **<speaker>** — <what they will do>`, "You" = the person recording, `**Unassigned**`
when nobody took it); `Meetings/NotesService.swift:163-183` (the automatic-pass branch);
`Meetings/MeetingStore.swift:241` (`notes(for:)`), `:390` (`notesFile`); `Agent/MeetingAgent.swift`
(the proposal lane, unchanged); `Knowledge/KnowledgeExtractionService.swift:228-233`
(`reminderArguments` for a 09:00 one-off reminder).

**Current behaviour:** `NotesService` automatic pass, after notes are written
(`Meetings/NotesService.swift:172-182`):
```swift
if announce { AgentService.shared.review(finished) }
if announce, model != nil {
    Notifications.shared.postNotesReady(meeting: finished, model: model)
    IslandState.shared.announceNotesReady(finished)
    AgentTriggerEvents.shared.notesReady(finished)
}
```
Nothing reads the "## Action items" section for the user's own items.

**Target behaviour:**
1. `OwedItems.parse(notesMarkdown:userNames:) -> [OwedItem]`: reads the `## Action items` section,
   bullets `- **<owner>** — <text>`; keeps owners where `ActionItemReminders.isUser(owner, names:)`
   (`you`, `me`, `i`, `myself`, and the account's first/full name). Due date: a trailing date phrase
   the notes model was told to end the sentence with ("by Friday", "on 2026-09-30", "tomorrow") parsed
   with `NSDataDetector` relative to the meeting's `start`; nil when absent. `_None._` → empty.
   `OwedItem { id: "<meetingID>#<sha1 of normalized text>", text, due: Date?, meetingID, meetingTitle, attendees }`.
2. **Suggestion lane.** Beside the evidence-gated proposal lane, a meeting folder gets
   `suggestions.json`: `[MeetingSuggestion { id, kind: .owed, text, due, createdAt, state:
   .open|.remindSet|.dismissed|.done, offer: SuggestionOffer? }]`. `SuggestionOffer { request: String,
   capability: String }` is a natural-language request the user can accept ("Draft an email to Dad with
   the DIKAD numbers"), with `capability` a manifest capability id (P1-03) — never a tool call and never
   arguments. Offers are created only when the owed text starts with a verb the manifest can serve
   (send/email/share → `draft_email`; schedule/book → `create_event`; otherwise no offer).
   All new `Codable` fields use `decodeIfPresent`.
3. **Wrap.** On the automatic pass with notes written, `NotesService` calls
   `ProactiveService.shared.meetingWrapped(finished)` **instead of** `IslandState.shared.announceNotesReady`
   when the meeting has ≥ 1 owed item and `agentMeetingWrap` is on; otherwise it keeps the current call.
   The wrap card: title = meeting title; lines = "Notes are ready." + up to 2 owed items as "You said
   you'd <text> (<due>)."; buttons: body click opens the notes; `Remind me` (creates a reminder per item
   through `ScheduleToolExecutor.run` with `schedule.create` and `OwedItem.reminderArguments`, the
   user's click being the yes); `Draft it` only when an offer exists (submits `offer.request` as a user
   turn to `RealtimeAgent.shared` — typed path — so any write still goes to the approval card);
   `Not now`.
4. The notes-ready notification body appends `You said you'd: <first item>.` when there is one.
5. Once per meeting id (ledger key `wrap:<meetingID>`). Regenerate never wraps (`announce == false`).
   Quiet hours: card waits until they end (store as pending in the ledger and show on the next
   `ProactiveService` tick after quiet end) — notes often land late in the evening.
6. The wrap never proposes a write and never calls `AgentToolExecutor` or `PermissionGate`.
7. Opt-out: `Settings.agentMeetingWrap: Bool` key `agentMeetingWrap`, default `true`. Row: `After meetings`
   — "What you said you'd do, once the notes are ready."
8. Speech: same Overview rule; the spoken form is "Notes from <title> are ready. You said you'd <first item>."
9. **(OpenMuse 2026-09-27) An owed item that looks done is not nudged.** OpenMuse's "Ideas" drop a
   suggestion once the matching reply was sent or the matching work completed, and it shipped with
   a regression test because the first version re-suggested finished work. Here the evidence is
   already local: `ActionReceiptStore` (`Agent/ActionRuntime.swift:329`). An `.open` suggestion with
   an offer is **looks done** when a receipt exists that is `.completed`, started after the
   meeting's `end`, ran the offer's capability, and names one of the meeting's attendees in its
   arguments. A looks-done item is never nudged (P4-06) and never repeated in a brief (P4-04); in
   the meeting's list it reads "Looks done: <the receipt's own title>, Tuesday." (for example
   "Looks done: email to Margaret drafted, Tuesday." — a draft is never described as sent) with
   `Done` and `Still open`. It is **never** marked `.done` by the app — the match shows a connection rather
   than claiming one, the same rule as the memory overlay's `remembered_as` edges (AGENTS.md
   "Memories are drawn onto the graph"). An item with no offer has no evidence to match and stays
   as it is.

**Steps:**
1. Implement `OwedItems.parse` with a line-based reader (find the `## Action items` heading, stop at the
   next `## `). Owner regex `^- \*\*(?<owner>[^*]+)\*\*\s+[—-]\s+(?<text>.+)$` (safe regex subset).
2. `MeetingSuggestionStore`: `load(meetingID) -> [MeetingSuggestion]`, `save(_:for:)` into
   `MeetingStore.shared.directory(for:)/suggestions.json`, atomic. Under `SelfTest.isRunning` the
   self-test passes its own directory; the store takes `directory: URL` in `init`.
3. `ProactiveService.meetingWrapped(_ meeting: Meeting)`: read notes via `MeetingStore.shared.notes(for:)`,
   parse, merge with existing suggestions (by id; never resurrect `.dismissed`), save, build the card, deliver
   through the sink.
4. `OwedItems.open(matching attendees: [String], title: String) -> [OwedItem]` (used by P4-04): scan the
   last 60 days of meetings' `suggestions.json` for `.open` items whose meeting shares an attendee (folded
   compare) or ≥ 1 title word ≥ 4 characters; plus graph items when the graph is on.
5. `NotesService`: replace the `announceNotesReady` line with
   `if !ProactiveService.shared.meetingWrapped(finished) { IslandState.shared.announceNotesReady(finished) }`
   (`meetingWrapped` returns `true` when it showed a card).
6. Meeting detail view: list open suggestions under a `You said you'd` heading with `Remind me`, `Done`,
   `Dismiss` buttons. Strings contain no ids.

**Do not:**
- Do not change the proposal lane's rules (`AgentPrompts.rules`) beyond P4-03(i); suggestions are a
  separate lane.
- Do not use a model to find owed items; the notes model already wrote them in a fixed shape.
- Do not invent owners or dates ("Unassigned" is not the user).
- Do not auto-create reminders; a click creates them.
- Do not let a meeting with `audioIsTemporary` release logic depend on this (it does not read audio).

**Red-first self-test:** extend `--selftest-proactive`.
- Fixture meeting in a temp `MeetingStore` directory with `notes.md`:
  ```markdown
  ## Action items
  - **You** — Send Margaret the deck by Friday.
  - **Margaret** — Review the pricing.
  - **Unassigned** — Book the room.
  ```
- Case I (wrap): `meetingWrapped(meeting)` → returns true; 1 show whose lines contain `Send Margaret the
  deck` and not `Review the pricing` or `Book the room`; `suggestions.json` has exactly 1 `.open` item with a
  non-nil `due`; an injected executor counter for `AgentToolExecutor` = 0; `PermissionGate.shared.askCount`
  unchanged; no `proposals.json` written.
- Case J (once): a second call → no new show, still 1 suggestion.
- Case K (no owed items): notes with only `**Margaret**` items → returns false (caller keeps the notes-ready card).
- Case L (dismissed stays dismissed): mark dismissed, re-run → still dismissed, no show.
- Case M (brief uses it): P4-04's Case A with this meeting as the owed source contains `Send Margaret the deck`.
- Case N (OpenMuse 2026-09-27, looks done): seed a `.completed` `draft_email` receipt after the
  meeting's end whose `to` names Margaret → the suggestion stays `.open`, `looksDone` is true, P4-06's
  nudge candidate list excludes it, and the row's sentence names the receipt's day; the same receipt
  dated *before* the meeting → `looksDone` false.
- Red: before step 5, Case I fails ("meetingWrapped returned false").

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-proactive
Scripts/run-selftest.sh --selftest-notes-context
Scripts/run-selftest.sh --selftest-agent "$HOME/Library/Application Support/Next Notes/Meetings/<a meeting folder>"   # read-only proposal pass unchanged
Scripts/run-selftest.sh --selftest-ui-strings
make acceptance TIER=core
```
(Pick any existing meeting folder for `--selftest-agent`; it reads, it does not write.)

**Success threshold:** Cases I–M pass; 0 tool executions and 0 permission asks from the wrap path.

**Risks & rollback:** notes in another language keep English headings (the prompt requires it) but owner
labels may be localised ("Vous") — `selfNames` covers English only; add localised pronouns when a real
meeting shows one. Rollback: `agentMeetingWrap` default `false`, or restore the one `NotesService` line.

**Done when:**
- [ ] `OwedItems.parse`, `MeetingSuggestionStore`, `meetingWrapped` exist with a production caller in `NotesService`
- [ ] meeting detail shows open suggestions
- [ ] Cases I–M pass
- [ ] (H-audit 2026-09-23) the `meeting.proposals` outcome counts from `usage.jsonl` are recorded in `STATUS.md` before and after

---

### P4-06 — Morning digest offer, owed-item nudges, next-step offer as a pending intent

**Finding(s):** Q12 (D §5 items 3, 4, 7; D-report items P2-18, P2-19, P2-20); H3 #19 (H-audit 2026-09-23)  **Effort:** 3.5 days  **Depends on:** P4-04, P4-05, P1-02, P1-03, P4-02, P4-12 (H-audit 2026-09-23: the digest this task offers needs P4-12's Apple Intelligence route and its 1,536-token template budget, or it skips or truncates every morning)  **Unblocks:** —

**Why (what the user experiences today):** `DigestTemplate.createArguments()`
(`Agent/Schedules/DigestTemplate.swift:73-83`) has no production caller — only `DigestSelfTest.swift:141`
calls it. Owed items with due dates are never pushed. The persona asks for "do the useful next thing",
but the voice answer lane was forbidden to promise work (`LocalVoiceDecision.swift:155`) and the typed
first pass had nothing to store an offer in, so "yes" after an offer went nowhere (09-22 00:58–01:01:
"would you like me to do that?" ×4).

**Files you will change:** `Agent/Proactive/ProactiveService.swift` (digest offer, nudges);
`Agent/Proactive/ProactiveOffers.swift` (new: offer model, next-step selection);
`Agent/VoiceConversationCoordinator.swift` (`offer(_:)` setter for `pendingAction`);
the typed pending slot P1-02 introduced (grep `typedPending` in `Agent/RealtimeAgent.swift`);
`Agent/Schedules/ScheduledRunner.swift:441` (format-aware sentence cap); `UI/Agent/AgentView.swift`
(`.onAppear` hook); `UI/Agent/IdeasView.swift` (digest entry); `Support/Settings.swift`
(`agentOwedNudges`, `agentNextStepOffers`, `agentDigestOffered`); `UI/Settings/ProactiveSection.swift`;
`Agent/Schedules/DigestSelfTest.swift`; `Agent/Proactive/ProactiveSelfTest.swift`;
`Memory/RoutineSuggestions.swift` and `Memory/MemoryReviewSelfTest.swift` (detector clustering, H-audit 2026-09-23).

**Read for context (do not change):** `Agent/Schedules/ScheduleTools.swift:113-135`
(`ScheduleToolExecutor.run(_:arguments:scheduler:…)`); `DigestTemplate.restatement()` (`:62-67`);
`Agent/PendingAction.swift` (P1-02/P1-07: `PendingAction` replaced the coordinator's `PendingIntent`, 180 s freshness; before P1-07 it was `Coordinator:45-52`), the coordinator's bare-acknowledgment resolution (`:357-367` on 2026-09-23; grep `pendingAction`);
`Activation/VoiceTurnPolicy.swift:78-87` (`isBareAcknowledgment`); `Memory/RoutineSuggestions.swift`.

**Current behaviour:** as in Why. `ScheduledRunner` system rules (`:441`): "When you are finished, answer in
plain language in at most three sentences." — `DigestTemplate`'s doc comment (`:32-36`) records this as a
known tension with its sectioned format.

**Target behaviour:**
1. **Digest offer, once.** On the first weekday when the Agent pane appears (`AgentView.onAppear`) or the
   wake word fires, between the end of quiet hours and 11:00 local, with no digest schedule in
   `ScheduleStore` and `agentDigestOffered == false`: show a heads-up card "Want a morning digest?"
   with line `DigestTemplate.restatement()` minus its final question, buttons `Yes` / `No`. Yes →
   `ScheduleToolExecutor.run(registry.tool("schedule.create"), arguments: DigestTemplate.createArguments())`
   (the click is the user's yes; the existing create path test-runs once, visibly). No → never again.
   Either answer sets `agentDigestOffered = true`. `IdeasView` keeps a "Morning digest" entry with the same
   Yes action for later.
2. **Runner cap.** `ScheduledRunner` rules line `:441` becomes: "When you are finished, answer in plain
   language. If the routine's instructions give a format, follow it; otherwise use at most three sentences."
   (H-audit 2026-09-23) The sentence alone does not let a digest be long: the token cap
   (`maxTokens: 384`, `ScheduledRunner.swift:531,535`) is replaced by P4-12's `Budget.maxOutputTokens`
   (1,536 for the digest template). Do not change the token cap here.
3. **Owed-item nudges.** Once a day, at the first `ProactiveService` tick after quiet hours end with the user
   present: open suggestions (P4-05) and graph action items (`ActionItemReminders.suggestions`) owned by the
   user, due today or tomorrow, not resolved in `ReminderSuggestionStore` → one card "Due soon" with up to 2
   items and buttons `Remind me` / `Done` / `Not now`. Each item is nudged at most once
   (`ReminderSuggestionStore.resolve(id)` on any answer; ledger key `nudge:<id>`). Cap: 1 nudge card per day.
   Opt-out `Settings.agentOwedNudges` (default `true`), row `Things you owe` — "A nudge when something you said
   you'd do is due soon."
4. **Next-step offer after an answer.** After a completed answer (typed reply or spoken voice answer), when
   `agentNextStepOffers` is on (default `true`), at most one offer sentence may be appended, chosen
   deterministically — no extra model call:
   - the answer listed ≥ 2 calendar events or emails → "Want me to put these in a doc?" (capability `create_doc`);
   - the answer came from a meeting's notes and an owed item exists → "Want me to draft the email to <name>?"
     (`draft_email`);
   - otherwise none.
   The capability must be in this turn's `AgentCapabilityManifest` (P1-03). The offer is stored as a pending
   action: voice → `VoiceConversationCoordinator.offer(PendingAction(requestText:question:capabilityID:origin: .frontendOffer, sessionID:at:))`
   (P1-07 unified the voice slot on P1-02's `PendingAction`; freshness 180 s); typed →
   `RealtimeAgent.typedPending` (P1-02's slot, `origin: .typedOffer`). A bare acknowledgment ("yes", "okay", "do it") then
   submits `requestText` — existing path at `Coordinator:359-367`. Max one offer per 3 answers, never after a
   failure or a refusal, never in quiet hours.
5. Offers never execute a write directly; they submit a request that goes through the normal
   planner/approval path.
6. **The routine-suggestion detector can fire (H-audit 2026-09-23, H3 #19).** Today
   `RoutineSuggestionDetector.key(for:)` (`Memory/RoutineSuggestions.swift:53-62`) makes the key the sorted
   set of content words, and `detect` (`:66-86`) groups by that exact key and needs `requiredDays = 3`
   (`:48`). Measured on this Mac (H3 #19): 68 logged requests → 58 distinct keys → 0 suggestions; the top
   keys were `who`, `yeah` (2 days each) and `chrome open` (2). Change:
   - add `"yeah"`, `"who"`, `"win"` to `filler` (`:91-97`);
   - `key(for:)` returns nil when fewer than 2 content words remain (one-word keys are noise);
   - `detect` clusters keys instead of grouping by exact key: two keys are the same request when the
     Jaccard similarity of their word sets is ≥ 0.6. Greedy single-link over keys sorted by first
     occurrence; the cluster's representative key is its most frequent member; a cluster already covered by
     an `existing` suggestion (any member key equal to a suggestion's key) is skipped;
   - keep `requiredDays = 3` (a suggestion must not be noise).
   These suggestions feed the routine offer (`MemoryReviewStateStore.takeOffer`), which after P4-12 can run
   on Apple Intelligence.

**Steps:**
1. `ProactiveService.maybeOfferDigest(now:trigger:)` called from `AgentView.onAppear` (wrap in
   `Task { @MainActor in … }`) and from the wake-word handler (grep the wake event in
   `Activation/ActivationController.swift`).
2. `ScheduledRunner`: change the one sentence; re-run `--selftest-digest` and `--selftest-schedule`.
3. `ProactiveService.tick(now:)` — call it from `MeetingScheduler.runOnce` end (30 s) next to the Now
   publish; it handles pending wraps (P4-05 quiet-hours hold) and the daily nudge.
4. `ProactiveOffers.nextStep(for reply: String, turn: AgentTurnSummary, manifest: Set<String>) -> PendingOffer?`
   pure; `AgentTurnSummary` carries the tool ids used this turn and their result kinds (from the tool loop's
   results). Call it where the final reply is concluded (`RealtimeAgent.conclude` for typed; the coordinator's
   `.answer` completion and the worker-result delivery for voice). Append the sentence to the reply text before
   it is recorded/spoken.
5. Coordinator: `func offer(_ action: PendingAction)` sets `pendingAction`. After P1-07 lands, "okay" during a
   pending action is not noise (T8) — reuse, do not duplicate.
6. (H-audit 2026-09-23) `Memory/RoutineSuggestions.swift`: implement Target 6. Add
   `static func jaccard(_ a: String, _ b: String) -> Double` (keys split on spaces) and
   `static let clusterThreshold = 0.6`; `detect` builds clusters, then applies the existing day count to the
   union of each cluster's rows. The P4-12 output budget is what lets a digest created from a suggestion or
   from Target 1 answer in its sectioned format; Target 2's sentence change and P4-12's token cap are two
   halves of the same fix and must both be in place before `DIGEST_OK` is claimed.

**Do not:**
- Do not create the digest without a click; do not re-offer after "No".
- Do not add a web or news tool to the digest (its prompt forbids it).
- Do not generate offers with a model; do not offer a capability the manifest lacks.
- Do not let a stale offer (> 180 s voice; P1-02's rule typed) execute.
- Do not nudge more than once per item, or inside quiet hours.

**Red-first self-test:**
- Extend `--selftest-digest` (`Agent/Schedules/DigestSelfTest.swift`): with a temp `ScheduleStore`/scheduler
  (the shared one is already isolated under `SelfTest.isRunning`), call
  `ProactiveService.maybeOfferDigest(now: <a weekday 08:30>, trigger: .paneOpened)` with a fake sink, then invoke
  the card's `Yes` action → assert exactly one schedule titled `Morning digest` exists with `repeat weekdays`,
  `06:00`, tools = the three ids; a second `maybeOfferDigest` shows nothing. Also assert the runner's rules no
  longer say `at most three sentences.` unconditionally (contains `If the routine's instructions give a format`).
  Fails today: "no production path created the digest routine".
- Extend `--selftest-proactive`:
  - Case N (nudge): an open suggestion due tomorrow → at t = quiet end + 1 min, 1 card with `Remind me`; a second
    tick the same day → none; next day with the item resolved → none.
  - Case O (next-step offer): a typed turn summary with `get_agenda` returning 3 events and manifest containing
    `create_doc` → offer text `Want me to put these in a doc?` and the typed pending slot holds it; then "yes" →
    exactly one submitted request `Put these events in a doc` (fake worker); with `create_doc` absent → no offer.
  - Case P (voice offer): the coordinator's pending intent is set by `offer(_:)`; "okay" within 180 s submits;
    after 181 s does not.
- (H-audit 2026-09-23) Extend `--selftest-memory-review` (`Memory/MemoryReviewSelfTest.swift`, next to
  the existing detector checks at `:701-703`): a request log with "what's on my calendar today" (day 1),
  "what's on my calendar" (day 2), "show my calendar for today please" (day 3) → exactly 1 suggestion
  (red today: three different exact keys); "yeah" on 3 days → 0; "who" on 3 days → 0; "chrome" alone on 3
  days → 0 (one content word); `key(for: "Open Chrome")` → nil. Final marker stays `MEMORY_REVIEW_OK`.
- Markers: `DIGEST_OK`/`DIGEST_FAILED` (existing), `PROACTIVE_OK`/`PROACTIVE_FAILED`.

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-digest
Scripts/run-selftest.sh --selftest-proactive
Scripts/run-selftest.sh --selftest-schedule
Scripts/run-selftest.sh --selftest-routine-authority
Scripts/run-selftest.sh --selftest-voice-turn-routing
Scripts/run-selftest.sh --selftest-guided
Scripts/run-selftest.sh --selftest-ui-strings
Scripts/run-selftest.sh --selftest-memory-review
Scripts/run-selftest.sh --selftest-toolloop-live
make acceptance TIER=core
```

**Success threshold:** `DIGEST_OK` with the production-path assertion; Cases N–P pass; eval shows no filler or
unsolicited offer on failures/refusals (the eval's filler check stays green); (H-audit 2026-09-23)
`MEMORY_REVIEW_OK` with the five detector cases (1 cluster suggestion, 0 for the four noise logs).

**Risks & rollback:** offers may feel pushy → one per three answers, setting to turn off. A digest created on this
Mac runs through `ScheduledRunner` with `model = auto`; on a Mac with no working model it produces nothing (the
scheduler's failure escalation already notifies). Rollback per item: each is behind its own setting.

**Done when:**
- [ ] `DigestTemplate.createArguments()` has a production caller (grep shows `ProactiveService` or `IdeasView`)
- [ ] runner cap is format-aware; nudges and offers behind settings
- [ ] `DIGEST_OK`, `PROACTIVE_OK` with new cases
- [ ] (H-audit 2026-09-23) detector clusters by Jaccard ≥ 0.6, new filler words, no one-word keys; `MEMORY_REVIEW_OK`

---

### P4-07 — Explicit statements saved to memory

**Finding(s):** Q11 (D §3, D-report item P1-14); cross-reference H1 #23 (H-audit 2026-09-23)  **Effort:** 1.5 days  **Depends on:** P4-07a, P0-11  **Unblocks:** —

**Complements P4-11 (H-audit 2026-09-23).** This task saves an explicit statement at the moment it is
said. P4-11 fixes the background review that reads everything afterwards: it stops the review echoing
the saved facts back (55 % of its proposals, H3 #7), keeps short sentences the harvest drops today
(`MemoryHarvest.minimumSentence = 24`), narrows two skip regexes, and retries a target-less
`memory.update` as `remember` (H1 #23: 25 of 40 refusals). The two tasks touch different files except
`Tests/Fixtures/memory-review.json` and `Memory/MemoryReviewSelfTest.swift`; whichever lands second
merges its fixture cases into the other's, and both keep the one `MEMORY_REVIEW_OK` marker. Note that
"My brother is Cyril." (20 characters) is below today's harvest floor, so until P4-11 lands the
review would never see it in a dictation — this task's direct path is the only one that saves it.
Also note the "200 runs" figure below is a ledger cap (`MemoryReviewStateStore.runLimit = 200`,
`Memory/RoutineSuggestions.swift:132`) covering about 30 hours, not a lifetime count (H3 fact 1).

**Why (what the user experiences today):** 200 background review runs saved **2** facts (D §3). The persona says
"Remember what they tell you", and the planner's memory rule only fires when the planner runs. "I'm the CEO of
ProductFlo" and "my brother is Cyril", said in conversation, are not reliably kept.

**Files you will change:** new `Memory/ExplicitMemoryStatement.swift`; the typed turn entry
(`RealtimeAgent.handle`, `Agent/RealtimeAgent.swift`) and the voice turn entry (`Coordinator.respond`, after
`recordUser` at `:325`); `Memory/MemoryReviewSelfTest.swift`; `Tests/Fixtures/memory-review.json`;
`Memory/MemoryReviewer.swift` (skip `contextKind == "proactive"` rows, from P4-04).

**Read for context (do not change):** `Memory/NextMemory.swift:600-640` (`remember(kind:text:source:…)`:
normalize + near-duplicate + budget), `:40-80` (`Kind`, `Source.userSaid`); `Memory/MemoryGuard.swift`.

**Current behaviour:** user turns are recorded (`AgentSession.recordUser`, `Agent/RealtimeAgent.swift:1094`) and
reviewed later by `MemoryReviewScheduler`; nothing saves an explicit statement at the time it is said.

**Target behaviour:**
1. `ExplicitMemoryStatement.extract(_ text: String, userName: String) -> [String]` returns zero or more facts, each
   one declarative sentence in the user's words, for these English shapes only (safe regex subset, case-insensitive,
   whole clause):
   - `I'm|I am (the|a|an)? <role> (of|at) <org>` → "I'm the CEO of ProductFlo."
   - `my <relation> is <Name>` with relation ∈ brother, sister, wife, husband, partner, dad, father, mum, mom,
     mother, son, daughter, boss, manager, assistant, cofounder, co-founder → "My brother is Cyril."
   - `call me <Name>` / `my name is <Name>`
   - `I live in <place>` / `I work at|for <org>`
   - `remember (that)? <fact>` (5–160 characters) → the fact.
   Excluded: questions (`?`), clauses containing `not`, `n't`, `if`, `maybe`, `was`, `used to`; source `.meeting`.
2. On each typed or voice user turn, when memory is enabled, each extracted fact is saved with
   `NextMemory.shared.remember(kind: .profile, text:, source: .userSaid, sessionID:)`. Duplicates are reported as
   already known (existing behaviour); over budget → skipped and audited.
3. The pane shows a small row "Remembered: My brother is Cyril." under the user's message (reuse whatever the
   `memory.remember` tool result renders — grep `memory.remember` in `UI/Agent`). Nothing is spoken.
4. Planner rule "memory.remember: only a fact the user stated about themselves…" stays; the planner will now often
   find the fact already saved.

**Steps:** implement the extractor as a pure function; call it through a seam
`var rememberExplicit: @MainActor (String) -> Void` on `RealtimeAgent` and the coordinator (self-tests pass a
recorder); add fixture cases to `Tests/Fixtures/memory-review.json` in the file's existing shape (read the file
first) with `expect` saved for "I'm the CEO of ProductFlo" and "my brother is Cyril", and not saved for "Is my
brother Cyril coming?" and "I'm not the CEO anymore".

**Do not:** do not save from meeting transcripts, tool results or the agent's own text; do not infer facts ("sounds
like you're a CEO"); do not let a saved memory grant permission for anything; do not write to the user's real memory
from the self-test (the review self-test's temp store only).

**Red-first self-test:** `--selftest-memory-review` gains the four fixture cases plus a direct check that the
extractor returns exactly `["I'm the CEO of ProductFlo.", "My brother is Cyril."]` for the combined sentence "I'm
the CEO of ProductFlo and my brother is Cyril." and that a temp `NextMemory` holds both after one simulated typed
turn. Markers `MEMORY_REVIEW_OK` / `MEMORY_REVIEW_FAILED`. Red today: the fixture expects saves the extractor path
never makes.

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-memory-review
Scripts/run-selftest.sh --selftest-memory
Scripts/run-selftest.sh --selftest-toolloop-live      # "I'm the CEO of ProductFlo" case
make acceptance TIER=core
```

**Success threshold:** both statements saved; both negatives not saved; `MEMORY_REVIEW_PRECISION` not lower than
before.

**Risks & rollback:** false saves from sarcasm or quotes → narrow patterns, visible "Remembered" row, and the Memories
editor to delete. Rollback: the seam defaults to a no-op.

**Done when:** [ ] extractor + call sites; [ ] fixtures pass; [ ] visible "Remembered" row.

---

### P4-07a — Provenance survives the write: `MemoryEntry` keeps what `MemoryGuard` read

*Prerequisite for P4-07 and P4-11. Runs first in the memory order and may start independently from P0-11; the preferred whole-phase order adds no P4-08 dependency.*

**Finding(s):** structural audit 2026-09-25, folded from the then-named
`roadmap/todo/next-notes-multi-agent-durable-jobs-memory-roadmap.md` §5.1 — **that file has since
been deleted**; its surviving half is `roadmap/backlog/memory-lifecycle-consolidation-roadmap.md` §1
(`REVIEW-LOG.md` §6.3)
**Effort:** 1.5 days **Depends on:** P0-11 **Unblocks:** P4-07, P4-11, and
`roadmap/backlog/memory-lifecycle-consolidation-roadmap.md`

**Why (what the user experiences today):** not directly — nothing is broken today, and that is the
point of doing it first. What a user *cannot* do is ask where a memory came from. Every saved fact
carries one channel and one number, so a memory learned from a dictation, a meeting, and the
knowledge graph look identical from the outside, and a correction cannot show what it replaced.
Three later things need that and cannot have it: P4-07 (a saved statement must be able to say
where it was said), and memory consolidation (merging two memories must not flatten two provenances
into one sentence).

**The structural problem.** `MemoryProvenance` (`Memory/MemoryGuard.swift:8`) is a
`@TaskLocal` **gate**, consulted before a write by `MemoryToolExecutor.checkedText` and set by the
code running the turn, never by the model. What lands on the entry is **three denormalised
fields** — `origin`, `sourceLabel`, `confidence` — written at `Memory/NextMemory.swift:633` and
`:674-675`. Once written, a memory carries a single channel and a single number. There is no
`sourceEntryIDs`, no provenance list, no run id. So the consolidation lineage the sibling roadmap
proposes **cannot be built on today's write path**, and the fix has to come before, not with it.

**A correction to the source proposal, and it is a privacy one.** The draft specified

```swift
struct MemoryLineage {
    var sourceEntryIDs: [UUID]
    var provenance: [MemoryProvenance]      // ← rejected
    var consolidationRunID: UUID?
}
```

`MemoryProvenance` deliberately holds `userText: [String]` (what the user said) and
`untrustedText: [String]` (other speakers, tool results, emails, files, pages) — it is a gate
that is meant to be **read once and discarded**. Persisting it would put every source turn's raw
text into `next-memory.json` and multiply the file, and it would retain exactly the quoted content
that `UsageLog.sanitise` exists to keep out of `usage.jsonl` for the Agent, Meetings and Dictation
passes. **Persist the descriptor, not the content.** Define:

```swift
/// The persistable subset of `MemoryProvenance`: where a fact came from, not what was said.
struct MemoryProvenanceRecord: Codable, Sendable, Equatable {
    var source: MemoryProvenance.Origin
    var trustedSource: MemoryProvenance.TrustedSource
    var sourceLabel: String?
    var occurredAt: Date
    var sessionID: UUID?
    var confidence: Double?          // 0.9 / 0.8 / 0.7 / 0.5, or nil when it was not derived from a channel
    var entryID: UUID?               // the memory this row replaced, when it was a correction
}

struct MemoryLineage: Codable, Sendable, Equatable {
    var records: [MemoryProvenanceRecord]
    var consolidatedFrom: [UUID]      // the ids a merge absorbed; empty until consolidation runs
    var consolidationRunID: UUID?     // nil until it has
}
```

`MemoryProvenance` itself stays a gate and stays out of the store. Add a test case that asserts no
memory row serialises `userText` or `untrustedText`, and a case that greps the written file for a
phrase from the source turn and requires it to be absent.

**Files you will change:** `Memory/NextMemory.swift` (`MemoryEntry` + a hand-written
`init(from:)`; `remember` at `:612` and the second write site at `:657` accept a lineage);
`Memory/MemoryGuard.swift` (build the record, drop the content); `Memory/MemorySelfTest.swift`;
and `Memory/Consolidation/MemoryLineage.swift` (new, two small types).

**Read for context (do not change):** `Memory/MemoryGuard.swift:8` (the gate, its four
`TrustedSource` confidences and its `requiredAuthority`); `Memory/NextMemory.swift:39`
(`MemoryEntry`), `:61-66` (the 2,400 / 4,000 / 300 character budgets in §12 — **do not touch
them**), `:1215` (`MemorySnapshotCache`), `:1150-1165` (the version-1→2 migration, and the pattern
for a version bump), `:1181-1193` (atomic write + `chmod 0600`); `Memory/MemoryReviewer.swift:178`
(`MemoryReviewJob`, which carries `turns` — the in-memory form of the same thing).

**Current behaviour:** `MemoryEntry.origin`/`.sourceLabel`/`.confidence` are written from the
`@TaskLocal` provenance and the raw text is dropped. `StoredFile` is at **version 2**.

**Target behaviour:**
1. `MemoryEntry` gains `var lineage: MemoryLineage?` — **Optional**, so a row written by an older
   build still decodes.
2. **`MemoryEntry` gains a hand-written `init(from:)` with `decodeIfPresent` for every field, new
   and old.** This is the `MeetingModels` rule and it is the single most likely way this task ships
   broken: a synthesized `init(from:)` does **not** fall back to a property's default for a missing
   key, so a non-optional new field makes every existing `next-memory.json` fail to decode and
   every memory the user has silently vanishes. Read `Memory/NextMemory.swift` and copy the pattern
   from `Meetings/MeetingModels.swift`, or from `Agent/Tasks/AgentTask.swift:115`.
3. `StoredFile` bumps to **version 3** and the version-2 → 3 migration writes **no lineage at
   all** — old entries get `nil`, meaning "unknown", which is the truth. The migration must not
   synthesise a provenance nobody recorded, and it must not rewrite the user's file to add empty
   rows. `MemoryEntry.supersedes` already carries the single-parent correction chain, so
   `consolidatedFrom` starts empty and `entryID` in a record is populated from `supersedes` when it
   is already known.
4. `MemoryGuard` builds a `MemoryProvenanceRecord` and passes it down; `remember` stores it.
5. **`origin`, `sourceLabel` and `confidence` are retained, not replaced.** `MemorySnapshotCache`
   and the review prompts read them, and the sibling roadmap's consolidation still wants a fast
   single-channel read.

**Steps:**
1. Write the red-first cases first (below) and confirm they fail.
2. Add the two types in their own file, with `Codable` and hand-written decoding for the date and
   the two enums.
3. Add `lineage` to `MemoryEntry`; write the hand-written `init(from:)` **first**, before the
   property, so the compiler helps you.
4. Thread it through `remember`'s two write sites. Keep the existing parameters' defaults, so
   existing callers are unchanged.
5. Bump `StoredFile` to version 3 with an additive migration, following the version-1→2 code's
   shape (including the `Log.agent.info` line and the `persist()` in the `do`, and the `else` on
   `error`).
6. Update `STATUS.md` with what the version-3 row looks like on disk.

**Do not:**
- **Do not persist `userText` or `untrustedText`.** That is the whole correction; a self-test must
  fail if either reaches the file.
- Do not change the character budgets in §12, the `MemorySnapshotCache` selection order, or the
  prompt's memory share (P4-08 owns the last one).
- Do not touch the Knowledge Graph. `Knowledge/GraphStore.swift` keeps its citations; the sibling
  roadmap's §5.6 says consolidation must not rewrite them and this task does not come near them.
- Do not synthesise provenance for an old entry. `nil` means unknown, and unknown is not `userSaid`.
- Do not make lineage grant permission for anything. `AgentRisk` and `PermissionBroker` are
  unchanged; a memory is a fact, not an authority.
- Do not write to the owner's real `next-memory.json` from the self-test — P0-11's temp store.

**Red-first self-test:** extend **`--selftest-memory`** (CORE; one marker, `MEMORY_OK` /
`MEMORY_FAILED`, cases added not replaced). Cases:
- an **old version-2 fixture** `next-memory.json` — copy one from `Tests/Fixtures/` or write one in
  the version-2 shape with `profile`/`note` entries, a `superseded` row and three activity items —
  loads, keeps every entry, and produces a **`MemorySnapshotCache` encoding byte-identical** to a
  golden captured before this change. This is the load-bearing case: it fails today only if the
  decoder breaks, which is exactly what it is there to catch.
- a written entry's `lineage.records[0]` carries the right `trustedSource` and `confidence` for each
  of the four `TrustedSource` cases.
- **the privacy case:** after a write, read the file back as text and assert it does not contain a
  distinctive phrase from `provenance.userText` or `untrustedText`.
- `consolidatedFrom` is empty and `consolidationRunID` is `nil` for an entry written by hand.
- a version-3 file re-read by the version-2 shape is a *test fixture* concern only — do not assert
  forward compatibility, the app never downgrades.

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-memory
Scripts/run-selftest.sh --selftest-memory-review
Scripts/run-selftest.sh --selftest-store-isolation
Scripts/run-selftest.sh --selftest-persona
make acceptance TIER=core
```

**Success threshold:** the old fixture decodes and its snapshot bytes are unchanged; the privacy
case passes; `MEMORY_REVIEW_OK` and `STORE_ISOLATION_OK` unchanged; the version-3 file is readable
by the new code and the version-2 file is readable by the new code.

**Risks & rollback:** the failure mode is *invisible* — a decode error returns
`try? decoder.decode(…) ?? []` and the app starts with **no memory at all** and no error. The
red-first fixture case is the only guard; do not soften it to "at least the entries load". If the
hand-written `init(from:)` proves larger than expected, the rollback is to make `lineage` Optional
and leave it `nil` — the fields are additive and nothing reads them yet.

**Done when:** [ ] two types added; [ ] `MemoryEntry` has a hand-written `init(from:)`;
[ ] version-3 migration; [ ] old fixture decodes with a byte-identical snapshot; [ ] privacy case
green; [ ] `AGENTS.md` gains a line naming what provenance is kept and what is deliberately not.

---

### P4-08 — Longer history; fitted `KnowledgeAsker` for typed library questions

**Finding(s):** Q9, Q10 (D §3, D-report items D:P1-12 and D:P1-13, not this roadmap's P1-12/P1-13); H3 #17, H1 #29, H2 V20 (H-audit 2026-09-23)  **Effort:** 1.5 days  **Depends on:** P4-01, P1-18 (H-audit 2026-09-23: the typed and planner history budget moved there)  **Unblocks:** —

**Scope change (H-audit 2026-09-23, H1 #9).** The typed/planner history budget (old Target 1–2 and Steps
1–2: `AgentHistoryBudget`, the 2,500 first-pass and 2,500/6,000 planner splits, the 1,800 per-message cap)
is **done in P1-18 (Phase 1)**, which also lifts the 10,000-character session ceiling
(`AgentSessionBoundary.swift`). Do not re-implement it here. Check it landed: `grep -rn "AgentHistoryBudget"
Sources/NextNotes` must show callers in `Agent/RealtimeAgent+ToolLoop.swift` and `Agent/RealtimeAgent.swift`;
if it does not, stop and do P1-18 first. What remains here: the voice-lane rule (unchanged at 1,400), the
fitted `KnowledgeAsker`, the typed library route, the memory prompt budget and the Assembler page budget.

**Why (what the user experiences today):** Library questions on Apple FM overflow: `KnowledgeAsker` carries up
to 20 passages × 700 characters (`KnowledgeAsker.contextPassages` / `passageCharacters`,
`Knowledge/KnowledgeAsk.swift:157-158`) ≈ 3,500 tokens (estimate). The app assumes a 4,096-token window for it
(`FoundationModelLLMProvider.contextTokens`; 8,192 measured on the dev Mac and read at runtime after P1-10a), and
typed library questions never reach it (voice only: `runVoiceObjective`, `Agent/RealtimeAgent.swift:130-139`).
(H-audit 2026-09-23) Memory in the prompt is a fixed character budget per path whatever the reader's window
(`AgentPromptPath.budget`, `Persona/AgentPromptContext.swift:56-78`: `voiceAnswer` 300, `meetingAssistant` /
`knowledgeAsk` 600, `toolLoop` / `localModel` / `scheduledRun` 3,400), and the `toolLoop` comment still says
"Both core budgets (1,200 + 2,000)" (`:65`) while the store budgets are 2,400 + 4,000 (`NextMemory.swift:63-64`).
No harm with 2 stored facts, but after P4-07 and P4-11 a 262K cloud reader would still see 600 characters of
memory on the meeting path (H3 #17). The Assembler's page pass is capped at 600 tokens
(`Assembler.compose`, `Knowledge/Assembler.swift:456`: `maxTokens: 600`), tight for a page with sources and
3–5 outstanding items (≈ 450 words, H1 #29).

**Files you will change:** `Agent/RealtimeAgent.swift` (typed routing to `KnowledgeAsker`);
`Knowledge/KnowledgeAsk.swift` (fitting); the `KnowledgeAnswerModel` protocol and `ProviderKnowledgeAnswerModel`
(grep; expose `contextTokens`); the `--selftest-ask` implementation; (H-audit 2026-09-23)
`Persona/AgentPromptContext.swift` (memory budget from the window; stale comment); the callers of
`AgentPromptContext.assemble` that know their provider (15 call sites today — grep
`AgentPromptContext.assemble(`); `Knowledge/Assembler.swift` (`compose` output budget); `Persona/PersonaSelfTest.swift`
(budget cases).

**Read for context (do not change):** `Agent/AgentAnswerBudget.swift` (`readerContextTokens(for:)`, `:54`);
`Memory/NextMemory.swift:60-66` (store budgets 2,400 / 4,000); `Agent/VoiceConversationCoordinator.swift:732`
(voice history `maxCharacters: 1_400`).

**Current behaviour:** fixed passage count and size in `KnowledgeAsker`; fixed memory budgets per path; Assembler
page pass 600 tokens. The voice answer history is `chatHistoryForCurrentTurn(maxCharacters: 1_400, …)` at
`Coordinator:732` (it was `:678` when this task was first written).

**Target behaviour:**
1. **Voice history stays 1,400 (H2 V20, kept here).** The voice answer lane stays at 1,400 characters
   (`Coordinator:732`): it is always Apple FM and latency bounds it, not the window (read at runtime: 8,192 on
   the dev Mac), unless a P5 cloud frontend is active, then the frontend's own window rule. P1-18 does not
   touch this line.
2. (Moved to P1-18; nothing to do here.)
3. `KnowledgeAsker` fits passages to the model: `passageBudgetChars = max(0, (contextTokens - maxTokens -
   estimatedTokens(system) - estimatedTokens(question) - 300) * 4 * 6 / 10)`; `contextPassages = min(20,
   passageBudgetChars / passageCharacters)`, at least 3; `estimatedTokens(s) = s.count / 4` (estimate, same rule as
   D). The fitted count is used in `run` (`:219`, `:232`).
4. Typed turns: when `KnowledgeAskRouting.isLibraryQuestion(text) && KnowledgeToolGate.isAvailable`, the typed path
   answers with `KnowledgeAsker` on the Agent-role provider (P4-09's typed lane), inside
   `KnowledgeGraphScope.$reader.withValue(provider.id)`, and renders citations the way the Knowledge screen does; on
   nil/failure it falls back to the planner.
5. **Memory budget from the window (H-audit 2026-09-23, H3 #17).**
   `AgentPromptPath.memoryLimit(contextTokens: Int?) -> Int` =
   `let window = contextTokens ?? 0; return window > 8_192 ? max(budget.memoryLimit, window * 4 * 5 / 100) : budget.memoryLimit` for every
   path whose `budget.memoryLimit > 0` (about 5 % of the window, in characters at ~4 characters per token,
   estimate); the current values are the floors, and windows of 8K or less keep them exactly (P4-10 is shrinking
   the meeting prompt on those). `voiceRoute` and `acpAgent` stay 0. Examples: Apple FM 4,096 or 8,192 → today's
   values; 32,768 → 6,553 on every path (the 3,400 paths too); 262,144 → 52,428, which the store's own
   6,400-character total (2,400 + 4,000) caps in practice. `AgentPromptContext.assemble` gains `contextTokens: Int? = nil`; nil keeps
   today's floors exactly. The `toolLoop` comment becomes "Both core budgets (2,400 + 4,000) plus the JSON framing".
6. **Assembler page budget (H-audit 2026-09-23, H1 #29).** `Assembler.compose` asks for
   `min(1_500, max(600, readerContextTokens / 4))` tokens instead of 600, where `readerContextTokens =
   await AgentAnswerBudget.readerContextTokens(for: provider)`. Apple FM 4,096 → 1,024; 8,192 → 1,500.

**Steps:**
1. (Done in P1-18, Phase 1 — H-audit 2026-09-23.) Confirm with the grep in **Scope change** above.
2. (Done in P1-18, Phase 1 — H-audit 2026-09-23.) Leave `Coordinator:732` (voice, 1,400) unchanged.
3. Add `var contextTokens: Int { get }` to `KnowledgeAnswerModel` (grep the protocol) and implement it in
   `ProviderKnowledgeAnswerModel` from the wrapped provider; compute the fitted passage count (Target 3)
   once per `run` and use it at `KnowledgeAsk.swift:219` and `:232`.
4. In `RealtimeAgent.handle`, typed path only, before the tool loop: route library questions to
   `KnowledgeAsker` as in Target 4; fall back to the planner on nil or error.
5. Grep for callers of every new function before ticking the task.
6. (H-audit 2026-09-23) In `Persona/AgentPromptContext.swift` add
   `func memoryLimit(contextTokens: Int?) -> Int` on `AgentPromptPath` (Target 5); in `assemble`, add the
   parameter `contextTokens: Int? = nil` and cap memory with `path.memoryLimit(contextTokens:)` instead of
   `budget.memoryLimit` (`:177-179`). Fix the `:65` comment. At each `assemble` caller that holds a provider,
   pass `await AgentAnswerBudget.readerContextTokens(for: provider)`; callers without a provider (static
   prompt strings such as `AgentPrompts.system`) keep nil until a later task gives them one — list them in
   `STATUS.md`.
7. (H-audit 2026-09-23) `Knowledge/Assembler.swift` `compose`: resolve the provider as today, compute the
   Target 6 budget, pass it as `maxTokens`.

**Do not:** do not grow the voice lane's history on Apple FM; do not change citation rules; do not route "search my
files" requests to `KnowledgeAsker` (files go to `filesystem.find`). (H-audit 2026-09-23) Do not re-implement
P1-18's history budget here; do not lower any memory budget below today's value; do not change the memory store's
own budgets (2,400 / 4,000, `NextMemory.swift:63-64`) or the 300-character entry cap; do not write to the user's
real memory from the self-test.

**Red-first self-test:** extend `--selftest-ask`: a fake `KnowledgeAnswerModel` with `contextTokens = 4_096` and a
fixture index returning 20 passages of 700 characters; capture the assembled prompt; fail with
`ASK_FAILED: prompt ~N tokens exceeds 4096` when `prompt.count / 4 + maxTokens > 4_096`. Red today: 20 × 700
characters exceed the window. (H-audit 2026-09-23) Also: with `Assembler.composeForSelfTest` capturing, assert the
requested budget is 1,500 for a fake 32,768-token provider and 1,024 for 4,096 (add a `maxTokens` capture to the
seam; red today: 600). Extend `--selftest-persona` (`Persona/PersonaSelfTest.swift`): with a temp memory snapshot
of 5,000 characters, `assemble(.meetingAssistant, rules: "x", contextTokens: 32_768).memoryCharacters` ≥ 5,000,
`contextTokens: 8_192` and `contextTokens: nil` each give ≤ 600; `.voiceRoute` gives 0 at any window. Red today: the parameter does not exist
(compile-time red; commit the test with a stub returning `budget.memoryLimit` to see the runtime red).

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-ask
Scripts/run-selftest.sh --selftest-search
Scripts/run-selftest.sh --selftest-assemble
Scripts/run-selftest.sh --selftest-persona
Scripts/run-selftest.sh --selftest-tool-awareness
Scripts/run-selftest.sh --selftest-toolloop
Scripts/run-selftest.sh --selftest-toolloop-live      # typed "what we decided in my last meeting"
make acceptance TIER=core
```

**Success threshold:** `ASK_OK`; the fitted prompt ≤ 4,096 − 512 tokens (estimate) on the fixture (a scripted
4,096 reader: the worst case, and Apple FM's fallback, not its measured 8,192); eval library case
answers with a citation. (H-audit 2026-09-23) `ASSEMBLE_OK`, `PERSONA_OK` and `TOOL_AWARENESS_OK` with the new
cases; no path's memory section shorter than before at any window.

**Risks & rollback:** fewer passages on Apple FM may lower recall; the multi-round loop (`maxRounds = 4`) compensates.
(H-audit 2026-09-23) A larger memory section on a big reader lengthens the cached prefix; prefix reuse (P0-18)
makes that a one-time cost per session. Rollback: return the constants; `contextTokens: nil` everywhere restores
today's memory budgets.

**Done when:** [ ] P1-18's `AgentHistoryBudget` confirmed in place (grep); [ ] fitted asker; [ ] typed library route;
[ ] `ASK_OK`; [ ] (H-audit 2026-09-23) memory budget from the window with today's values as floors, `:65` comment
fixed; [ ] Assembler page budget `min(1_500, readerContextTokens/4)`; [ ] voice history still 1,400.

---

### P4-09 — Capable model for typed and background work, with its own consent

**Independent-role amendment (2026-09-30):** this task routes Agent lanes and owns
Agent consent only. SB-02 retains independent meetingNotes choices, cloud model IDs
and context settings; it must not inherit Agent cloud authorization for transcripts.
Resolve providers per workload and pass the actual reader to graph/file/memory consent
checks. Sharing an artifact never grants another workload's consent. Keep MiniCPM
cleanup local with its existing Apple guard/fallback; do not route it through AgentLane.
Coordinate ModelRoleStore/settings/UI edits with SB-02/SB-03/SB-06.


**Finding(s):** Q1 (D §1, D-report item P0-3); G §5 ("after Phase 0/1": OpenRouter for typed work, with reasoning capped and native `tools`); H1 #16 (H-audit 2026-09-23: consent migration)  **Effort:** 1.75 days  **Depends on:** P0-01, P0-03, P0-14, P1-01, P0-17 (a reasoning cloud model is otherwise cut off, G N1), P0-19 (the consent text may promise that nothing is written to the disk cache, G N4), P0-20 (records which model did the work)  **Unblocks:** P4-08 (typed lane), P5-01

**Why (what the user experiences today):** every answer comes from the ~3B Apple model or none (D §0.2). Background
voice work is pinned to the on-device model although it is not real-time:
```swift
// Support/ModelRoles/ModelRoleStore.swift:726-727, AgentModelRouting.provider(for:voice:)
static func provider(for prompt: String, voice: Bool) async -> (any LLMProvider)? {
    if voice { return await LLMProviders.resolve(preferring: .appLLM) }
```
The only cloud gate is the knowledge graph's consent (`:735`, `let consent = Settings.shared.knowledgeGraphCloudConsent`;
also `ToolLoop:758`), which is the wrong consent: it was given for the life map, not for sending requests.

**Files you will change:** `Support/ModelRoles/ModelRoleStore.swift` (`AgentModelRouting`, `MultiStepPlanRouting`
callers); `Agent/RealtimeAgent+ToolLoop.swift` (`:353`, `:756-759`, `:774`); `Formatting/LLM/NotesModelRuntime.swift:312`
(`resolvesToLocalModel`); `Knowledge/Assembler.swift:453`; `Support/Settings.swift` (`agentCloudConsent`);
`UI/Settings/ModelRoleSection.swift` or `UI/Settings/ModelsSettingsTab.swift` (toggle next to the OpenRouter key);
`UI/Settings/OpenRouterModelSelection.swift` (small-model hint); `Persona/AgentNow.swift` (reads the consent);
`Support/ModelRoles/ModelRoleSelfTest.swift`.

**Read for context (do not change):** `ModelRoleStore.provider(for:)` (`:534-584`, after P0-03's usable-model guard);
`Formatting/LLM/OpenRouterLLMProvider.swift:63-140` (`OpenRouterKeyStore`); `Knowledge/KnowledgeTools.swift:166-177`.

**Current behaviour:** above. Also `ModelRoleStore.provider(for:)` re-sets `activeAgentModelID` on every turn
(`:576-578`) — P0-14 owns that (read-only resolution); do not re-fix it here, only check it is fixed.

**Target behaviour:**
1. `enum AgentLane: Sendable { case conversational, typed, background }`.
   `AgentModelRouting.provider(for prompt: String, lane: AgentLane)`:
   - `.conversational` → `.appLLM` preferred (unchanged; the Apple FM frontend does not come through here at all).
   - `.typed`, `.background` → `ModelRoleStore.shared.provider(for: role)` (role from `role(forUtterance:)`).
     If that provider's id is `.openRouter` and `agentCloudConsent` is off → the on-device provider instead, and one
     notice per session: "Online answers are off — answering on this Mac. You can turn them on in Settings ▸ Agent."
   - Multi-step cloud continuation (`:731-742`) uses `agentCloudConsent`, not `knowledgeGraphCloudConsent`.
2. Callers map: `runModelTurn` (`ToolLoop:353`) and the planner (`:774`): `isVoiceWorker ? .background : voice ?
   .conversational : .typed`. `ToolLoop:756-759` uses `agentCloudConsent`. `NotesModelRuntime:312`
   `resolvesToLocalModel(voice:)` maps the same way. `Knowledge/Assembler.swift:453` → `.background`.
   Keep a `provider(for:voice:)` shim only if other callers exist after this change; otherwise delete it.
3. `Settings.agentCloudConsent: Bool`, key `agentCloudConsent`, default `false`. Toggle label: `Let an online model
   answer typed requests and background work`; detail: `What you ask, the conversation, your memory and what the
   Agent looks up to answer are sent to the online model you picked. Voice conversation stays on this Mac.`
   The graph and file-name consents stay separate and still apply inside a cloud run.
   **Migration (H-audit 2026-09-23, H1 #16).** A default of `false` would silently demote a user who already
   chose the online model: with a stored `modelRoles.agent = cloud` (this Mac today) Target 1 would answer on
   the device with "Online answers are off". So in `Settings.init`, when the `agentCloudConsent` key is
   **absent** from defaults, seed it once as
   `agentCloudConsent = (ModelRoleStore.shared.choice(for: .agent) == .cloud)` (`ModelRoleStore.choice(for:)`,
   `Support/ModelRoles/ModelRoleStore.swift:341`; `ModelRoleChoice.cloud`, `:115`; the stored key is
   `modelRoles.agent`, `:322`) and write the seeded value, so the migration runs exactly once. If `Settings`
   cannot reach `ModelRoleStore` at init without a cycle, read the token directly:
   `defaults.string(forKey: "modelRoles.agent") == ModelRoleChoice.cloud.token`. A key that is present (true
   or false) is never touched. Choosing `.cloud` in the role picker afterwards shows the consent sentence inline
   and sets it to true.
4. Background voice results from a cloud model are delivered like any other result (P3-04 when present).
5. `OpenRouterModelSelection`: when the agent model id ends in `:free` or its name has a parameter tag ≤ 3B
   (`\b([0-9.]+)b\b` ≤ 3), show `This model is small. Answers may be no better than the one on this Mac.`
   (the configured `liquid/lfm-2.5-2.6b:free` triggers it).
6. The Now block (P4-01) and grounding for a cloud reader now use `agentCloudConsent`.

**Steps:**
1. Add `AgentLane` and `AgentModelRouting.provider(for:lane:roles:)` (keep P0-14's `roles:` injection) in
   `ModelRoleStore.swift`; implement Target 1.
2. Map every caller listed in Target 2; delete the `voice:` overload if nothing else calls it
   (`grep -rn "AgentModelRouting.provider(for" Sources/NextNotes`).
3. Add `Settings.agentCloudConsent` and the toggle (Target 3) with `DS` tokens only; add the small-model
   hint (Target 5).
4. Switch the Now block's cloud check (P4-01 Target 4) and `ToolLoop:756-759` to `agentCloudConsent`.
5. Add the self-test seams and cases below, confirm red, then implement.

**Do not:** do not route the conversational voice lane to the cloud (P5 does that behind its own consent); do not reuse
`knowledgeGraphCloudConsent` for this; do not let a role naming an auxiliary/draft file resolve (P0-03's guard must be in
place first — if `--selftest-model-roles` does not already fail on an auxiliary role, stop and do P0-03); do not store the
API key anywhere but the Keychain (`OpenRouterKeyStore`). (H-audit 2026-09-23) Do not seed the consent on every
launch (only when the key is absent), and never flip a stored `false` to `true`.

**Red-first self-test:** extend `--selftest-model-roles` (`Support/ModelRoles/ModelRoleSelfTest.swift`). Add seams
`AgentModelRouting.cloudReadyForTesting: Bool?` and `resolveForTesting: ((LLMProviderID) -> (any LLMProvider)?)?` so no
Keychain or network is touched.
- Role `agent = .appleFoundation`: `.background` lane resolves `.appleFoundation` (today `.appLLM` → red).
- Role `agent = .cloud`, cloud ready, `agentCloudConsent = false`, `knowledgeGraphCloudConsent = true`: `.typed` lane
  resolves an on-device id; a "check my email then summarise the last one" multi-step prompt does **not** go to
  `.openRouter` (today it does → red).
- Same with `agentCloudConsent = true` → `.openRouter`.
- `.conversational` → `.appLLM` in every case.
- (H-audit 2026-09-23, H1 #16) Migration, against a throwaway `UserDefaults(suiteName:)` (never the user's
  defaults): stored `modelRoles.agent` = the `.cloud` token and no `agentCloudConsent` key → after
  `Settings(defaults:)` init the key exists and is `true`; stored `.appleFoundation` token and no key → `false`;
  key already `false` with a `.cloud` role → stays `false`; a second init changes nothing. Red today: the key
  does not exist, so the first case reads `false`. (If `Settings` has no `defaults:` initializer, add one as a
  test seam; do not write `UserDefaults.standard` from the test.)
- Restore choices with `restoreChoicesForTesting` and settings to their prior values.
- Markers: `MODEL_ROLES_OK` / `MODEL_ROLES_FAILED` (existing; `NextNotesApp.swift:384-392`).

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-model-roles
Scripts/run-selftest.sh --selftest-openrouter-contract
Scripts/run-selftest.sh --selftest-toolloop
Scripts/run-selftest.sh --selftest-voice-scheduling
Scripts/run-selftest.sh --selftest-now-block
Scripts/run-selftest.sh --selftest-toolloop-live      # record the resolved model and the score
make acceptance TIER=core
```

**Success threshold:** `MODEL_ROLES_OK` with the four new cases and the four migration cases (H-audit 2026-09-23); on this Mac (stored
role `.cloud`) the first launch after the change leaves typed turns on OpenRouter; with an installed GGUF in the Agent role, background
voice work loads that model (an `agent.worker` `UsageRecord` row in P0-20's `usage.jsonl` names it — H-audit 2026-09-23; formerly a `metrics.jsonl` line), not Apple FM; eval not lower than before by more than one.

**Risks & rollback:** background work on the Agent-role GGUF contends with the frontend for compute — P0-06 moved
warmup to `.background` and P3-07 adds lanes; re-run `--selftest-voice-scheduling`. Rollback: map `.background` to
`.conversational` in one switch.

**Done when:** [ ] lanes in place, all callers mapped; [ ] new consent + UI + hint; [ ] (H-audit 2026-09-23) one-time consent migration seeded from the stored Agent role; [ ] `MODEL_ROLES_OK`; [ ] AGENTS.md
stale "every agent run has gone through Apple Foundation Models" sentence updated if P0-12 has not already.

---

### P4-10 — Post-meeting review fits a small window and reads the asks, not only the tail

**Finding(s):** H3 #3, #4, #16; H1 #25 (reader-scaled rounds) (H-audit 2026-09-23)  **Effort:** 2.5 days  **Depends on:** P0-20b (the `meeting.proposals` usage rows), P1-10a (the Apple FM window read at runtime)  **Unblocks:** P4-05, P4-13

**Why (what the user experiences today):** 6 of 6 meetings on this Mac have `agentActions: []` and no
`proposals.json`, although four of them list "**You** — send the proforma invoice / share the roadmap / send
the meeting summary" action items (H1 #25, H3 #3). The post-meeting pass reserves 900 output + 256 headroom +
512 lookup tokens on top of a system prompt of full persona, full grounding, 600 characters of memory,
`AgentPrompts.rules` and 11+ JSON tool schemas — roughly 2,800–3,000 tokens (estimate, H3 #3) — so on Apple
Intelligence's 4,096-token window `fit` very likely throws `AgentError.contextTooSmall` ("This model has too
little room left to read the meeting…") before the model reads a word. **This is not measured:** the failure
lives only in `AgentService.problems` (in memory) and in an info-level log line that ages out. When the window
does fit, the transcript is cut from the tail only, so "I'll send you the pricing" said at minute 8 of a
25-minute call is gone; and a write whose quote differs from the transcript by one comma is rejected.

**Files you will change:**
- `Agent/MeetingAgent.swift` — `AgentPolicy` rounds, window-derived reservations, compact prompt, tool
  selection, transcript windows, evidence matching, `FitReport`
- new `Agent/MeetingTranscriptWindows.swift` — pure window builder
- new `Agent/MeetingEvidenceMatcher.swift` — pure quote matcher (normalization + token LCS)
- `Agent/AgentPrompts.swift` — `system(compact:)`
- `Persona/AgentPromptContext.swift` — `assemble(…, compact: Bool = false)`
- `Meetings/MeetingActionReconciler.swift` — make `actionMatches` reachable (`static`, not `private`) or move the
  vocabulary into `MeetingAgent.toolNames(forCandidateAction:)` (below)
- `Agent/AgentService.swift` — pass anchors and the reader window; persist the failure
- `Meetings/MeetingModels.swift` — `Meeting.agentProblem` (+ `decodeIfPresent` in the hand-written `init(from:)`)
- `UI/Meetings/MeetingDetailView.swift` — banner falls back to the persisted problem
- `NextNotesApp.swift` — `--selftest-agent` prints the fit; register `--selftest-meeting-agent-fit`
- new `Agent/MeetingAgentFitSelfTest.swift`
- `AGENTS.md` (flag list), `Scripts/acceptance.sh` (INTEGRATION)

**Read for context (do not change):** `Meetings/MeetingContext.swift:34-87` (`MeetingCandidateAction`,
`MeetingContext`); `Meetings/MeetingContextStore.swift:113` (`load(meetingID:)`, file `context.json`);
`Agent/AgentAnswerBudget.swift:54` (`readerContextTokens(for:)`); `UI/Meetings/TranscriptView.swift:93`
(`plainText(speakerNames:)`, the line format windows must reproduce); AGENTS.md "Related-context brief" and
"Adding a property to `Meeting` without `decodeIfPresent`".

**Current behaviour** (verified 2026-09-24):
- `AgentPolicy.maxRounds = 2` (`Agent/MeetingAgent.swift:16`); `AgentPolicy.fromSettings()` (`:20-26`) returns
  `maxRounds: 2` and `autoRunReadTools: Settings.shared.agentAutoRunReadTools` (true by default).
- Fixed reservations (`:49-61`): `maxOutputTokens = 900`, `headroomTokens = 256`, `lookupTokens = 512`,
  `minimumTranscriptTokens = 500`.
- `MeetingAgent.fit` (`:409-449`):
  ```swift
  let system = AgentPrompts.system + "\n\n" + AgentPrompts.toolBlock(tools: tools)
  let lookups = policy.autoRunReadTools && policy.maxRounds > 1 ? Self.lookupTokens : 0
  let reserved = try await provider.countTokens(system)
      + Self.maxOutputTokens
      + Self.headroomTokens
      + lookups
  var budget = provider.contextTokens - reserved
  guard budget >= Self.minimumTranscriptTokens else { throw AgentError.contextTooSmall }
  ...
  let cut = try await cut(transcript, to: budget, provider: provider, keepingTail: true)
  ```
- `advertisedTools` (`:163-181`) advertises every Workspace tool up to `.send` (11 today, `Agent/WorkspaceTools.swift`)
  plus up to 3 knowledge read tools. `AgentPrompts.system` (`Agent/AgentPrompts.swift:14-16`) assembles the
  `.meetingAssistant` path, whose budget is full persona + full grounding + 600 characters of memory
  (`Persona/AgentPromptContext.swift:69-71`).
- `plan` (`:194`) uses `AgentPrompts.system` again (`:203`) and `maxTokens: Self.maxOutputTokens` (`:214`); a write is
  validated against the **fitted** transcript (`proposals(... transcript: fitted.transcript)`, `:104-110`).
- `isTranscriptEvidence` (`:359-365`):
  ```swift
  let cleaned = quote.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
  let body = transcript.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
  return cleaned.count >= 12 && body.contains(cleaned)
  ```
  The model's own quote is stored as `evidence: call.evidence` (`:350`).
- `AgentService.review` (`Agent/AgentService.swift:197-270`) resolves `ModelRoleStore.shared.provider(for: .agent)`
  (`:221`), calls `proposals(... policy: AgentPolicy.fromSettings())` (`:230-237`), and on error sets
  `self.problems[id] = error.localizedDescription` (`:266`) — memory only; `MeetingDetailView` shows it
  (`UI/Meetings/MeetingDetailView.swift:91-98`) until relaunch.
- `MeetingContext.candidateActions` carry `evidenceStart: TimeInterval?` (`Meetings/MeetingContext.swift:44`).
  **Correction to H3 #4:** `MeetingContext.actionItems` are `[MeetingContextItem]` (`:84`), which have **no**
  `evidenceStart` — only `text`, `speaker`, `source`, `createdAt`. They must be located in the transcript (Step 4).
- `--selftest-agent <dir>` (`NextNotesApp.runAgentSelfTest`, `NextNotesApp.swift:3922`, registered at `:545`) runs
  the pass with `policy: .dryRun` (`maxRounds: 1`, no reads — so **no lookup reserve**), no brief, the Agent-role
  provider, and prints `AGENT_OK: <model> proposed N action(s) …` or `AGENT_FAILED: <error>`. It never prints
  the fit numbers, and its policy differs from production's, so a dry run can pass where production throws.

**Target behaviour:**
1. **Probe first.** `--selftest-agent <dir>` prints one line per policy before planning:
   `AGENT_FIT policy=<dryRun|production> window=<n> system=<n> output=<n> headroom=<n> lookups=<n> reserved=<n> budget=<n> tools=<n> fits=<yes|no>`,
   and accepts `--agent-provider apple|role` (default `role`). With `apple` it uses
   `LLMProviders.make(.appleFoundation)`. The executor records both lines for Apple FM on a real meeting folder in
   `STATUS.md`, plus the P0-20b row counts (Step 0), **before** changing any gate.
2. **Small reader (window ≤ 8,192 tokens, read with `AgentAnswerBudget.readerContextTokens(for:)`):**
   one round and no lookup reserve (reads are neither run nor advertised), output 600 tokens, the persona short
   card and compact grounding, and only the write tools that `MeetingContext.candidateActions` point at
   (table below; when there are no candidates, `draft_email`, `create_event`, `create_doc` — estimate of the
   three most common asks). Knowledge tools are not advertised on a small reader.
3. **Large reader (window ≥ 32,768):** `maxRounds = 3` (H1 #25: "more than that on a 4B model is a loop" is a
   per-model fact; a 32K+ reader is not a 4B model on Apple's window). Between 8K and 32K: today's 2 rounds,
   900 output, lookup reserve kept.
4. **Transcript section when the whole transcript does not fit:** windows of ±30 s around each ask, newest
   ask first, until the budget is spent, then the tail with whatever is left; rendered in chronological
   order in the same `plainText` line format, windows separated by a line `…`. Asks = every
   `candidateActions[i].evidenceStart`, plus every `actionItems[i]` located in the transcript (Step 4). When
   the whole transcript fits, it is sent whole (no change).
5. **Evidence matching:** normalize both sides (lowercase; `’ ‘ ʼ` → `'`; `“ ” «»` → `"`; drop every character
   that is not a letter, digit, space or apostrophe; collapse whitespace). Accept when the normalized quote
   has ≥ 12 characters and either is a substring of the normalized transcript, or the quote's content-token
   sequence (`MemoryGuard.contentTokens`) matches a transcript window at ≥ 90 % by token LCS
   (`lcs / quoteTokens.count ≥ 0.9`, window = quote length + 25 %). The stored `evidence` is the
   **transcript's** words for the matched span (original casing), never the model's.
6. **The failure survives a relaunch:** `Meeting.agentProblem: String?` is written when a review fails (including
   `noProvider` and `contextTooSmall`) and cleared when a review succeeds or the user dismisses the banner.
   `MeetingDetailView` shows `agent.problem(for:) ?? meeting.agentProblem`.
7. The rule that a write needs a quote the user actually said is unchanged in spirit: every accepted quote maps
   to real transcript words (Target 5), and the prompt still asks for an exact quote.

| Candidate `action` (normalized) | Write tools advertised on a small reader |
|---|---|
| `send`, `email` | `draft_email`, `send_email` |
| `share` | `draft_email`, `send_email`, `upload_to_drive` |
| `create`, `write` | `create_doc` |
| `append`, `update` | `append_doc` |
| `upload` | `upload_to_drive` |
| `schedule` | `create_event` |
| anything else | none (the default trio applies only when no candidate maps to any tool) |

**Steps:**
0. **Read before changing anything.** On this Mac (read-only):
   `grep '"feature":"meeting.proposals"' "$HOME/Library/Application Support/Next Notes/usage.jsonl" | tail -20`
   and note per row: provider, `counts.rounds`, `counts.calls`, `counts.proposals`, `counts.refusals`,
   `errorClass`. If P0-20b has not landed (no such rows), stop: this task depends on it. Then implement
   Step 1 only, build, install, and run the probe (Verify, lines 3–4) on one real meeting folder; paste both
   `AGENT_FIT` lines into `STATUS.md`. If `fits=yes` for the production policy on Apple FM, say so in
   `STATUS.md` and still do Steps 2–8 (the tail cut and the evidence rule stand on their own).
1. **FitReport.** In `MeetingAgent`:
   ```swift
   struct FitReport: Sendable, Equatable {
       let window, systemTokens, outputTokens, headroom, lookups, reserved, budget, toolCount: Int
       var fits: Bool { budget >= MeetingAgent.minimumTranscriptTokens }
   }
   struct PassShape: Sendable, Equatable {       // what a pass is allowed, derived from the window
       let window: Int
       let compact: Bool                          // window <= 8_192
       let rounds: Int                            // compact ? 1 : (window >= 32_768 ? 3 : policy.maxRounds)
       let outputTokens: Int                      // compact ? 600 : 900
       let lookups: Int                           // compact || !policy.autoRunReadTools || rounds < 2 ? 0 : 512
   }
   static func shape(window: Int, policy: AgentPolicy) -> PassShape
   func fitReport(tools: [AgentTool], shape: PassShape, provider: any LLMProvider) async throws -> FitReport
   ```
   Make `minimumTranscriptTokens` internal (`static let`, not `private`). `fit` calls `fitReport` and throws
   `contextTooSmall` when `!fits`, exactly as today. In `runAgentSelfTest`, compute and print the two
   `AGENT_FIT` lines (dryRun shape and `AgentPolicy.fromSettings()` shape) before `proposals`; add
   `SelfTest.value(after: "--agent-provider")`.
2. **Compact prompt.** `AgentPromptContext.assemble` gains `compact: Bool = false`; when true the persona is
   `personaStore.shortCard()` and grounding `.compact`, whatever the path's budget. `AgentPrompts` gets
   `static func system(compact: Bool) -> String` (`system` stays as `system(compact: false)`). `plan` takes the
   system string and the `PassShape` as parameters instead of reading `AgentPrompts.system` and
   `Self.maxOutputTokens` (`:203`, `:214`), so fit and plan always use the same prompt.
3. **Tool selection.** `advertisedTools(policy:provider:includeKnowledge:candidates:shape:)`: when
   `shape.compact`, return `WorkspaceTools.tools(upTo: policy.allowedRisk)` filtered to
   `MeetingAgent.toolNames(forCandidateActions:)` (table above; reuse the vocabulary of
   `MeetingActionReconciler.actionMatches`, `Meetings/MeetingActionReconciler.swift:149-170` — add a shared
   `static func` rather than a second copy) and no knowledge tools; otherwise today's list.
4. **Anchors.** New parameter on `proposals(for:segments:notes:brief:context:provider:policy:)`:
   `context: MeetingContext? = nil`. `AgentService.review` passes `self.context(for: id)` (the same private
   helper, `AgentService.context(for:)` at `AgentService.swift:174`); `runAgentSelfTest` passes
   `MeetingContextStore.shared.load(meetingID: meeting.id)` when the folder has `context.json`.
   Anchor times: `candidateActions.compactMap(\.evidenceStart)`; for each `actionItems` item, the `start` of the
   first segment whose normalized text contains ≥ 60 % of the item's content tokens (estimate; skip the item
   when none does).
5. **Windows.** `enum MeetingTranscriptWindows { static func build(segments: [TranscriptSegment], anchors: [TimeInterval], speakerNames: [String: String], budgetCharacters: Int, radius: TimeInterval = 30) -> String }`
   — pure. Anchors sorted descending; for each, the segments with `start` in `[a − radius, a + radius]`
   (merge overlapping ranges); add whole windows while they fit `budgetCharacters`; then append the longest
   tail of segments that still fits; render chronologically with `[TranscriptSegment].plainText(speakerNames:)`,
   joining non-contiguous ranges with a line `…`. In `fit`, when the transcript's token count exceeds the
   budget **and** anchors are non-empty, convert the token budget to characters with the measured ratio (the
   same trick `cut` uses, `:458-470`) and use `build`; with no anchors keep the tail cut.
6. **Evidence.** `enum MeetingEvidenceMatcher { static func normalize(_:) -> String; static func match(quote: String, in transcript: String) -> String? }`
   returning the transcript span (original text) or nil. `isTranscriptEvidence` becomes
   `match(quote:in:) != nil`; `proposals(from:)` stores the returned span as `evidence` (`:350`). Keep the
   12-character minimum on the normalized quote.
7. **Rounds.** `AgentPolicy.fromSettings()` keeps its signature; `MeetingAgent.proposals` computes
   `shape(window:policy:)` from `await AgentAnswerBudget.readerContextTokens(for: provider)` and passes
   `shape.rounds` to `plan` in place of `policy.maxRounds`. `liveProposals` keeps `.live` (1 round, no reads).
8. **Persisted failure.** `Meeting`: `var agentProblem: String?` beside `agentActions`
   (`Meetings/MeetingModels.swift:236`), memberwise `init` parameter defaulting to nil, and in the hand-written
   `init(from:)` (`:316-337`): `agentProblem = try container.decodeIfPresent(String.self, forKey: .agentProblem)`.
   `AgentService.review`: on each `self.problems[id] = …` also `store.save(meeting with agentProblem = message)`
   (`MeetingStore.save`, `Meetings/MeetingStore.swift:145`, re-reading the meeting by id first); on success
   and in `clearProblem(for:)`, save with `agentProblem = nil`. `MeetingDetailView`: `agent.problem(for:) ??
   meeting.agentProblem` for the banner message.
9. Register `--selftest-meeting-agent-fit` (below) in `NextNotesApp.runRequestedSelfTest`, the AGENTS.md flag
   list, and `Scripts/acceptance.sh` INTEGRATION as `"selftest-meeting-agent-fit|120"`.

**Do not:**
- Do not relax the quote rule into "anything similar": the LCS match is on content tokens at ≥ 90 % and the
  stored evidence is the transcript's words. Do not accept a quote from the notes or the brief.
- Do not change `AgentPrompts.maxProposals`, the "often zero" line or `argumentsGroundedInTranscript`
  (P4-03(i) owns prompt wording; H1 #29/#30 say these gates help).
- Do not give the brief to the map step or let it supply an argument (AGENTS.md "Related-context brief"); the
  window builder reads transcript segments only.
- Do not add a `Meeting` field without `decodeIfPresent` in the hand-written `init(from:)` — a missing key
  orphans every meeting on disk. Keep `id`, `title`, `start` required.
- Do not reuse a brief assembled for a local reader for a cloud one.
- Do not let `--selftest-agent` or the new self-test write `proposals.json`, `meeting.json` or any real store;
  the new self-test uses fakes and a temp directory only.
- `MainActor.assumeIsolated` is forbidden; use `await MainActor.run`.
- Build with `make build`, install with `make install OPEN=0`, run self-tests with `Scripts/run-selftest.sh`
  in the foreground, one at a time.

**Red-first self-test:** new `--selftest-meeting-agent-fit` in `Agent/MeetingAgentFitSelfTest.swift` (no model, no
account, no user store). Fakes: `FakeWindowProvider: LLMProvider` with a settable `contextTokens` and
`countTokens(text) = text.count / 4` (estimate); a fixture 25-minute transcript of 150 segments (10 s each,
generated text) in which segment 48 (t = 480 s) reads "Ana: Can you send me the pricing sheet by Friday?" and
the last segment is small talk; a `MeetingContext` with one candidate `send`/`pricing sheet`, `evidenceStart: 480`,
and one action item "You — share the roadmap" matching segment 100's text.
- Case A (small window fits): window 4,096, production policy → `shape.compact == true`, `rounds == 1`,
  `lookups == 0`, `outputTokens == 600`; `fitReport(...).fits == true`; tools advertised = `draft_email`,
  `send_email` exactly (from the one `send` candidate; action items do not select tools), no knowledge
  tools. Red today: the fixed 900 + 256 + 512 reservation with the full prompt and 11 schemas.
- Case B (asks survive): the fitted transcript at window 4,096 contains "send me the pricing sheet" and
  "share the roadmap"; it also contains the last segment's text. Red today: the tail cut drops minute 8.
- Case C (large window): window 32,768 → `rounds == 3`, `lookups == 512`, `outputTokens == 900`; whole
  transcript sent (no `…` line).
- Case D (evidence): `match(quote: "can you send me the pricing sheet, by friday", in: transcript)` returns the
  transcript's `Can you send me the pricing sheet by Friday` span; `"Can you send me the pricing-sheet by Friday"`
  (hyphen) → match; a quote with two content words changed ("Can you send me the budget file by Friday") → nil;
  `"pricing"` (under 12 characters) → nil. Red today: the comma variant is rejected.
- Case E (persisted failure): encode a `Meeting` with `agentProblem = "x"`, decode → `"x"`; decode a
  `meeting.json` fixture string without the key → nil and the meeting decodes.
- Markers: each failure `MEETING_AGENT_FIT_WRONG: <case>: <reason>`, final `MEETING_AGENT_FIT_OK` or
  `MEETING_AGENT_FIT_FAILED: <n> case(s)`. No model is used, so there is no `_ABSENT`.
- Red: land the test first with `shape(window:policy:)` returning today's constants and `build` returning the
  tail → Cases A, B, D fail.

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-meeting-agent-fit
Scripts/run-selftest.sh --selftest-agent "$HOME/Library/Application Support/Next Notes/Meetings/<a meeting folder>" --agent-provider apple
Scripts/run-selftest.sh --selftest-agent "$HOME/Library/Application Support/Next Notes/Meetings/<a meeting folder>"
Scripts/run-selftest.sh --selftest-notes-context
Scripts/run-selftest.sh --selftest-meeting-reconcile
Scripts/run-selftest.sh --selftest-persona
Scripts/run-selftest.sh --selftest-tool-awareness
make acceptance TIER=core
```
(`--selftest-agent` runs `.dryRun` and executes nothing; pick a folder that has `transcript.json` and
`context.json` — the WhatsApp/FaceTime meetings on this Mac have them, H3 #4.)

**Success threshold:** `MEETING_AGENT_FIT_OK`; on this Mac `AGENT_FIT policy=production … fits=yes` with Apple FM
on every one of the 6 meeting folders (record the six `budget=` values); `--selftest-agent --agent-provider
apple` ends `AGENT_OK` on at least 4 of the 6 folders (it failed or proposed nothing on 6/6 before, H1 #25 —
estimate; if proposals stay at 0 on all six with `fits=yes`, record it and hand the prompt question to P4-05,
do not loosen gates here); after one real meeting, its P0-20b row shows no `errorClass`, or a persisted
`agentProblem` that survives a relaunch.

**Risks & rollback:** a short persona card makes the meeting assistant blander (acceptable for a pass whose output
is tool calls). Fewer advertised tools can hide the right one when the extractor missed the ask → the default
trio covers the common cases; watch `counts.proposals` in `usage.jsonl`. The LCS match may accept a paraphrase
that drops a negation ("don't send") → content tokens include `send`, but `don't` is not a content token; guard:
reject a match when the transcript span contains `not`/`n't`/`never` and the quote does not (add as Case D2 if
it fires). Rollback: `shape(window:policy:)` returning today's constants restores the old pass;
`agentProblem` is an optional field and can stay.

**Done when:**
- [ ] probe lines for Apple FM and the P0-20b row counts recorded in `STATUS.md` before any gate changed
- [ ] `PassShape` derived from the reader window; compact prompt; candidate-scoped tools; 3 rounds at ≥ 32K
- [ ] transcript windows around asks + tail; evidence matcher stores transcript words
- [ ] `Meeting.agentProblem` with `decodeIfPresent`; banner survives relaunch
- [ ] `MEETING_AGENT_FIT_OK`; `AGENT_FIT … fits=yes` on Apple FM; flag in AGENTS.md and acceptance INTEGRATION

---

### P4-11 — Memory review stops echoing saved facts and keeps short ones

**Finding(s):** H3 #7, #8, #9, #25; H1 #23 (H-audit 2026-09-23)  **Effort:** 2 days  **Depends on:** P4-07a, P4-07, P0-11 (the review's writer and ledger must not touch the user's real stores from a self-test)  **Unblocks:** — (complements P4-07)

**Why (what the user experiences today):** The background memory review almost never adds anything. Over the
200 ledger rows on this Mac (2026-09-22 16:05 → 09-23 22:40, H3 #7): 103 proposals, 4 saved; **57 (55 %)**
skipped as "already remembered" and **25 (24 %)** refused as "you didn't say which memory to change" — both
restatements of the two facts already stored, because the review prompt opens with the whole memory
(`"Current memory (data): "`) and a ~3B model copies what it is shown. Short durable facts never reach the
model at all: the harvest drops every sentence under 24 characters, so "My brother is Cyril." (20),
"I live in Paris." (16) and "Call me Serge." (14) are thrown away as filler (H3 #8). The one real firing of
the "environment failure" skip rule dropped a durable work-style fact (H3 #9). And "200 runs, 2 facts" was read
as a lifetime figure because the ledger keeps only 200 rows, about 30 hours (H3 #25).

**Files you will change:**
- `Memory/MemoryReviewer.swift` — `MemoryReviewModel.contextTokens`; relevant-only memory in `userPrompt`;
  system-prompt wording; skip-regex narrowing; update→remember retry
- `Memory/MemoryReviewAppleModel.swift` — `contextTokens`
- `Memory/MemorySources.swift` — harvest floor
- `Memory/RoutineSuggestions.swift` — lifetime totals in `MemoryReviewStateStore`
- `UI/Settings/MemoriesSection.swift` — totals line in `MemoriesEditor`
- `Memory/MemoryReviewSelfTest.swift`, `Tests/Fixtures/memory-review.json` — cases

**Read for context (do not change):** `Memory/MemoryGuard.swift:273` (`provenanceProblem`), `:393-402`
(`targetProblem`), `:474` (`contentTokens`), `:489` (`saysTheSameFact`); `Memory/MemoryTools.swift:115-126` (the
`update` case that throws `MemoryWriteError.provenance(problem)`); `Memory/MemoryReviewLedger.swift:13`
(`MemoryReviewRun`); P4-07 (explicit statements, the complementary direct path).

**Current behaviour** (verified 2026-09-24):
- `MemoryReviewer.userPrompt(_:memory:)` (`Memory/MemoryReviewer.swift:573`) starts with
  `var sections = ["Current memory (data): " + MemoryWriteError.render(memory)]` (`:581`) — every usable entry,
  whatever the provider. The system prompt says "…current memory. Most of it needs nothing." (`:543`) and lists
  "anything already in current memory" among the things not to save (`:563`).
- `MemoryReviewModel` (`:317-320`) has only `label` and `complete(system:user:)`; nothing tells the review the
  reader's window. Production models: `ProviderMemoryReviewModel` (`:322`), `AppleMemoryReviewModel`
  (`Memory/MemoryReviewAppleModel.swift:38`); the self-test uses `ScriptedMemoryReviewModel` (`:371`).
- `MemoryHarvest.minimumSentence = 24` (`Memory/MemorySources.swift:30`), applied in `sentences(_:)`:
  `guard text.count >= minimumSentence else { continue }` (`:214`).
- `MemoryReviewSkipRules` (`Memory/MemoryReviewer.swift:441-493`): `environmentFailure` (`:465-466`) matches any
  bare `errors?|failed|…|offline|…|unavailable|unreachable|bug(gy|s)?`; `oneOff` (`:477-484`) ends with
  `|\bsearch\w*\b` — any word starting with "search".
- In `MemoryReviewer.review` (`:598-660`) a writer error is appended to `outcome.refused` and the loop
  `continue`s (`:640-645`); a `memory.update` whose target the user never named fails in
  `MemoryToolExecutor` (`Memory/MemoryTools.swift:120-121`) with
  `MemoryWriteError.provenance("you didn't say which memory to change.")` and the fact is lost.
- `MemoryReviewStateStore.runLimit = 200` (`Memory/RoutineSuggestions.swift:132`); `record(run:sourceKey:)`
  (`:184-190`) drops the oldest row; the on-disk `Stored` struct (`:249-260`) has only optional additions, decoded
  by the synthesized `init(from:)`.

**Target behaviour:**
1. **Relevant-only memory on small readers.** When the review model's `contextTokens ≤ 8_192` (Apple FM, the ~3B
   local models), the user prompt carries only the saved entries whose content words
   (`MemoryGuard.contentTokens`) overlap the job's **user** turns' content words, at most 5, ranked by overlap
   count then recency, under the heading
   `Facts already saved — do not repeat (data): ` — or no memory section at all when none overlap. Only those
   entries can be `update`/`forget` targets anyway (`targetProblem` requires the user's words to name the
   entry). Readers above 8K keep today's full section, renamed with the same heading. The code-level duplicate
   check (`MemoryReviewSkipRules.reason` → "already remembered") stays.
2. **System prompt wording** follows: "anything already in current memory" → "anything in the facts already
   saved"; "Most of it needs nothing." stays.
3. **Short facts reach the review.** The harvest keeps a sentence when it has at least 2 content tokens that are
   not filler: `MemoryGuard.contentTokens(text).filter { !MemoryHarvest.filler.contains($0) }.count >= 2`, with
   `MemoryHarvest.filler` = `yeah, yes, yep, okay, sure, right, alright, cool, great, thanks, thank, hmm, uhm,
   well, sorry, please, just, really, actually` (estimate; extend only with a fixture that needs it). The
   6,000-character job budget (`charactersPerJob`, `:32`) is unchanged.
4. **Narrower skip rules.**
   - `environmentFailure` fires only with an environment frame: a failure word **and** an app, device, network
     or permission object in the same sentence (`app|mac|computer|laptop|phone|wifi|wi-fi|internet|network|connection|server|website|site|microphone|mic|camera|bluetooth|permission|model|download|update|sync|login|account`),
     or a present-tense clause `(isn't|doesn't|won't|can't|keeps?) (work|connect|load|open|sync|start)`.
     Bare `unavailable`, `offline`, `bug(s)`, `fail…` alone no longer match.
   - `oneOff` drops the trailing `|\bsearch\w*\b`; the continuous forms (`is searching`, `wants to search`,
     `searched`) stay caught by the clauses before it.
   - These four sentences are **kept** (a fixture case each): "The user is unavailable on Fridays.",
     "The user prefers offline-first tools.", "The user's company builds search software.",
     "The user fixes bugs before features." These stay **skipped**: "The user's microphone isn't working.",
     "The user is searching for the budget.", "The app failed to sync the user's calendar."
5. **Target-less update becomes a remember, once (H1 #23).** In `MemoryReviewer.review`, when
   `call.name == "memory.update"`, the provenance origin is `.memoryReview`, and the writer throws
   `MemoryWriteError.provenance("you didn't say which memory to change.")`, retry **once** as
   `AgentToolCall(name: "memory.remember", arguments: ["kind": call.arguments["kind"] ?? "profile", "text": text], rationale: "", evidence: nil)`
   — but only when `MemoryGuard.provenanceProblem(text, provenance: provenance) == nil` and
   `MemoryReviewSkipRules.reason(tool: "memory.remember", …)` is nil (so the "already remembered" duplicate
   check still applies). A refused retry is recorded as a refusal of the original call with the retry's reason.
   No other refusal is retried; `memory.forget` is never retried.
6. **Lifetime totals (H3 #25).** `agent-memory-review.json` gains `lifetime: MemoryReviewTotals?`
   (`runs`, `proposed`, `saved`, `skipped: [String: Int]`, `refused: [String: Int]`, `since: Date`), updated in
   `record(run:sourceKey:)` before the 200-row trim; `nil` in an older file is seeded once from the kept rows
   (their counts, `since` = the oldest kept row's `at`). The 200-row cap stays. `MemoriesEditor` shows one line under "Last looked":
   "Since <date>: looked <runs> times, saved <saved>." (no developer words; no reason keys on screen).

**Steps:**
1. `MemoryReviewModel`: add `var contextTokens: Int { get }` with a protocol extension default of `8_192`;
   `ProviderMemoryReviewModel` returns `provider.contextTokens`; `AppleMemoryReviewModel` returns
   `LLMProviders.make(.appleFoundation).contextTokens` (4,096 today, the runtime value after P1-10a);
   `ScriptedMemoryReviewModel` gets `init(contextTokens: Int = 4_096, delay:_:)`.
2. `MemoryReviewer.userPrompt(_ job:, memory:, contextTokens: Int)`: implement Target 1 with a helper
   `static func relevantMemory(_ memory: [MemoryEntry], for job: MemoryReviewJob, limit: Int = 5) -> [MemoryEntry]`;
   pass `model.contextTokens` from `review` (`:609-610`). Update the two system-prompt lines (Target 2).
3. `MemoryHarvest`: replace `minimumSentence` with `static let filler: Set<String>` and
   `static func isWorthReading(_ text: String) -> Bool` (Target 3); `sentences(_:)` uses it at `:214`. Grep
   `minimumSentence` and update every other reader (self-tests included).
4. `MemoryReviewSkipRules`: rewrite `environmentFailure` as two patterns combined with AND in `reason`
   (failure word, environment object) OR the present-tense clause; delete the `\bsearch\w*\b` alternative.
   Stay inside AGENTS.md's safe regex subset (`\b`, classes, alternation, lazy/greedy quantifiers).
5. `MemoryReviewer.review`: implement Target 5 inside the existing `catch` (`:640-645`), before appending the
   refusal. Match the error by value: `if case MemoryWriteError.provenance(let why) = error, why == "you didn't say which memory to change."`.
   Better: add `static let untargetedUpdate = "you didn't say which memory to change."` to `MemoryGuard` and
   use it in both `targetProblem` (`:400`) and here, so the string cannot drift.
6. `MemoryReviewStateStore`: add `struct MemoryReviewTotals: Codable, Equatable` and the optional `lifetime`
   field in `Stored` (`:249-260`); update in `record(run:sourceKey:)`; expose `var lifetime: MemoryReviewTotals`.
7. `MemoriesEditor` (`UI/Settings/MemoriesSection.swift:65`): the totals line, `DS.Font.caption`,
   `DS.Color.textSecondary`; no literal sizes.
8. Fixtures and self-test (below). Coordinate with P4-07: if it has landed, append to its fixture cases in
   `Tests/Fixtures/memory-review.json` rather than reordering them.

**Do not:**
- Do not remove the code-level duplicate check or any `MemoryGuard` rule (H3 #30: all 36 real refusals except
  the #9 one were correct).
- Do not retry `memory.forget`, and do not retry an update refused for any reason other than the missing target.
- Do not send the full memory to a ≤ 8K reader "just for update targets" — a target the user did not name is
  refused anyway.
- Do not lower the 6,000-character job budget, the 5-call cap (`maxCalls`, `:516`) or the 200-row ledger cap.
- Do not add a `Stored` field without making it optional (the synthesized `init(from:)` decodes optionals with
  `decodeIfPresent`; a non-optional field makes every existing `agent-memory-review.json` unreadable and the
  store "starts fresh", losing the watermark).
- A self-test never writes the user's real memory, ledger or audit log: use the review self-test's temp stores
  and `StoreMemoryReviewWriter` (P0-11).
- UI strings: no `review`, `ledger`, `run`, reason keys or counts by reason on screen; `--selftest-ui-strings`
  must stay OK. Views use `DS` tokens only.

**Red-first self-test:** extend `--selftest-memory-review` (`Memory/MemoryReviewSelfTest.swift`; final marker stays
`MEMORY_REVIEW_OK` / `MEMORY_REVIEW_FAILED`, per-case lines `MEMORY_REVIEW_WRONG: …` as the file prints them today, `:48`). All fixtures use the temp store the file already builds (`:153-157`).
- **Echo fixture (the threshold):** 10 scripted jobs, each one user turn stating one new fact; memory seeded with
  8 unrelated facts; exactly one job's user turn shares a content word with one seeded fact. The scripted model
  is an **echo model**: for every line of the prompt under the memory heading it proposes
  `memory.remember` with that line's text, then proposes the job's new fact. Compute
  `echoShare = proposals whose text saysTheSameFact(an existing entry) / all proposals` over the 10 jobs; print
  `MEMORY_REVIEW_ECHO_SHARE <x.xx>`; fail when `≥ 0.15`. Expected after: 1 / 11 ≈ 0.09; today: 80 / 90 ≈ 0.89 (red).
  Also assert the prompt for a job with no overlap contains no seeded fact text.
- **Harvest:** `MemoryHarvest.sentences(["My brother is Cyril.", "I live in Paris.", "Call me Serge.", "okay", "yeah, sure", "Thanks!"])`
  returns exactly the first three. Red today: returns none.
- **Skip rules:** the four keep-sentences in Target 4 → `MemoryReviewSkipRules.reason(...) == nil`; the three
  skip-sentences → non-nil. Add the four keep-cases to `Tests/Fixtures/memory-review.json` in its existing case
  shape (`turns`, `scripted`, `expect.saves`) so the scored run also counts them. Red today: all four are
  skipped.
- **Update retry:** job "My dad is Mathieu." with memory seeded "The user's brother is Cyril."; scripted
  `memory.update {"match": "brother", "text": "The user's dad is Mathieu."}` → the store holds the dad fact and
  still holds the brother fact; the run's `refused` is empty. And a second case where the retry text restates a
  saved fact → skipped "already remembered", nothing saved. Red today: refused, nothing saved.
- **Totals:** a temp `MemoryReviewStateStore` fed 205 runs → `runs.count == 200`, `lifetime.runs == 205`; a
  fixture `agent-memory-review.json` without `lifetime` loads with its runs intact (no "starting fresh" log).
- Precision must not fall: `MEMORY_REVIEW_PRECISION` printed by the scored pass (`:230`) is ≥ its value before
  the change (record both in `STATUS.md`).

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-memory-review
Scripts/run-selftest.sh --selftest-memory
Scripts/run-selftest.sh --selftest-memory-portability
Scripts/run-selftest.sh --selftest-ui-strings
make acceptance TIER=core
```
Optional, owner-run (not a gate): `Scripts/run-selftest.sh --selftest-memory-review --model local` when a local
model is installed.

**Success threshold:** `MEMORY_REVIEW_OK`; `MEMORY_REVIEW_ECHO_SHARE` < 0.15 on the scripted echo fixture (it is
≈ 0.89 before); the three short sentences harvested; four keep-cases kept, three skip-cases skipped; the update
retry saves exactly one fact; `MEMORY_REVIEW_PRECISION` not lower than before. Owner observation of the next 50
real ledger rows (echo share, H3 target < 15 %) is recorded in `STATUS.md` when available but is **not** a gate.

**Risks & rollback:** fewer entries in the prompt may let a small model propose a duplicate the code check then
skips (costs a call, not a wrong save). A looser harvest sends more dictation text to the review (85 % of its
input is dictation aimed at other apps, H3 #7) → more model calls; watch `counts` in P0-20's `memory.review`
usage rows. The narrower environment rule could let a transient complaint through → the fixture's three
skip-cases pin the common shapes. Rollback: each target is independent (`contextTokens` threshold to 0 restores
the full memory; the old regexes and `minimumSentence` are one-line restores).

**Done when:**
- [ ] relevant-only memory (≤ 5, labelled) for readers ≤ 8K; echo share < 0.15 on the fixture
- [ ] harvest floor is ≥ 2 non-filler content tokens; three short facts harvested
- [ ] skip regexes narrowed; four keep-cases in `Tests/Fixtures/memory-review.json`
- [ ] target-less update retried once as remember on the review path only
- [ ] lifetime totals persisted with optional decoding and shown in the Memories sheet
- [ ] `MEMORY_REVIEW_OK`, `MEMORY_OK`, `MEMORY_PORTABILITY_OK`, `UI_STRINGS_OK`

---

### P4-12 — Routines run on Apple Intelligence and may be as long as their template needs

**Finding(s):** H3 #10, #11, #23 (H-audit 2026-09-23)  **Effort:** 1.5 days  **Depends on:** none inside Phase 4 (soft: P1-05 for native tool calls on Apple FM — see Risks)  **Unblocks:** P4-04, P4-06

**Why (what the user experiences today):** A routine picks its model with a router that knows only the llama
model and OpenRouter. With no GGUF installed or loadable and OpenRouter absent or rate-limited (33 of 200 memory
review runs on this Mac failed "OpenRouter rate-limited", up to 27 in a row on 09-22, H3 #7), every routine,
every trigger (`meetingStarting`, `notesReady`) and every goal nudge that needs a model is skipped — although
Apple Intelligence is resident on this Mac. The memory review had exactly this bug and was fixed by adding an
Apple route (`MemoryReviewRouter`); routines never got the fix (H3 #10). When a routine does run, its answer
is cut at 384 tokens per round, so the morning digest's sections (masthead, week grid, desks, watch items) and a
two-host podcast script cannot fit even with their prompt override (H3 #11; the conflict is documented in
`DigestTemplate.swift:32-36` and `PodcastTemplate.swift:26-29`). And a digest the user set for 07:00 is held
until 08:00 because quiet hours hold every routine's result, although a reminder set inside quiet hours is
delivered on time (H3 #23).

**Files you will change:**
- `Agent/Schedules/ScheduledRunner.swift` — `RoutineModelRoute.appleFoundation`, router rows, environment seam,
  live model resolution, token budget
- `Agent/Schedules/AgentSchedule.swift` — `Budget.maxOutputTokens`, `effectiveMaxOutputTokens`
- `Agent/Schedules/ScheduleTools.swift` — template budget at `schedule.create`
- `Agent/Schedules/AgentScheduler.swift` — quiet-hours rule for a routine's own slot
- `Agent/Schedules/RoutineAuthoritySelfTest.swift`, `Agent/Schedules/ScheduleSelfTest.swift` — cases
- the three fake environments: `Agent/Schedules/DigestSelfTest.swift:317`, `Agent/Schedules/PodcastSelfTest.swift:554`,
  `Agent/Schedules/RoutineAuthoritySelfTest.swift:593` (only if the protocol default below does not cover them)

**Read for context (do not change):** `Memory/MemoryReviewer.swift:106-148` (`MemoryReviewRouter.route`, the
precedent: local → Apple → cloud → wait), `:1183-1185` (`LiveMemoryReviewEnvironment.isAppleFoundationAvailable`),
`:1194-1214` (`LiveMemoryReviewModels`: "Through `make`, not a bare `LlamaLLMProvider()`"); `Memory/MemoryReviewAppleModel.swift:38`
(why the memory review uses guided generation on Apple FM); `Agent/Schedules/DigestTemplate.swift:45`
(`title = "Morning digest"`), `Agent/Schedules/PodcastTemplate.swift:38` (`title = "Your morning podcast"`, and
`resultTransform` at `:127-130` already identifies its schedules by title).

**Current behaviour** (verified 2026-09-24):
- `RoutineModelRoute` (`Agent/Schedules/ScheduledRunner.swift:21-25`) has `.local`, `.cloud`, `.skip(String)`.
  `RoutineModelRouter.route(choice:isRecording:local:cloudConfigured:)` (`:27-56`):
  ```swift
  case .auto:
      if localRunnable { return .local }
      if cloudConfigured { return .cloud }
      return .skip(localReason)
  case .local:
      return localRunnable ? .local : .skip(localReason)
  ```
- `ScheduledRunner.run` (`:246-262`) routes, then `environment.model(for: route)`, and labels the task
  `backend: route == .local ? "local" : "openrouter"` (`:262`).
- `LiveScheduledRunEnvironment.model(for:)` (`:527-539`):
  `.local` → `ProviderMemoryReviewModel(provider: LlamaLLMProvider(), maxTokens: 384)` (`:531`) — a bare provider
  that ignores the model library and `ModelRoleStore`; `.cloud` → OpenRouter with `maxTokens: 384` (`:533-535`).
- `ScheduledRunEnvironment` (`:175-180`): `isRecording`, `localModelState()`, `isCloudConfigured()`, `model(for:)`.
- `AgentSchedule.Budget` (`Agent/Schedules/AgentSchedule.swift:36-41`): `maxSeconds`, `maxToolCalls`,
  `standard = Budget(maxSeconds: 180, maxToolCalls: 8)`; `AgentSchedule` uses the synthesized `init(from:)`.
- The runner's rules end "answer in plain language in at most three sentences" (`:441`) — P4-06 Target 2 owns
  that sentence.
- Quiet hours: a reminder is delivered when its own slot is inside quiet hours
  (`AgentScheduler.swift:505-507`: `if schedule.kind == .reminder, settings.isQuiet(now, zone: zone), !settings.isQuiet(deliveredSlot, zone: zone)`).
  A routine's result is held whenever `now` is quiet (`deliverRoutineResult`, `:648-669`:
  `if !ignoreQuiet, settings.isQuiet(now, zone: zone) { … held … }`), and the class doc says so (`:143-150`).
- The router rows are pinned in `--selftest-routine-authority` (`RoutineAuthoritySelfTest.swift:76-95`), which
  binds `let route = RoutineModelRouter.route` and calls it positionally with four arguments.

**Target behaviour:**
1. **Apple route.** `RoutineModelRoute` gains `.appleFoundation`. `route(choice:isRecording:local:cloudConfigured:appleAvailable: Bool = false)`:

   | choice | rule, in order |
   |---|---|
   | `.auto` | local runnable → `.local`; recording and cloud configured → `.cloud`; Apple available → `.appleFoundation`; cloud configured → `.cloud`; else `.skip(localReason + ", OpenRouter isn't set up and Apple Intelligence isn't available")` |
   | `.local` | local runnable → `.local`; Apple available → `.appleFoundation`; else `.skip(localReason + " and Apple Intelligence isn't available")` |
   | `.cloud` | unchanged |

   (While recording the cloud goes first when it is set up, because Apple FM is also the live voice frontend's
   model; otherwise Apple runs even while recording — a `meetingStarting` trigger fires during a meeting.)
2. **Local model through the library.** `.local` resolves `await ModelRoleStore.shared.provider(for: .agent)` and
   uses it when its `id == .appLLM`; otherwise `LLMProviders.make(.appLLM)` (the memory review's precedent,
   `MemoryReviewer.swift:1197-1200`). Never a bare `LlamaLLMProvider()`. `.appleFoundation` →
   `ProviderMemoryReviewModel(provider: LLMProviders.make(.appleFoundation), maxTokens: …)`. The task's `backend`
   label becomes `"local" | "apple" | "openrouter"`.
3. **Output budget.** `Budget.maxOutputTokens: Int?` (optional, so every stored schedule still decodes — the
   synthesized decoder uses `decodeIfPresent` for optionals). `AgentSchedule.effectiveMaxOutputTokens`:
   `budget.maxOutputTokens ?? (title == DigestTemplate.title ? 1_536 : title == PodcastTemplate.title ? 4_096 : 384)`.
   `ScheduleToolExecutor` `case "create"` (`Agent/Schedules/ScheduleTools.swift:143-213`) sets
   `schedule.budget.maxOutputTokens` from the same rule when it builds the schedule. The live environment clamps
   to the provider: `min(effective, max(384, provider.contextTokens / 3))` — Apple FM 4,096 → 1,365 (so the
   podcast on Apple is shorter than its template wants; see Risks), OpenRouter 32K → full value.
4. **Quiet hours.** A **routine** (`kind == .routine`) whose own slot is inside quiet hours is delivered when it
   runs, like a reminder; a routine whose slot is outside quiet hours but whose result arrives inside them (a
   late run, a retry) is still held; **trigger** results (`kind == .trigger`, no slot) are always held, as today.
   Update the class doc (`:143-150`) to say so.

**Steps:**
1. `ScheduledRunner.swift`: add the enum case; extend `route` per Target 1 (keep it pure). In `run` (`:250-257`)
   pass `appleAvailable: await environment.isAppleFoundationAvailable()` and the budget:
   `environment.model(for: route, maxOutputTokens: schedule.effectiveMaxOutputTokens)`. Fix the `skipped` reason
   and the `backend` label for the new case.
2. `ScheduledRunEnvironment`: add `func isAppleFoundationAvailable() async -> Bool` and
   `func model(for route: RoutineModelRoute, maxOutputTokens: Int) async -> (any MemoryReviewModel)?`, with a
   protocol extension giving `isAppleFoundationAvailable() = false` and forwarding
   `model(for:maxOutputTokens:)` to the old `model(for:)`, so the three self-test fakes compile unchanged.
   `LiveScheduledRunEnvironment` implements both (Apple availability through its existing `review:
   LiveMemoryReviewEnvironment`, `:516`; models per Target 2–3). Delete `maxTokens: 384` at `:531` and `:535`.
3. `AgentSchedule.swift`: `var maxOutputTokens: Int? = nil` in `Budget` (update `standard` and the memberwise
   init call sites; grep `Budget(`), and `var effectiveMaxOutputTokens: Int` on `AgentSchedule`.
4. `ScheduleTools.swift` `create`: after building `schedule`, `schedule.budget.maxOutputTokens = schedule.effectiveMaxOutputTokens`.
5. `AgentScheduler.deliverRoutineResult` (`:648-669`): hold only when
   `!ignoreQuiet && settings.isQuiet(now, zone: zone) && !(schedule.kind == .routine && slot.map { settings.isQuiet($0, zone: zone) } == true)`.
6. Self-tests (below), then the docs: `ScheduledRunner`'s header comment (`:9-11`, "`auto` probes the on-device
   model first … then OpenRouter") and the two template doc comments' "Known tension" paragraphs (token half
   resolved here; the sentence half by P4-06).

**Do not:**
- Do not let a routine load or hold the llama model while recording (the existing `localRunnable` rule stays).
- Do not route through `MemoryReviewRouter` itself or change its rows; routines may load the model on their
  slot, the review may not.
- Do not add a non-optional field to `Budget` or `AgentSchedule` (every `agent-schedules.json` would fail to
  decode). Do not change `Budget.standard`'s 180 s / 8 calls (H3 #33: those help).
- Do not deliver trigger results inside quiet hours, and do not touch the reminder rule.
- Do not give routines `schedule.*` or memory-write tools (`RoutineToolCeiling`, unchanged).
- Self-tests use the isolated `ScheduleStore.shared` and fakes; never the user's schedules, tasks or audit log.
- UI strings: the skip reasons are shown in run history ("Skipped — …"); keep them in plain words (no `route`,
  `appleFoundation`, `FM`); `--selftest-ui-strings` must stay OK.

**Red-first self-test:**
- Extend `--selftest-routine-authority` (`Agent/Schedules/RoutineAuthoritySelfTest.swift:76-95`, where the router
  rows already live; final marker stays `ROUTINE_AUTHORITY_OK` / `ROUTINE_AUTHORITY_FAILED`). Replace the
  positional function reference with a closure that passes `appleAvailable:`. New rows:
  `auto, no local, no cloud, Apple` → `.appleFoundation`; `auto, local busy, cloud, Apple` → `.appleFoundation`;
  `auto, recording, cloud, Apple` → `.cloud`; `auto, recording, no cloud, Apple` → `.appleFoundation`;
  `local, busy, Apple` → `.appleFoundation`; `local, recording, Apple` → `.appleFoundation`;
  `cloud, not set up, Apple` → `.skip("OpenRouter isn't set up")`. Every existing row keeps its answer with
  `appleAvailable: false`. Red today: the case does not exist (commit the rows against a stub that ignores the
  flag to see them fail).
- Extend `--selftest-schedule` (`Agent/Schedules/ScheduleSelfTest.swift`, final `SCHEDULE_OK` / `SCHEDULE_FAILED`):
  - **Budget decode:** a fixture `agent-schedules.json` row without `maxOutputTokens` decodes; its
    `effectiveMaxOutputTokens` is 384; a schedule titled `DigestTemplate.title` → 1,536, `PodcastTemplate.title`
    → 4,096.
  - **Budget reaches the model:** a fake environment records the `maxOutputTokens` it was asked for; a digest
    test run through `scheduler.testRun` asks for 1,536 (red today: the seam does not exist; the live code
    hard-codes 384).
  - **Quiet hours:** in the existing quiet block (`:404-425`, quiet 21:00–08:00), a daily **routine** at 07:00
    with a fake runner answering "Digest." delivers at 07:00 (red today: held until 08:00); a routine at 20:00
    found late at 21:30 is still held; a trigger result at 22:00 is still held.
- Regressions: `--selftest-digest`, `--selftest-podcast` (their fakes must compile through the protocol
  defaults and still pass).

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-routine-authority
Scripts/run-selftest.sh --selftest-schedule
Scripts/run-selftest.sh --selftest-digest
Scripts/run-selftest.sh --selftest-podcast
Scripts/run-selftest.sh --selftest-ui-strings
make acceptance TIER=core
```

**Success threshold:** `ROUTINE_AUTHORITY_OK` with the 7 new rows and every old row unchanged; `SCHEDULE_OK` with
the budget, seam and three quiet-hours cases; `DIGEST_OK`, `PODCAST_OK`; `grep -n "LlamaLLMProvider()"
Sources/NextNotes/Agent/Schedules/ScheduledRunner.swift` prints nothing and `grep -n "maxTokens: 384"` in that file
prints nothing. Owner check (recorded in `STATUS.md`, not a gate): on this Mac, "Run now" on a digest with
OpenRouter unset ends in a delivered or "nothing to report" outcome, not "Skipped".

**Risks & rollback:** Apple FM does not reliably emit the Hermes `<tool_call>` text a routine plans with (the memory
review measured 0 saves through the parser on Apple and moved to guided generation,
`MemoryReviewAppleModel.swift`); a routine on Apple may then answer without reading anything. Notice: run
history shows "Ran" with 0 tool calls, or P0-20's `agent.routine` usage rows show `calls: 0`. Mitigation: P1-05
gives Apple FM native tool calling; until then the route is still better than a skip, and the owner check above
shows it. Apple's 4,096 window clamps the podcast to ~1,365 tokens — shorter than its 4–8 minute script target
(estimate); the podcast's own result transform still renders what it gets. Rollback: `appleAvailable: false` in
`run` restores today's routing; a nil `maxOutputTokens` with the template rule removed restores 384.

**Done when:**
- [ ] `.appleFoundation` route with the table in Target 1; rows pinned in `--selftest-routine-authority`
- [ ] local provider through the Agent role / `LLMProviders.make(.appLLM)`; no bare `LlamaLLMProvider()`
- [ ] `Budget.maxOutputTokens` (optional) with template defaults and provider clamp; 384 literal gone
- [ ] a routine's own-slot result inside quiet hours is delivered; trigger results still held
- [ ] `ROUTINE_AUTHORITY_OK`, `SCHEDULE_OK`, `DIGEST_OK`, `PODCAST_OK`

---

### P4-13 — Consent-shaped defaults for proactive meeting features

**Finding(s):** H3 #12, #13, #14, #15 (H-audit 2026-09-23)  **Effort:** 2 days  **Depends on:** P1-16 (approval cards stay visible until answered — the first-use consent card and the follow-up cards this task makes more frequent must not vanish after 8 s), P4-10 (the post-meeting review must fit Apple Intelligence before more meetings are sent to it), P4-04 (`--selftest-proactive` and the heads-up card exist)  **Unblocks:** — (soft: P4-06, whose digest reads mail only after the attended first-use consent)

**Why (what the user experiences today):** A fresh user who connects Google gets none of the proactive meeting
features, although each still asks before doing anything. Meeting follow-ups stay off until the user finds a
switch in Workspace settings (`agentEnabled` defaults to `false`; onboarding never sets it, H3 #13). The fast
"noticing" engine (Needle, p50 ≈ 60 ms per turn, resident, measured 2026-09-23) is inert in meetings unless the
separate live-LLM switch is on, which is off by default because the LLM pass "spends model time during the call"
— true of the LLM, not of Needle (H3 #14). Meetings that ended before sign-in are never reviewed (the 09-10 and
09-13 meetings on this Mac predate the first mail read, H3 #15). And a morning digest created by the user reads
no mail, every morning, for good: the first-read consent gate refuses every unattended read, and nothing ever
offers the consent (`first-ingestion.json` does not exist on this Mac; the last `search_email` in the audit is
2026-09-15, H3 #12).

**Files you will change:**
- `Agent/Permissions/FirstIngestionGate.swift` — attended scheduled run; account key by email when known
- `Agent/Tools/AgentToolExecutor.swift` — the gate's scheduled branch
- `Agent/Schedules/AgentScheduler.swift` — `testRun` binds "attended"
- `Agent/GoogleWorkspaceCLI.swift` — optional account email from `gws auth status`
- `Agent/AgentService.swift` — first sign-in enablement; backfill review; `review(_:force:announce:)`
- `Support/Settings.swift` — one-time marker key
- `Meetings/MeetingModels.swift` — `Meeting.agentReviewedAt` (+ `decodeIfPresent`)
- `Agent/FunctionCalling/FunctionCallStore.swift`, `Agent/FunctionCalling/FunctionCallWatcher.swift` — meeting
  noticing decoupled from `agentLiveDuringMeeting`
- `UI/Settings/FastListeningSection.swift` — toggle label and footer
- `UI/Island/IslandState.swift` — the one-time notice (through P4-04's `showHeadsUp` or `showAgentReply`)
- `Agent/Proactive/ProactiveSelfTest.swift` — cases

**Read for context (do not change):** `Agent/Schedules/ScheduleTools.swift:143-240` (`schedule.create`: saves, then
`scheduler.testRun` at `:223`, visibly, before confirming); `Agent/ActionRuntime.swift:20-66` (`ActionAuthority`,
`isScheduled`); `Agent/AgentService.swift:472` (`record(_:for:announce:replacing:)`); AGENTS.md "The agent
searches your mail without asking, and can't send anything without asking" and "Adding a property to `Meeting`".

**Current behaviour** (verified 2026-09-24):
- `AgentToolExecutor` Workspace branch (`Agent/Tools/AgentToolExecutor.swift:325-330`):
  ```swift
  if tool.risk <= .read, !SelfTest.isRunning,
     let account = await FirstIngestionGate.unreviewedWorkspaceAccount() {
      if authority?.isScheduled == true {
          return WorkspaceToolResult(summary: FirstIngestionGate.noConsentPathLine(toolID: tool.id))
      }
  ```
  `FirstIngestionGate.unreviewedWorkspaceAccount()` (`Agent/Permissions/FirstIngestionGate.swift:83-88`) keys the
  account as `"google-workspace:\(method)"` — the credential storage method, not an address.
  `AgentScheduler.testRun(id:now:)` (`Agent/Schedules/AgentScheduler.swift:1155-1164`) runs the routine with
  `forced: .ranNow` under the same `.scheduled(id)` authority, so the creation test run is refused too although
  the user is watching it.
- `GoogleWorkspaceCLI.authState()` (`Agent/GoogleWorkspaceCLI.swift:212-227`) decodes only `auth_method` and the
  credential flags (`AuthStatus`, `:240-262`); no account address is read.
- `Settings.agentEnabled` defaults to false (`Support/Settings.swift:1060`: `defaults.object(forKey: Keys.agentEnabled) as? Bool ?? false`);
  `AgentService.isReady = Settings.shared.agentEnabled && authState.isSignedIn` (`Agent/AgentService.swift:143`);
  `authState` is set by the probe (`:138`) and nothing reacts to its first `.signedIn`.
- `AgentService.review(_:force:)` (`:197-209`) returns at `guard isReady` and is called only from the notes-ready
  branch (`Meetings/NotesService.swift`); "reviewed" means `isFromReview` proposals or actions exist (`:207-208`),
  so a review that found nothing leaves no mark.
- `FunctionCallStore.noticesMeetings` (`Agent/FunctionCalling/FunctionCallStore.swift:200-202`) returns
  `noticesMeetingsOverrideForTesting ?? Settings.shared.agentLiveDuringMeeting`; `setNoticesMeetings` (`:210-214`)
  writes `Settings.agentLiveDuringMeeting`. `Settings.agentLiveDuringMeeting` defaults to false (`Settings.swift:1062`).
  The watcher returns early without it (`FunctionCallWatcher.ingest`, `:291-292`; `warmEngine`, `:486`). The toggle's
  title is `FunctionCallStore.Status.meetingToggleTitle = "Notice things during a meeting too"` (`:158`), shown in
  `FastListeningSection` (`UI/Settings/FastListeningSection.swift:29-32`). The LLM live pass reads the same bit
  (`AgentService.handleLiveDelta`, `Agent/AgentService.swift:569`), and Workspace settings show it as
  "Listen for requests during a meeting" (`UI/Settings/WorkspaceSettingsTab.swift:140`).

**Target behaviour:**
1. **First-use consent during the attended test run (H3 #12).** A scheduled read inside
   `AgentScheduler.testRun` is *attended*: the first-use gate runs its normal look → card → ask path
   (`PermissionGate.shared.ask(FirstIngestionGate.consentRequest(…))`) instead of refusing. An unattended slot
   still gets `noConsentPathLine`. After a yes, later unattended runs read normally (the account is reviewed).
2. **Account key.** When `gws auth status` exposes an address (check the real output on this Mac, read-only:
   `gws auth status`; look for a field such as `user`, `email` or `account`), the key is
   `"google-workspace:<address>"`; otherwise `"google-workspace:<method>"` as today. An account already reviewed
   under the method key counts as reviewed (no second card for this Mac's existing state).
3. **Follow-ups on at first sign-in (H3 #13).** The first time Workspace auth becomes `.signedIn` while the
   `agentEnabled` key is **absent** from defaults (never set by the user) and the one-time marker
   `agentEnabledOffered` is false, set `agentEnabled = true`, set the marker, and show one island notice:
   "I'll suggest follow-ups after meetings — you approve each one." An explicit off (key present, false) stays off;
   the marker makes it happen once per Mac.
4. **Noticing in meetings without the live-LLM switch (H3 #14).** `FunctionCallStore` keeps its own
   `noticesMeetings` bit in `function-calling.json` (optional in `Snapshot`, so old files decode). When absent it
   is seeded once: from `Settings.agentLiveDuringMeeting` if that key is present in defaults (an explicit user
   choice), else `true`. In a meeting the watcher proposes with Needle when it is installed; it uses the local-model
   fallback **only** when `Settings.agentLiveDuringMeeting` is on (model time during the call is what that switch
   consents to); otherwise it stays quiet in meetings. The toggle is relabelled
   "Notice requests during meetings" (one switch, relabelled, not a new one). The LLM live pass
   (`handleLiveDelta`) stays behind `agentLiveDuringMeeting`.
5. **Backfill meetings from before sign-in (H3 #15).** On the first transition of `isReady` from false to true in
   a process, review the meetings whose `start` is within the last 7 days, newest first, that have a transcript
   and are not yet reviewed — "reviewed" now also means `Meeting.agentReviewedAt != nil`, a field set whenever a
   review pass completes (proposals or none). At most 3 cards are announced across the whole backfill; later
   proposals are filed on their meetings without a card.
6. **Strings** (no developer words): the notice above; toggle "Notice requests during meetings"; the Fast listening
   footer's meeting sentence adjusted to say it works in meetings with the fast download, and with the notes
   model only when "Listen for requests during a meeting" is on.

**Steps:**
1. `FirstIngestionGate`: add `enum ScheduledRunAttendance { @TaskLocal static var attended = false }` (or a
   `@TaskLocal static var attendedScheduledRun` on the gate). In `AgentScheduler.testRun` wrap the
   `runRoutine` call: `await ScheduledRunAttendance.$attended.withValue(true) { await runRoutine(…) }` — inside the
   `serialized` body, so no unrelated pass inherits it. In `AgentToolExecutor` (`:327`) change the scheduled branch
   to `if authority?.isScheduled == true, !ScheduledRunAttendance.attended { return … noConsentPathLine … }`.
   Factor the decision into a pure `FirstIngestionGate.decision(isScheduled: Bool, attended: Bool, unreviewed: Bool) -> Decision { .proceed, .refuseNoConsentPath, .askFirst }`
   so it is testable without the `SelfTest.isRunning` skip.
2. `GoogleWorkspaceCLI`: add optional `accountAddress: String?` to `AuthStatus` (`decodeIfPresent`, CodingKey
   whatever field `gws auth status` prints — verify on this Mac first; if there is none, skip this step and write
   that in `STATUS.md`) and `func accountAddress() async -> String?`. `unreviewedWorkspaceAccount()` builds the
   address key when available and treats the account as reviewed if either key is in the records.
3. `Settings`: key `agentEnabledOffered` (Bool, default false), plus
   `var agentEnabledIsExplicit: Bool { defaults.object(forKey: Keys.agentEnabled) != nil }`. Pure
   `enum AgentEnablement { static func onSignIn(explicit: Bool, offered: Bool) -> Bool }` (true = enable and notify).
   `AgentService.probe` (after `authState = state`, `:138`): when the previous state was not signed in and the new
   one is, apply it; the notice goes through `IslandState.shared.showHeadsUp` (P4-04) or `showAgentReply`.
4. `Meeting.agentReviewedAt: Date?` beside `agentActions` (`Meetings/MeetingModels.swift:236`), memberwise-init
   default nil, `decodeIfPresent` in the hand-written `init(from:)` (`:316-337`). `AgentService.review` sets it
   (via `MeetingStore.save`) when a pass completes without error; the `reviewed` check (`:207-208`) adds
   `|| meeting.agentReviewedAt != nil`.
5. `AgentService.review(_:force:announce: Bool = true)` passes `announce` to `record` (`:472`).
   `func backfillReviews(now: Date = Date())`: select per Target 5, review sequentially (await each task before the
   next), `announce: remaining > 0` where `remaining` starts at 3 and drops by the number of proposals announced.
   Trigger it from an `isReady` false→true observation in the probe and in `agentEnabled`'s change path; guard
   with a per-process flag.
6. `FunctionCallStore`: `Snapshot.noticesMeetings: Bool?`; seed per Target 4 on load; `noticesMeetings` returns
   `noticesMeetingsOverrideForTesting ?? storedNoticesMeetings`; `setNoticesMeetings` writes the store's own bit
   and persists (no longer `Settings.agentLiveDuringMeeting`). Add
   `func meetingProposer() async -> (any FunctionCallProposer)?`: Needle when downloaded and supported; else the
   local fallback only when `Settings.shared.agentLiveDuringMeeting`; else nil. `FunctionCallWatcher` uses it on the
   meeting path; `warmEngine` warms only Needle. `Status.meetingToggleTitle = "Notice requests during meetings"`;
   `refreshStatus` reports `noticesMeetings` from the new bit.
7. `FastListeningSection`: footer sentence per Target 6; no layout literals (`DS` tokens only).
8. Self-test cases (below); grep for callers of `backfillReviews`, `AgentEnablement.onSignIn`,
   `ScheduledRunAttendance` before ticking.

**Do not:**
- Do not let an **unattended** routine read an unreviewed account; only `testRun` is attended.
- Do not turn `agentEnabled` on when the user ever set it (key present), and never twice (marker).
- Do not let the meeting watcher spend the notes model during a call unless `agentLiveDuringMeeting` is on; do not
  change the watcher's card caps (1 outstanding, 3 per 10 min, 20 s cooldown, 12-character floor — H3 #26–28 say
  they help), its write-only families or its confidence floors.
- Do not auto-run any write: backfilled proposals are cards/rows the user approves (`AgentRisk`, `PermissionGate`).
- Do not add a `Meeting` field without `decodeIfPresent` in the hand-written `init(from:)`.
- A self-test never writes the user's settings, `function-calling.json`, `first-ingestion.json` or meetings: use
  throwaway `UserDefaults(suiteName:)`, `FunctionCallStore(directory:)` with a temp directory, and pure functions.
- UI strings: no `Needle`, `gws`, `ingestion`, tool ids or schema keys on screen (`--selftest-ui-strings`).
- `MainActor.assumeIsolated` is forbidden.

**Red-first self-test:** extend `--selftest-proactive` (`Agent/Proactive/ProactiveSelfTest.swift`, final
`PROACTIVE_OK` / `PROACTIVE_FAILED`, failures as `PROACTIVE_WRONG: <case>: <reason>`):
- Case Q (attended consent): `FirstIngestionGate.decision(isScheduled: true, attended: true, unreviewed: true) == .askFirst`;
  `(true, false, true) == .refuseNoConsentPath`; `(false, false, true) == .askFirst`; `(true, false, false) == .proceed`;
  and inside `ScheduledRunAttendance.$attended.withValue(true)` the flag reads true in a child `Task`, false outside.
  Red today: a scheduled read always refuses.
- Case R (enablement): `AgentEnablement.onSignIn(explicit: false, offered: false) == true`;
  `(explicit: true, offered: false) == false`; `(explicit: false, offered: true) == false`; against a throwaway
  defaults suite, applying it twice sets `agentEnabled` once and the marker once.
- Case S (noticing decoupled): a `FunctionCallStore(directory: <temp>)` with no file → `noticesMeetings == true`
  while the throwaway defaults have no `agentLiveDuringMeeting` key; a snapshot file `{"isEnabled":true,"wantsFastEngine":false}`
  (old shape) decodes; with Needle absent and `agentLiveDuringMeeting` off, `meetingProposer()` is nil (use a seam
  for `NeedleModels.isDownloaded`); with Needle present → non-nil. Red today: `noticesMeetings` reads the
  live-LLM switch.
- Case T (backfill): a temp `MeetingStore` with 5 transcribed meetings (days −1, −2, −3, −8 and one already with
  `agentReviewedAt`) and a fake proposer returning 2 proposals each → exactly the 3 eligible meetings reviewed,
  newest first, 3 cards announced in total (2 + 1), all 6 proposals filed; a second call reviews nothing.
- Case U (reviewed mark): a review that returns 0 proposals sets `agentReviewedAt`; `Meeting` decodes from a
  `meeting.json` without the key.

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-proactive
Scripts/run-selftest.sh --selftest-function-calls
Scripts/run-selftest.sh --selftest-routine-authority
Scripts/run-selftest.sh --selftest-gws
Scripts/run-selftest.sh --selftest-guided
Scripts/run-selftest.sh --selftest-ui-strings
make acceptance TIER=core
```

**Success threshold:** `PROACTIVE_OK` with Cases Q–U; `FUNCTION_CALLS_OK` (or its documented `_ABSENT` line when the
Needle files are not given) with no change in its graded calls; `ROUTINE_AUTHORITY_OK`; `UI_STRINGS_OK`. Owner check
(recorded, not a gate): creating a morning digest on this Mac shows the first-use card during the test run, and the
next morning's run reads mail.

**Risks & rollback:** turning follow-ups on by default raises more cards after meetings → every one still needs a
click, P1-16 keeps them visible, and the notice says how it works; turning it off is the existing switch.
Backfill on a Mac with many old meetings costs model time once → capped at 7 days and 3 cards, sequential.
Rollback: `AgentEnablement.onSignIn` returning false; `noticesMeetings` seeded false; the attended flag never bound.

**Done when:**
- [ ] attended test run shows the first-use card; unattended runs still refuse; account keyed by address when available
- [ ] follow-ups enabled once at first sign-in with one notice; explicit off stays off
- [ ] meeting noticing has its own bit, relabelled toggle, no notes-model use without the live switch
- [ ] 7-day backfill with ≤ 3 cards; `agentReviewedAt` with `decodeIfPresent`
- [ ] `PROACTIVE_OK` with Q–U; `UI_STRINGS_OK`

### 2026-10-02 bounded P4-08a advertised-window producer evidence

Original94 ASK RED2 → fixed95 same15 checks and11 focused flags PASS.
Actual temporary SQLite→Asker→sameprovider→stream/citation flow captures4096
estimated total4974→3057,32768 preserves20,512 refuses before model stream.
Existing protocol forwards exact advertised context synchronously; no shared
runtime probe/new await/store/pass. Required quick is FAILED4/10 on localGemma;
CORE21/22 with unchanged wake17/24 and3/32, tool-awareness/answers PASS.
Only the bounded fitting contract is done; floor3/metadata fitting, actual loaded
runtime capacity, typed routing, memory and Assembler remain open. No parent
checkbox/phase/model/default is promoted. [Actual proof](../../../Tests/Reports/agent-overhaul-closure/next-implementation-review/p4-08-knowledge-fitting/verification.md).

### 2026-10-02 bounded P4-08b feasible-floor and actual metadata admission

Original97 RED6 → identical98 PASS20 +prior15, repeated99. Complete immutable prompt envelope prefers3 when feasible (1900:3/cost1712), retains fewer when not (1500:1/cost1329), trims actual long-title passage tails before emission/stream (4096:6/cost3916). Retrieved events/source rows/model prompt/returned citations agree. No extra retrieval/model round/store/await; per-loop metadata resolution and characters-per-token estimate remain explicit.

Final31 related checks pass on recheck; initial worker owner-metrics signature anomaly remains open/unattributed. Required quick99 FAILED3/10 (C04 next planner-pass timeout), core21/22 known wake only, tool-awareness/answers pass. Affected C04 route does not call changed fitting/audio producers; runtime cause still open. Loaded capacity/longquery/files-only/repeatedtrim/typed/memory/Assembler/fullowner/physical gates and parent P4-08 remain open. See [actual boundary proof](../../../Tests/Reports/agent-overhaul-closure/next-implementation-review/p4-08-knowledge-fitting/boundary-preparation/boundary-verification.md).


### 2026-10-03 bounded P4-08 typed route producer evidence

Actual staged161 fails18 missing-feature assertions; staged162 passes the same59
checks after the fixture observes actual downstream partial publication. Only the
two RealtimeAgent producer files differ across1062 compiler inputs. Existing
KnowledgeAsker/provider/graph scope feed actual stream, saved citation descriptors
and conversation codec; planner fallback, action/source/permission gates and
12,000-character caps remain enforced. The intermediate markup failures and their
confirmed parser/scrub order cause are retained. Seven related flags pass, including
production tool loop, voice duplex and owner isolation21files32defaults. Quick162
repeat times out before scoring at unchanged300s; model-stall attribution is open.
Prior1563/10 remains latest scored failure; no aggregate or full parent promotion. Memory budgets, Assembler, loaded
capacity and native source interaction remain open. [Actual proof](../../../Tests/Reports/agent-overhaul-closure/typed-knowledge-production/verification.md).


### 2026-10-03 bounded P4-08 memory and page budget evidence

Actual163 fails15Persona+2Assembler feature assertions; fixed164 passes the same51
checks with eight producer files across1062 inputs. The cache and prompt assembler
share the reader-scaled allowance; floors/zero routes/store budgets stay unchanged.
Actual page writing captures4096→1024 and32768→1500 output tokens. Nine latest
related flags pass, including typed59 and isolation21files32defaults. Initial
production-loop three-read deadline failure is retained; original/recheck pass
without Sources/deadline changes, so timing attribution stays open. Scheduled
forwarding and actual provider-owned loaded-window fitting require separate proof;
full parent/native/quality/latency gates remain open. [Actual reader proof](../../../Tests/Reports/agent-overhaul-closure/reader-budget-production/verification.md).


2026-10-03 bounded P4-11 progress: actual staged167 fails33/71 reader/harvest assertions; identical168 passes71 and the whole memory-review flag, retaining explicit70. Relevant saved-fact selection and short dictation harvesting reach the guarded writer; scripted echo80/90→1/11 is not real-model quality. Memory/portability/Persona/UI strings/isolation pass. Settings167/168 and pre-COMMON164 print success then exit-11, retained as failed. Remaining63 and provider capacity28 are prepared for serial verification; parent gates remain open. [Evidence](../../../Tests/Reports/agent-overhaul-closure/memory-review-production/reader-harvest/verification.md).


2026-10-03 bounded P4-11 decisions/totals: original169 RED28/63→fixed170 PASS63, same actual reviewer/guarded writer/state-reader inputs. Prior reader71 and explicit70 remain green; memory/portability/UI strings/isolation21files32defaults also pass. Narrow environment/request skips retain durable wording; only the exact untargeted-update refusal permits one existing guarded remember write. Lifetime counts survive the recent200-row trim in the same state file, seeding retained legacy rows once. Existing MemoriesEditor receives canonical status text; native appearance remains unverified. Both COMMON compile corrections are retained and precede the pair. Settings crash, actual loaded capacity/real-model quality/fullCORE/owner/latency and parent completion remain open. [Proof](../../../Tests/Reports/agent-overhaul-closure/memory-review-production/remaining/verification.md).


2026-10-03 bounded provider capacity: actual171 RED4→172 ASK PASS31 and actual173 RED7/28→174 memory-review PASS28. The answering wrapper/fitter and memory reviewer use the same captured provider-window scalar as system assembly; exact cold Llama runtime binding replaces global generic-ID lookup. Prior typed59 and memory63/71/70 remain green. Genuinely loaded factory/residency/native interaction and quality/full/CORE/owner/latency gates remain open. [Reader evidence](../../../Tests/Reports/agent-overhaul-closure/provider-reader-capacity-production/verification.md), [memory evidence](../../../Tests/Reports/agent-overhaul-closure/memory-provider-capacity-production/verification.md).

## Bounded implementation update — 2026-10-03 (211/212)

P4-02 previous completed exchange20 and P4-08 scheduled advertised-reader8 pass their actual original/fixed producer comparisons and eight related flags. This closes those bounded implementation gaps only: classifier accuracy/deflection re-route, real loaded capacity, latency and parent acceptance remain open. [Exact evidence](../../../Tests/Reports/agent-overhaul-closure/route-context-and-scheduled-reader-production/verification.md). The separate ACP activity scheduling failure remains unaccepted.
