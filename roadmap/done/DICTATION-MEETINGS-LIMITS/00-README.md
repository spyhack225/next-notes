# DICTATION-MEETINGS-LIMITS: start here

> **Historical model assumptions — revised 2026-09-30:** this completed plan/audit
> preserves its dated measurements and implementation history. For new work, follow
> the [independent-role/shared-file contract](../../in-progress/SHARED-BRAIN/00-README.md): Meetings, Agent and cleanup
> may use different appropriate models; exact verified artifacts are reused, with
> workload-specific consent and request ownership. Agent-only file selection,
> universal model defaults and deletion based only on the Agent are superseded.
> MiniCPM cleanup + Apple guard/fallback is concurrent work, not evidence that this
> historical build used it. Re-measure quality/latency on the actual current engine.

This folder is an implementation roadmap for the two oldest parts of the macOS app: push-to-talk
**dictation** and **meetings** (recording → transcript → speakers → notes). It is executed task by
task by a coding agent that has **no access to the conversation that produced it**. Everything you
need is in these files, the repo, and the two audits linked below.

It is a **second roadmap**, separate from AGENT-OVERHAUL, and it is executed by the same agent.
Read this file completely, then `AGENTS.md` at the repo root, then
`roadmap/in-progress/AGENT-OVERHAUL/00-README.md` §5 (per-task workflow), §6 (phase gates), §8
(when stuck) and §9 (rules you must never break). This file restates the key rules briefly
(section 8) and refers to that file for the long form.

---

## 1. Why

Two read-only audits of 2026-09-23 measured every cap, gate and deadline in these two pipelines
against this Mac's own history:

| Audit | Subject | Evidence |
|---|---|---|
| [`I1-caps-dictation.md`](../agent-analysis-2026-09-23/I1-caps-dictation.md) | push-to-talk, the tail deadlines, ASR, the cleanup router, learning, injection, history | 226 runs in `runs.jsonl` (51 with a cleanup record), 19 metric holds in `metrics.jsonl`, the unified error log, `dictionary.txt` |
| [`I2-caps-meetings.md`](../agent-analysis-2026-09-23/I2-caps-meetings.md) | call detection, two-track capture, windows, diarization, notes, recovery, audio retention, calendar | the six meetings on disk (09-09 → 09-19), `defaults`, the FluidAudio checkout, the macOS SDK |

The decision document for the wider project is
[`roadmap/done/agent-analysis-2026-09-23/AGENT-QUALITY-ANALYSIS-2026-09-23.md`](../agent-analysis-2026-09-23/AGENT-QUALITY-ANALYSIS-2026-09-23.md).
It covers the Agent, not these pipelines; where a dictation or meeting item overlaps an
AGENT-OVERHAUL task, section 5 says which task owns what.

**The headline numbers** (all measured on this Mac; the source is named):

Dictation (I1):
- **The wait after release is the cleanup model, not speech recognition.** Over 15 metric holds,
  key-up → ASR final has a median of **0.38 s**; ASR final → cleanup done has a median of
  **5.19 s** (max 11.5 s); injection is 0.15 s.
- **18 % of cleanup model runs time out** (9 of 50). Timed-out and rejected answers took
  **81.8 s of the 242.6 s** spent in cleanup (34 %): each was waited out in full, then thrown away.
- The Apple cleanup timeout floor is **4.0 s**, below the **4.69 s** cold first call measured in
  the same file (`FoundationModelFormatter.swift`, `CleanupSessionWarmer` doc table).
- The layout pass was asked 6 times; **5 answers were not used**, 4 of them cut at its 3.5 s
  deadline while the user kept waiting for cleanup anyway.
- **Holds are lost without a trace.** On 09-23: a 4.40 s key-down → capture after a 52 s model
  load under memory pressure filed nothing; a 1.5 s hold filed nothing; a 0.18 s tap showed the
  raw string `Invalid audio data provided. Must be at least 300ms of 16kHz audio.` on the island.
  `runs.jsonl` files only successes, so none of these is countable today.
- The learner wrote `of a product -> for ProductFlo` into `dictionary.txt` (a rule for every app),
  and 5 duplicate rules.

Meetings (I2):
- **French meetings after the 09-13 window change read 16–24 % English-looking garbage.**
  Meeting finals come from 2–5 s ASR windows (commit `a276c5a`); before it, 6 % (25 s windows).
  The garbage reached the live context ("Parking lot") and the notes.
- **The browser consent gate never fires.** Core Audio reports `com.google.Chrome.helper`, not
  `com.google.Chrome`, so "Always record" is offered for a browser and, with auto-record on, a
  browser call records without asking — the one thing AGENTS.md says cannot happen.
- **3 of 6 meetings were over-split** by the diarizer (no speaker-count hint); the user merged
  clusters by hand, after notes had already named "Speaker 1".
- **29–50 % of far-end lines are left unattributed** ("Others") because short finals fall between
  the diarizer's runs.
- **The "Record this call?" card vanishes after 8 s** for a detected call, and with the default
  `callDetectionAutoRecord = false` that question is the only way an ad-hoc call gets recorded.
- **Interrupted meetings are never resumed.** Quit → `done` without notes; crash while recording →
  `failed` with an intact transcript; crash while diarizing/summarising → `done` and the
  temporary audio deleted.
- Map-reduce notes silently drop the **oldest** facts when they overflow; on Apple FM (which
  AGENT-OVERHAUL P0-01 made the meeting-notes model on this Mac) that starts at roughly 35–55
  minutes of meeting (arithmetic, I2 #5).

---

## 2. File map

| File | What it holds | Author status |
|---|---|---|
| `00-README.md` | This file: why, IDs, dependencies, order, workflow, gates, kept limits, flags | written |
| `STATUS.md` | The ledger. Update it after every task | written |
| `01-DICTATION.md` | D-01…D-16 (+ lettered subtasks), the dictation targets, the baseline stats script | written |
| `02-MEETINGS.md` | M-01…M-15, M-16a/b/c, the meeting targets, fixtures and flags | written by another author in parallel (authoritative for every M task) |

Inside a task file, each task's **Depends on** line is authoritative. The graph in section 4 is a
summary; for M tasks, `02-MEETINGS.md` wins wherever it disagrees with this file. Record any
disagreement in `STATUS.md` → *Decisions and deviations*.

The `roadmap/` folder is **git-ignored**. Never commit anything under it, never force it. Never
write plans into `docs/` (the published website). Test reports go in `Tests/Reports/` (tracked).
When you start executing, move this folder to `roadmap/done/DICTATION-MEETINGS-LIMITS/`
(and to `roadmap/done/` when every row is `done` or `blocked` with a note). Paths inside the files
are written relative to the repo root, so they survive the move.

---

## 3. Task IDs

IDs are fixed. Never renumber. You may split a task into lettered subtasks (`D-05a`); give each
its own row in `STATUS.md` and its own commit.

### Dictation (`01-DICTATION.md`)

| ID | Title | From (I1) |
|---|---|---|
| D-01 | Record the prewarm state before the call, and file every hold's outcome | I1-13, I1-05.3, I1-12, I1-16 |
| D-01a | ↳ `sessionPrewarmed` recorded before `respond`, on every exit including timeout | I1-13 |
| D-01b | ↳ One `dictation.hold` usage row per hold (`inserted`/`empty`/`tap`/`lostAtStartup`/`failed:*`), `dictation.press_refused`, dropped buffers | I1-05.3, I1-12, I1-16 |
| D-02 | Key-down pre-roll: capture from key-down, replay into the engine after start, transcribe instead of failing on a release in `.starting` | I1-04 |
| D-03 | Never lose a hold silently: speech-energy check on empty transcripts, keep the last failed hold's audio, "Try again" | I1-05 |
| D-04 | Parakeet short-audio padding to 300 ms; plain-language errors only | I1-06 |
| D-05 | A press during `.error` starts a new hold | I1-07 |
| D-06 | Warm Apple's model at launch and after wake; gate the S1-mini launch load on the engine that will actually run | I1-01.1, I1-09 |
| D-07 | Warmth-aware Apple cleanup timeout (cold: `min(16, 8.5 + 0.07·w)`) | I1-01.2 |
| D-08 | Chunked Apple cleanup: width chosen by measurement, wave-aware ceilings, staged sessions per group, per-group verdicts | I1-02 |
| D-09 | Anchor the layout-pass deadline to the cleanup pass it runs beside | I1-03 |
| D-10 | Learner safety: per-token alignment, auto-add only single-token or case-only, idempotent add, diff against the last edit, offer to review the bad rule | I1-08 |
| D-11 | Clause-level salvage for long single-sentence answers | I1-10 |
| D-12 | Incremental cleanup of stable sentences during the hold | I1-11 |
| D-13 | Pipelined holds (only if D-01b shows refused presses) | I1-12 |
| D-14 | Per-pass `.realtimeASR` acquisition for dictation (only if D-01b/P0-20b show contention) | I1-15 |
| D-15 | History and clipboard hygiene | I1-17, I1-18, I1-19 note |
| D-15a | ↳ `runs.jsonl`: in-memory append, reload only on edit/delete, opt-in retention | I1-17 |
| D-15b | ↳ Clipboard restore skipped when the user copied something meanwhile (`changeCount`) | I1-18 |
| D-15c | ↳ `--selftest-dictation`'s injected failures stop writing error-level lines into the user's log | I1-19 note |
| D-16 | Spike: vocabulary boosting for Parakeet (FluidAudio), and title-derived context for Terminal | I1-26 note, I1-14 |

### Meetings (`02-MEETINGS.md`)

Titles from I2 §3. `02-MEETINGS.md` may split them into lettered subtasks; add those rows to
`STATUS.md` when you reach them.

| ID | Title | From (I2) |
|---|---|---|
| M-01 | Long-window finals: keep 2–5 s provisionals, cut finals at 20–30 s pauses (or a post-Stop re-transcription pass); fix the AGENTS.md and `MeetingDiarizer` comments | #1 |
| M-02 | Resolve audio helpers to their owning app before `CallPolicy`; migrate `*.helper` answers; add `com.apple.replayd` to the denylist | #2 |
| M-03 | Speaker-count hints plus voice-print cluster merge, and "Re-identify with N speakers" | #3 |
| M-04 | Nearest-run and neighbour fallback in `MeetingDiarizer.assign` | #4 |
| M-05 | Map-reduce never drops facts: per-chunk fact budget plus a collapse pass; log chunk and collapse counts | #5, #15 |
| M-06 | The detected-call question stays as a compact island pill for the life of the call | #6 |
| M-07 | Transcription backlog bounded by audio seconds and merged, never dropped | #7 |
| M-08 | Resume interrupted meetings at their stage; hold temporary audio until done; confirm quit while recording; stall watchdog on diarize and notes | #8, #9 |
| M-09 | Retry the system-audio tap while recording | #10 |
| M-10 | Keep temporary audio 72 h or until speakers are confirmed, with a disk guard | #11, #21 |
| M-11 | Unify calls with calendar meetings: start early, inherit title and attendees, stop on hang-up; speech-aware overrun | #12, #17 |
| M-12 | Window-aware notes budgeting: read Apple's `contextSize` and `tokenCount`, count the system prompt, retry on overflow, derive chunk sizes | #13, #15 |
| M-13 | Truncation is visible: `LLMCompletion.finishedByLimit` for every provider, retry or mark "cut short"; scale the notes cap with length | #14 |
| M-14 | Live reconcile by speech time, with a 3-minute window and its own switch | #16 |
| M-15 | Speaker identification on by default once models exist; offer at the first multi-voice meeting | #18 |
| M-16 | Meeting metrics and transcript writes (split in `02-MEETINGS.md`) | #19, #20 |
| M-16a | ↳ Measure first: transcript-quality probe, meeting stage spans, generated fixtures, read-only `--meeting-quality-report` | #19 (stages), #1/#3/#4 (measurement) |
| M-16b | ↳ Meeting model passes in the unified usage log (through AGENT-OVERHAUL P0-20b) | #19 (model passes) |
| M-16c | ↳ Debounced `transcript.json` writes | #20 |

---

## 4. Dependency graph

A summary. Task **Depends on** lines are authoritative. Solid edges are hard dependencies;
dotted edges are "measure first" or "coordinate" edges (the task can start, but read the note).
`AO:` nodes are AGENT-OVERHAUL tasks in `roadmap/in-progress/AGENT-OVERHAUL/`. State of those on
2026-09-24 (from its `STATUS.md`): **done** P0-01, P0-05, P0-06, P0-09, P0-13, P0-15, P0-19;
**blocked** P0-10; **todo** everything else, including P0-04, P0-11, P0-17 and P0-20. P0-20 is
being widened into P0-20a–e (unified usage log, see section 5); if its phase file does not show
the subtasks yet when you read it, they are still defined by the IDs and names used here.

```mermaid
graph TD
  subgraph AO[AGENT-OVERHAUL]
    AO_P0_01[P0-01 notes role on Apple FM - done]
    AO_P0_06[P0-06 cancellable acquire - done]
    AO_P0_20a[P0-20a usage log writer]
    AO_P0_20b[P0-20b meetings rows]
    AO_P0_20c[P0-20c dictation rows]
    AO_P0_20d[P0-20d --usage-report]
    AO_P0_20e[P0-20e --selftest-usage-log]
    AO_P0_17[P0-17 finish_reason, OpenRouter]
    AO_P0_11[P0-11 store isolation]
    AO_P0_04[P0-04 chat templates]
    AO_P1_10a[P1-10a Apple FM window read at runtime]
    AO_P2_08[P2-08 smaller I/O buffers]
    AO_P3_07a[P3-07a capacity lanes]
    AO_P0_20a --> AO_P0_20b & AO_P0_20c --> AO_P0_20d
    AO_P0_20a --> AO_P0_20e
  end
  subgraph D[Dictation]
    D01a[D-01a prewarm recorded]
    D01b[D-01b hold outcomes]
    D02[D-02 pre-roll]
    D03[D-03 never silent + Try again]
    D04[D-04 short-audio pad]
    D05[D-05 press during error]
    D06[D-06 launch warm / S1 gate]
    D07[D-07 warmth-aware timeout]
    D08[D-08 chunk width + ceilings]
    D09[D-09 layout deadline]
    D10[D-10 learner safety]
    D11[D-11 clause salvage]
    D12[D-12 incremental cleanup]
    D13[D-13 pipelined holds]
    D14[D-14 per-pass ASR lane]
    D15[D-15a/b/c hygiene]
    D16[D-16 spike]
    D01a --> D06 --> D07 --> D08 --> D09
    D07 --> D11
    D01b --> D03
    D02 -.-> D03
    D07 & D08 & D11 & D01b --> D12
    D01b -. evidence .-> D13
    D02 --> D13
    D01b -. evidence .-> D14
  end
  subgraph M[Meetings - see 02-MEETINGS.md, authoritative]
    M16a[M-16a probes, spans, fixtures]
    M01[M-01 long-window finals]
    M02[M-02 helper to owner]
    M03[M-03 speaker hints]
    M04[M-04 assign fallback]
    M05[M-05 no dropped facts]
    M06[M-06 call pill]
    M07[M-07 backlog by seconds]
    M08[M-08 resume + watchdog]
    M09[M-09 tap retry]
    M10[M-10 audio retention]
    M11[M-11 calls + calendar]
    M12[M-12 window-aware notes]
    M13[M-13 truncation visible]
    M14[M-14 reconcile by time]
    M15[M-15 diarize default]
    M16b[M-16b model passes in usage log]
    M16c[M-16c debounced transcript]
    M16a --> M01 & M04 & M05
    M16a -. spans .-> M07 & M08
    M02 -. owner names .-> M06
    M02 & M06 --> M11
    M05 --> M12 --> M13
    M01 --> M08 --> M10
    M01 --> M07
    M04 --> M03
    M10 -. identify again needs audio .-> M03
    M03 & M10 --> M15
    M05 --> M16b
    M08 --> M16c
    M01 -. not hard .-> M14
  end
  AO_P0_20a --> D01b
  AO_P0_20c -. extend its rows .-> D01b
  AO_P0_20a & AO_P0_20b --> M16b
  AO_P0_06 --> D14
  AO_P0_20b -. meeting.transcribe evidence .-> D14
  AO_P3_07a -. coordinate lane semantics .-> D14
  AO_P3_07a -. coordinate .-> M14
  AO_P0_14[P0-14 one provider per turn] --> M14
  AO_P0_17 -. OpenRouter leg .-> M13
  AO_P1_10a --> M12
  AO_P0_01 -. makes the 4K path the default .-> M05 & M12
  D01b -. dictation drop counts feed .-> AO_P2_08
```

---

## 5. How this roadmap interleaves with AGENT-OVERHAUL

**When to start.** This roadmap needs the unified usage log, so it starts **after AGENT-OVERHAUL
P0-20a has landed** (the writer), and preferably after the whole AGENT-OVERHAUL **Phase 0 gate**
is green. Only the tasks that write no usage rows have no dependency on P0-20 at all (dictation: every
task except D-01b and those that depend on it — D-03, D-12, D-13, D-14; meetings: every task except
M-16b — see `02-MEETINGS.md` §1.5). You may run those earlier if the AGENT-OVERHAUL executor is
blocked, but record it in both `STATUS.md` files; their owner-use numbers are then read from
`runs.jsonl` and `metrics.jsonl` only.

**How to interleave.** After Phase 0 of AGENT-OVERHAUL, you may alternate between the two
roadmaps one whole task at a time. Rules:
- Never interleave inside a dependency chain (for example, do not start D-08 while D-07 is `red`).
- A phase gate of either roadmap runs `make acceptance TIER=core`; run it only when neither
  roadmap has a task in `red`.
- Both roadmaps edit the same registry files: `NextNotesApp.runRequestedSelfTest`, the flag list
  in `AGENTS.md`, `Scripts/acceptance.sh`. Edit them in the same commit as the task that needs
  them and re-read them right before editing; never reformat them.

**The unified usage log (AGENT-OVERHAUL P0-20a–e).** Names to use exactly (defined by
AGENT-OVERHAUL; re-read `01-PHASE-0-MAKE-IT-ANSWER.md` P0-20 before you write code, and follow it
wherever it differs from this list):
- file `usage.jsonl` beside `metrics.jsonl`; writer `UsageLog` (`Support/Usage/UsageLog.swift`),
  row `UsageRecord`, per-model-pass recorder `ModelPassRecorder`;
- `UsageLog.shared` is a temp directory under `SelfTest.isRunning`; tests inject
  `UsageLog(directory:)`;
- fields: `feature`, `pass`, `provider`, `modelID`, `ttftMs`, `totalMs`, `errorClass`,
  `finishReason`, `counts: [String: Int]`, `meetingID`, `scheduleID`, and the correlation ids;
- `feature` values relevant here: `dictation.asr`, `dictation.cleanup` (P0-20c);
  `meeting.transcribe`, `meeting.diarize`, `meeting.notes.single`, `meeting.notes.map`,
  `meeting.notes.reduce`, `meeting.proposals`, `meeting.live`, `meeting.needle` (P0-20b);
- P0-20d adds the `--usage-report` diagnostic, P0-20e the `--selftest-usage-log` flag.

This roadmap **adds** rows; it never invents a parallel log. D-01b adds two feature values,
`dictation.hold` and `dictation.press_refused`, through P0-20a's API. On the meetings side, M-16a
records pipeline **stage** spans and counters (dropped windows, collapse counts) in
`metrics.jsonl` and needs no P0-20; M-16b writes the notes and reconcile **model passes** through
P0-20b's writer. If P0-20c already records something
D-01b asks for, D-01b shrinks to the gap and says so in `STATUS.md`.

**Overlaps, and who owns what:**

| This roadmap | AGENT-OVERHAUL | Who owns what |
|---|---|---|
| D-01b hold outcomes | P0-20c dictation rows | P0-20c: one row per model/ASR pass. D-01b: one row per **hold**, whatever happened. Same correlation id. |
| M-16a stage spans, M-16b model passes | P0-20b meeting rows | P0-20b: the meetings usage writer. M-16b: the notes and reconcile model passes through it. M-16a: stage spans and counters P0-20b does not carry (dropped windows, collapsed facts), in `metrics.jsonl`. Never a second model-pass log. |
| D-02 pre-roll | P0-06 (done) cancellable `acquire` | P0-06 made the lane wait cancellable; it does not capture speech. D-02 does. |
| D-14 per-pass lane | P0-06 (done), P3-07a capacity lanes | D-14 uses `ComputeScheduler.acquireCancellable` (P0-06). If P3-07a has landed, re-read the lane model before D-14. |
| D-01b dropped buffers | P2-08 smaller I/O buffers | P2-08's "0 dropped chunks" gate measures the hub; D-01b adds the controller's own stream drops, which P2-08 should also read. Land D-01b first if both are pending. |
| M-12 Apple window | P1-10a step 0 reads `SystemLanguageModel.default.contextSize` | P1-10a **owns** `FoundationModelLLMProvider.contextTokens`. If M-12 is reached first, M-12 implements P1-10a step 0 verbatim, records it in **both** `STATUS.md` files, and P1-10a skips that step (`02-MEETINGS.md` §1.5). |
| M-14 reconcile provider | P0-14 one provider per turn | M-14 moves the reconcile's provider resolution to the role store only after P0-14 lands. |
| D-04 padding helper | — (both roadmaps' ASR paths) | D-04 owns the shared Parakeet minimum-input helper (`Transcription/ParakeetInput.swift`); M-01/M-07 call it and never copy it (`02-MEETINGS.md` §1.6). |
| M-13 `finishedByLimit` | P0-17 `finish_reason` (OpenRouter only) | P0-17 first. M-13 generalises it to every provider and reuses P0-17's field if it is on `LLMCompletion`. |
| M-14 live reconcile switch | P3-07a lanes | Coordinate: the reconcile runs on the Agent's model; read P3-07a's lane rules if it has landed. |
| M-05, M-12 (4K path) | P0-01 (done): meeting notes on Apple FM | P0-01 is why these are urgent, not optional. |
| Self-test isolation | P0-11 store isolation | Until P0-11 lands, every D/M self-test passes seams (`record:`, injected stores). After it lands, add `--selftest-store-isolation` to every regression list. |

**Dictation items that touch the cleanup model, and AGENT-OVERHAUL P0-04 / P0-05:**
- **P0-04 (per-family chat templates, todo)** changes how the in-process llama runtime
  (`NotesModelRuntime`) formats every prompt. The `.appLLM` cleanup engine
  (`AppLLMCleanupFormatter`) and `LLMStructurePlanner` go through that runtime. The production
  cleanup engine on this Mac is **Apple FM** (`cleanupEngine = s1Mini` + grammar on routes to
  Apple, `CleanupRouter.preferredEngine`), so D-06…D-12 are measured on Apple and do not depend
  on P0-04. But `--selftest-cleanup app-llm` output **changes** when P0-04 lands: never compare an
  `app-llm` score from before P0-04 with one from after it, and re-capture that line in this
  roadmap's baseline after P0-04. No D task edits template code; P0-04 owns it.
- **P0-05 (done, `6ad6ade`)** replaced the typed Agent's fixed 112-token cap with
  `AgentAnswerBudget`. That budget is for Agent answers only. The cleanup caps (Apple 1,200, layout
  500, app-LLM `min(1200, max(64, 4·words))`) are a **kept limit** (section 7): do not route them
  through `AgentAnswerBudget`, and do not change them in any D task.
- **P0-18 (prefix reuse, todo)** would make `.appLLM` cleanup cheaper per call; it does not change
  any D task's design.

---

## 6. Recommended order

Measure first, so every later claim is a before/after number rather than a hunch. Then fix what
loses words or consent. Then latency and quality. Deep changes last.

| Phase | Tasks, in order | Why this order |
|---|---|---|
| **A — measure** | D-01a → D-01b → M-16a | Everything later is judged by these rows. D-01a is a one-line trace fix and has no dependency; D-01b needs P0-20a (and P0-20c if landed); M-16a needs nothing and records the six real meetings' baseline. |
| **B — nothing lost, consent holds** | D-04 → D-05 → D-10 → D-02 → D-03; M-02 → M-06 → M-05 → M-01 → M-08 | Small correctness fixes first (D-04, D-05, D-10, M-02 are pure and cheap), then the ones that change the state machine or the pipeline. M-08 after M-01 (resume must know the final pass). |
| **C — faster and better** | D-06 → D-07 → D-08 → D-09 → D-11; M-04 → M-03 → M-12 → M-13 → M-07 → M-09 → M-10 → M-11 | The dictation latency series is one chain, each measured against the previous one with the stats script. M-12 after M-05 (it derives chunk sizes from M-05's fact budget). |
| **D — deeper changes and hygiene** | D-12 → D-15a → D-15b → D-15c → D-16 → D-13 (only on evidence) → D-14 (only on evidence); M-14 → M-15 → M-16b → M-16c | D-12 is the largest dictation change and needs everything in C. D-13 and D-14 run only if Phase A's rows justify them (the task says the threshold). |

Within a phase you may interleave D and M tasks. M ordering inside a phase follows
`02-MEETINGS.md` if it differs. Top five by harm: dictation D-01, D-02, D-07, D-03, D-10;
meetings M-01, M-02, M-05, M-06, M-08 (I2 §3).

---

## 7. Limits we keep on purpose

These are the HELPS verdicts from both audits. **Do not remove, loosen or "tidy" any of them** as
part of another task. If a task seems to require it, stop and write a `BLOCKED` note.

### Dictation (I1-19…I1-29)

| Limit | Where | Why it stays |
|---|---|---|
| `DictationController.Limits` (startup 45 s, drain 10 s, transcribe 90 s, cleanup 30 s, narrow 2 s, command 60 s) | `DictationController.Limits` @ `Core/DictationController.swift:322-348` | No production deadline has fired in the 14-day error log (every such line was `--selftest-dictation`'s injected 2 s limits). They exist for the documented "stuck in `.finishing`" failure and cost nothing when unused. AGENTS.md: "Every await in the dictation tail has a deadline". |
| `ChunkedFormatter` whole-pass budget 26 s, `maxWords` 120 | `Formatting/SentenceChunker.swift:110,128` | 26 s sits under the 30 s outer bound; no run was "left as spoken". D-07/D-08 change per-call ceilings *inside* it, never the 26 s. |
| `CleanupGuard` rules: invention, length ratio 0.35–1.7 (grammar), rewrite budget, phonetic budget | `CleanupGuard.rejection` @ `Formatting/CleanupGuard.swift:40-175`, `phoneticBudget` :435 | Rejected 3 of 50 answers, two already fixed in code. The problem is salvage granularity (D-11), not the thresholds. |
| Token caps: Apple cleanup 1,200, layout 500, app-LLM `min(1200, max(64, 4·words))` | `FoundationModelFormatter.cleanReporting` (`maximumResponseTokens: 1_200`), `StructurePlanner.swift:144`, `AppLLMCleanupFormatter` | Never reached: groups are ≤ 120 words and a plan is a few dozen tokens. Not an `AgentAnswerBudget` concern (section 5). |
| Parakeet partial cadence 1.0 s, reuse below 0.5 s leftover, one queued partial | `ParakeetEngine.maybeEmitPartial` / `finish` | `speech_to_first_partial` p50 2.06 s is mostly the time before the user starts speaking; reuse keeps `transcribe` at 0.14–0.5 s. |
| Push-to-talk fires on key-down with no threshold; Command Mode needs a 400 ms hold | `DictationController.commandHoldThreshold` :546, `HotkeyMonitor` | Key-down firing is what makes dictation feel instant; the stray tap is handled by D-04, not by a threshold. The Command Mode threshold is AGENTS.md-documented (⌘C). |
| Key-down origin, two-mechanism return (activate + `kAXFrontmostAttribute`), 600 + 400 ms polling, caret-moved verification | `TextInjector` | AGENTS.md "Where a dictation goes is decided at key-down" and "Returning to that app needs two mechanisms". No `couldNotReturn` in the log. |
| Bias and prompt caps: `biasLimit` 40, `promptNameLimit` 120, harvest 250 ms / 1,500 nodes / 200 names, Apple ASR context wait 60 ms | `DictionaryCorrector`, `ScreenContext`, `AXHarvester.Budget`, `AppleSpeechEngine.context()` | Measured (AGENTS.md screen-name entry). Inert on this Mac (Parakeet, no adapter apps). D-16 is a spike, not a cap change. |
| `cleanupSkipsModelWhenBusy` (opt-in), `shortWordLimit` 20 | `CleanupRouter.shortWordLimit` :32 | Opt-in; fired once in 51 runs, as documented. |
| `CleanupSessionWarmer.capacity` 3, a staged session is taken once | `CleanupSessionWarmer` @ `FoundationModelFormatter.swift:313-351` | Cleanup + layout + one spare; a session held across dictations would carry the previous transcript. D-08 stages more sessions *per hold*, never raises the capacity above what a hold uses. |
| `CorrectionLearner.maxCandidates` 5 | `Dictionary/CorrectionLearner.swift:34` | A larger edit is a rewrite. D-10 fixes the per-span test, not this cap. |
| The `LlamaBackend` cleanup gate is one-directional | `AppLLMCleanupFormatter`, `NotesModelRuntime.loadIfNeeded` | AGENTS.md: closing the cycle deadlocks. No D task calls `beginCleanup()` and then loads or completes on the notes runtime. |
| `SpokenStructure` runs before **and** after the model | `CleanupRouter.format` Stage C | AGENTS.md "A prompt rule is only a rule for the engines that read prompts". D-11/D-12 must keep both passes on the final text. |
| Self-tests pass the `record:` seam | `DictationController.init(record:)` | AGENTS.md "A self-test must never call `RunLog.record`" (55 fixture rows once leaked into a real history). |

### Meetings (I2 #22–#34)

| Limit | Where | Why it stays |
|---|---|---|
| Hand-started recordings never auto-stop | `MeetingScheduler.swift:268-271` | By design (AGENTS.md "An armed meeting's end…"): a recording someone started by hand is never cut off for being quiet. An optional "Still recording?" card is a nicety, not a task. |
| `CallPolicy` on/off debounce (3 s / 15 s) and the 5 s backstop poll | `CallPolicy.swift:29,34`; `CallDetector.swift:45` | Measured flicker of `kAudioProcessPropertyIsRunningInput` (AGENTS.md "The microphone flag flickers"). Lowering `offThreshold` re-introduces the bug. |
| `deniedBundleIDs` is a **denylist**, not an allowlist | `CallPolicy.swift:48-59` | AGENTS.md: an unknown conferencing app must work on day one. M-02 *adds* `com.apple.replayd`; it never turns the list into an allowlist. |
| Detected calls exempt from the overrun rule; 10-minute silence backstop | `MeetingScheduler.swift:272-283` | Correct as documented. M-11 adds "stop when the covering call ends" for calendar meetings; it does not remove the exemption. |
| Segment = 600 ms pause, or a sentence end once ≥ 2 s (inside a window) | `ChunkedTranscriber.swift:75,83,351-362` | AGENTS.md "A transcript segment is a sentence, not a window". M-01 changes the **window** around this rule, never the rule. |
| Writer lead 5 s; 16-bit stereo on disk (≈ 230 MB/h); two tracks | `MeetingAudioWriter.swift` | AGENTS.md "Meetings record two tracks on purpose". |
| Notes model 10-minute idle unload; cleanup gate; warm at meeting start | `NotesModelRuntime.swift:50`; `MeetingSession.swift:216-227` | AGENTS.md "The notes model unloads itself" (16 GB machine). |
| Brief counted before the single-pass decision; map step without the brief; `emptySection` forces `_None._` | `NotesGenerator.swift:71-101,148-159,361-375` | AGENTS.md "The Related-context brief is deliberately absent from three places". M-13 changes what a *truncated* answer shows; it does not change `emptySection` for a genuinely empty brief. |
| `audioIsTemporary` decided at start; the three-line `releaseAudio` rule | `MeetingSession.swift:90-103`; `MeetingStore.releaseAudio` | AGENTS.md "A meeting records audio even when…". M-10 changes **when** it runs, never the keep-or-drop rule. |
| `armedGrace` 10 min, `tickInterval` 30 s, one session at a time | `MeetingScheduler.swift:23,31` | Documented and sound. |
| Diarizer `minimumAudioSeconds` 2; voice print `minimumSeconds` 3 | `MeetingDiarizer.swift:33`; `SpeakerVoicePrints.swift:25` | Below these the embedding is noise. |
| Chunk-level silence gate: RMS 0.01 (≈ −40 dBFS) per 20 ms frame | `ChunkedTranscriber.swift:66-70,241-250` | No evidence against it. Recheck only once far-field fixtures exist (not in this roadmap). |
| Calendar look-ahead 24 h / look-behind 1 h / poll 5 min; declined-only exclusion | `Calendar/CalendarService.swift:29-34`; `EventKitCalendarProvider.swift:72-74` | Fine (H3 #34). |
| Chrome is offered only "Ask first" and "Never" | `CallPolicy.askOnlyBundleIDs`, `availableAnswers(forApp:)` | AGENTS.md: "that missing third option is the feature". M-02 makes it **actually apply** to the helper process; it does not relax it. |
| `Meeting` new fields decode with `decodeIfPresent` | `MeetingModels.swift` hand-written `init(from:)` | AGENTS.md: otherwise every meeting on disk vanishes. Every M task that adds a field obeys this. |

---

## 8. Per-task workflow, phase gates, and the rules (short form)

**Workflow.** Follow AGENT-OVERHAUL `00-README.md` §5 exactly, with these substitutions:
- logs go to `~/Library/Caches/NextNotesBuild/dictation-meetings/<ID>-red.txt` / `<ID>-green.txt`
  (`mkdir -p ~/Library/Caches/NextNotesBuild/dictation-meetings` once);
- commit messages are `D-NN: <title>` / `M-NN: <title>` (lettered subtasks: `D-15a: …`), body as
  there, ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`;
- the ledger is this folder's `STATUS.md`.

In one breath: read the task and its files → re-verify every anchor with `grep -n` (lines drift;
symbols are named so you can find them) → write the red-first self-test (seam only, no fix) →
`make build` → `make install OPEN=0` → run it and see `<NAME>_FAILED` → implement → build →
install → run until `<NAME>_OK` → run the regression flags → update `STATUS.md` → one commit with
only the files you touched (`git add <paths>`, never `-A`).

**Phase gates** (run when every task of a phase is `done` or `blocked`), per AGENT-OVERHAUL §6:
1. `make test` (dictionary and spoken-form vectors).
2. `make acceptance TIER=core`; nothing that was PASS in the baseline may be FAIL. Known red:
   `selftest-wake-live`, and `selftest-computer` on a locked screen.
3. The phase's exit flags (below), one at a time.
4. `python3 Scripts/dictation-stats.py --since <phase start>` and, once P0-20d exists,
   `Scripts/run-selftest.sh --usage-report` (or however P0-20d names its invocation).
5. Write `Tests/Reports/DICTATION-MEETINGS-P<A|B|C|D>-<YYYY-MM-DD>.md` (commit range; flag → final
   line before/after; stats-script numbers before/after; acceptance summary; BLOCKED tasks), and
   commit it alone as `DM-GATE-<A|B|C|D>: phase report`.
6. Update *Phase gates* in `STATUS.md`.

| Phase | Exit flags |
|---|---|
| A | `--selftest-dictation` (via-open) with the D-01b outcome assertions; `--selftest-cleanup-router`; `--selftest-usage-log` (P0-20e) including the new feature values; `--selftest-metrics`; `--selftest-meeting-quality`; `--meeting-quality-report` output saved |
| B | `--selftest-dictation` (via-open), `--selftest-learn`, `--selftest-calls`, `--selftest-island`, `--selftest-notes-longform`, `--selftest-meeting-finals`, `--selftest-meeting-resume`, `make test` |
| C | `--selftest-cleanup-router`, `--selftest-cleanup apple-grammar` (`CLEANUP_SUMMARY` line), `--selftest-diarize-assign`, `--selftest-diarize-hints`, `--selftest-notes-longform` (M-12 cases), `--selftest-notes-truncation`, `--selftest-meeting-backlog`, `--selftest-meeting-tap-retry`, `--selftest-audio-retention`, `--selftest-calendar` |
| D | `--selftest-dictation`, `--selftest-dictation-hygiene`, `--selftest-contention`, `--selftest-meeting-live`, `--selftest-onboarding`, `--selftest-usage-log` (M-16b), `--selftest-metrics` (M-16c); dictation targets in `01-DICTATION.md` §0.3 checked against owner use |

**Rules you must never break** (long form: AGENTS.md and AGENT-OVERHAUL `00-README.md` §9):
- Efficiency, speed and full-duplex conversation come first: do not add a sequential await, a
  fixed sleep, a debounce or a second confirmation to a path the user waits on, and do not
  serialise audio and interaction ("it is safer" is not a reason). The full statement is
  AGENTS.md "What we optimize for".
- Do not add a new store, ledger, queue or channel without reading AGENTS.md's single-owner
  paragraph first; prefer the existing seam and the smaller diff.
- The person using this is not technical: no flow may ask for an API key, a terminal command or
  a config file when the app can do it for them, and copy stays in the user's own words
  (`--selftest-ui-strings` is the floor, not the goal).
- Build only with `make build`; tests with `make test`; never bare `swift build`/`swift test`
  (iCloud folder; on "input file was modified during the build", wait 5 s and retry, up to 3×).
- Install only with `make install OPEN=0`. Never launch the GUI; never bare-invoke the binary;
  never run the `.app` from the repo folder.
- Self-tests only through `Scripts/run-selftest.sh --selftest-…`, foreground, one at a time.
  `--via-open` only for TCC-bound tests (`--selftest-dictation`, `--selftest-microphone`,
  `--selftest-systemaudio`, live acoustic, AX readback); **never loop `--via-open`**.
- A self-test ends with `<NAME>_OK` / `<NAME>_FAILED: <reason>`; a missing precondition is
  `<NAME>_ABSENT: <what>`, never OK. It must fail when the thing it names did not happen.
- A self-test never writes the user's real stores: `runs.jsonl` (use the `record:` seam),
  `usage.jsonl` (use `UsageLog(directory:)` or the harness temp store), `metrics.jsonl` (the
  harness store is temp; do not bypass it), `dictionary.txt`, `Meetings/`, `UserDefaults`.
- Never lower a threshold, skip an assertion, special-case `SelfTest.isRunning` in production
  logic, or turn `_FAILED` into `_ABSENT` to get a pass. Stop and write `BLOCKED` instead.
- Every await in the dictation tail stays behind `withBoundedWait`. `MainActor.assumeIsolated` is
  forbidden. Never mutate `@State` inside a `Canvas` draw closure.
- New `Meeting` fields: `decodeIfPresent` in the hand-written `init(from:)`.
- `shared/dictionary-test-vectors.json` is the **specification for correction behaviour**. A task
  that changes how corrections are applied changes the vectors first, copies them to
  `Tests/NextNotesDictionaryTests/`, and runs **both** `make test` and
  `cd windows && dotnet test NextNotes.CrossPlatform.slnf`. (D-10 changes what is *learned*, not
  how a rule applies; it says so and does not touch the vectors.)
- UI: no literal colours/sizes/durations (use `DS` tokens); red means recording and nothing else;
  no developer words in user-visible strings (`--selftest-ui-strings`); one animating orb per
  screen, and an orb state means one thing (AGENTS.md table).
- When a task changes a behaviour AGENTS.md documents as deliberate, the task quotes the
  paragraph, says what new evidence overrides it, and updates AGENTS.md in the same commit.
- New dependencies: BSD/MIT/Apache-2.0/ISC/OFL only; update `THIRD-PARTY-NOTICES.md`.
- Use `/usr/bin/log`, not `log`. Never `tccutil reset` without `ai.pivotstudio.nextnotes` (and
  leave it to the owner).

**When stuck:** AGENT-OVERHAUL `00-README.md` §8. Set the row to `blocked`, write the note under
the ledger (date, what you tried, the failing line and its saved path, what is missing), and move
to the next task whose dependencies are met. Several tasks here need the **owner's real use**
(dictations, calls) to reach their numeric targets; the deterministic self-test is the task's
gate, and the real-use number is recorded later in `STATUS.md` → *Owner-use measurements*.

---

## 9. Self-test flags

Every **new** flag is registered in `NextNotesApp.runRequestedSelfTest`, added to the AGENTS.md
flag list, and added to `Scripts/acceptance.sh` in the tier shown. A flag several tasks extend
keeps **one** final marker; tasks add cases, never a second marker. The M rows mirror
`02-MEETINGS.md` §1.10, which is authoritative for them.

### New flags

| Flag | Created by (extended by) | Final marker | Tier |
|---|---|---|---|
| `--selftest-dictation-hygiene` | D-15a (D-15b) | `DICTATION_HYGIENE_OK` / `DICTATION_HYGIENE_FAILED: <n> problem(s)` | INTEGRATION |
| `--selftest-meeting-quality` | M-16a | `MEETING_QUALITY_OK` / `…_FAILED` | INTEGRATION |
| `--meeting-quality-report` (diagnostic, not a self-test; reads real meetings read-only) | M-16a | `MEETING_QUALITY_REPORT_DONE: <n> meeting(s)` | none |
| `--selftest-meeting-finals [<dir>]` | M-01 | `MEETING_FINALS_OK` / `…_FAILED` / `…_ABSENT` | INTEGRATION |
| `--selftest-diarize-hints` | M-03 | `DIARIZE_HINTS_OK` / `…_FAILED` | INTEGRATION |
| `--selftest-diarize-assign` | M-04 | `DIARIZE_ASSIGN_OK` / `…_FAILED` | INTEGRATION |
| `--selftest-notes-longform` | M-05 (M-12) | `NOTES_LONGFORM_OK` / `…_FAILED` | INTEGRATION |
| `--selftest-meeting-backlog` | M-07 | `MEETING_BACKLOG_OK` / `…_FAILED` | INTEGRATION |
| `--selftest-meeting-resume` | M-08 (M-16c) | `MEETING_RESUME_OK` / `…_FAILED` | CORE |
| `--selftest-meeting-tap-retry` | M-09 | `MEETING_TAP_RETRY_OK` / `…_FAILED` | INTEGRATION |
| `--selftest-audio-retention` | M-10 | `AUDIO_RETENTION_OK` / `…_FAILED` | INTEGRATION |
| `--selftest-notes-truncation` | M-13 | `NOTES_TRUNCATION_OK` / `…_FAILED` | INTEGRATION |

### Existing flags extended (marker unchanged)

| Flag | Extended by | Final marker | Notes |
|---|---|---|---|
| `--selftest-dictation` | D-01b, D-02, D-03, D-04, D-05, D-13 | `DICTATION_OK` / `DICTATION_FAILED` | CORE, **via-open** (real microphone) |
| `--selftest-cleanup-router` | D-01a, D-06, D-07, D-08, D-09, D-11, D-12 | `CLEANUP_ROUTER_OK` / `CLEANUP_ROUTER_FAILED` | `--probe-layout` / `--probe-cleanup-warmth` / `--probe-chunk-width` print live measurements and assert nothing |
| `--selftest-cleanup <engine>` | D-07 (reads `CLEANUP_SUMMARY`), D-11 (one eval case) | `CLEANUP_OK` / `CLEANUP_FAILED` | long pole; sizes its own timeout |
| `--selftest-learn` | D-10 | `LEARN_OK` / `LEARN_FAILED` | |
| `--selftest-contention` | D-14 | existing | |
| `--selftest-usage-log` (P0-20e) | D-01b, M-16b | as P0-20e defines | |
| `--selftest-metrics` | M-16a, M-16c | `METRICS_OK` / `METRICS_FAILED` | |
| `--selftest-calls` | M-02 | existing | |
| `--selftest-island` | M-06 | `ISLAND_OK` / `ISLAND_FAILED` | also extended by AGENT-OVERHAUL P3-09 |
| `--selftest-calendar` (+ `--fake-calendar`) | M-11 | existing | |
| `--selftest-meeting-live` | M-14 | existing | |
| `--selftest-onboarding` | M-15 | existing | |

**Real-audio fixtures.** Meeting fixtures are generated and committed by M-16a under
`Tests/Fixtures/meetings/` (`generate.sh`, see `02-MEETINGS.md` §1.8). For the baseline and for
dictation checks, generate throwaway files outside the repo:

```bash
F=~/Library/Caches/NextNotesBuild/dictation-meetings/fixtures; mkdir -p "$F"
say -v Samantha -o "$F/en.aiff" "Okay so the plan is to ship the installer on Friday and then write the release note."
afconvert -f WAVE -d LEI16@16000 "$F/en.aiff" "$F/en16k.wav"
say -v Jacques -o "$F/fr.aiff" "Bonjour. Alors pour le budget, on reste à quarante mille euros, et on signe le contrat la semaine prochaine."
afconvert -f WAVE -d LEI16@16000 "$F/fr.aiff" "$F/fr16k.wav"
say -v '?' | grep -E "fr_(FR|CA)"     # other French voices: Eddy, Flo, Amélie, Thomas…
```
