# BUILD ORDER — current model/module coordination and historical collision matrix

**2026-10-02 current dependency update:** P6-03 is committed `1c68d3e` with37
installed actual journal/tool/approval cases and owner isolation green. P6-04a-1 held/strict-read foundation is committed `6f50e07` (56 installed cases, 12 related flags and owner isolation green); P6-04a-2 SQL authority migration is committed `5de382a` and installed (authority54/recovery56/durability37, all13 targeted flags green; parent open). P3-06a remains
open: bounded foundation `5ecc7e6` passes scripted capture/output/replay with
zero observed disagreements; physical/full-suite coverage remains open. The cited CORE15/18 is historical 2026-10-01 evidence, not a current core rerun.
Bounded typed-local attempt/receipt admission and normal typed ACP attempt admission
are now verified. ACP receipt startup admission (`e946ecd`: original65 RED9 → fixed66
worker731), completion admission (`404725b`: original67 RED4 → fixed68 worker764),
and permission selected/cancelled encoding (`4f37916`: original69 RED3 → fixed70
permission22/origin68/worker764) pass; app70 all20 focused flags pass. Those focused
checks are not CORE or model evaluations. Remote origin/attempt authority, live
lease/session/current-client authority, receipt reconciliation, crash recovery/retry,
TaskBridge, OutputScheduler and durable delivery remain open; IM-16 stays blocked.
Parent Phase6 and the unchanged quick9/full/owner/latency gates remain open.

## Current coordination — owner revision 2026-09-30

**Implementation sequencing revision, 2026-10-01:** the owner approved engineering
below the Agent's inherited 9/10 quick score. Follow [Agent README §4.1](in-progress/AGENT-OVERHAUL/00-README.md#41-implementation-eligibility-and-quality-gates--owner-decision-2026-10-01).
P3-01 is complete (`c1e635b`), MOD-02 source integrated (`7dc1b0c`, by-eye open),
and bounded SB-01b manifest adoption complete (`8b70b24`, parent open). P3-02
is committed (`7e3aba1`), with three installed duplex runs and related regressions
passing. P6-02a is committed (`670bc35`), with 18 installed cases and isolation
passing. P3-06a bounded foundation is committed `5ecc7e6`, scripted zero disagreements; physical/full-suite coverage remains open. P6-03 journal is committed
`1c68d3e` (installed37cases); P6-04a-1 held/strict-read foundation is committed `6f50e07` (56 installed cases, 12 related flags and owner isolation green); P6-04a-2 SQL authority migration is committed `5de382a` and installed (authority54/recovery56/durability37, all13 targeted flags green; parent open);
root serializes registrations/integration.
P6-01 is done as `ff40a93` (installed baseline/tasks/isolation pass; core 16/18
retains wake/dictation failures; isolated dictation capture-timing recheck unresolved).
Retained parent P6-02 stays in progress: P6-02a storage is done, P6-02b
evidence/UI is todo. P6-03's dependency is satisfied by committed verified
P6-02a, independently of open P6-02b. Latest CORE15/18 fails dictation capture/continuity, wake accuracy and computer focus.
P2-01 measurement audit and P4-07a provenance remain candidates. No
aggregate bar, full/owner gate or readiness requirement was lowered. Latency
instrumentation already exists; audit/rebaseline it. P6 fixtures must first have
an isolated real store/manager construction seam. The live ledgers record these actual claims/completions.

File ownership still decides parallelism: P2/P3 share capture/voice code; P6
durability registrations collide with frozen iMessage edits to NextNotesApp,
AGENTS and acceptance; P4-07a collides with existing NextMemory writers. Claim
small disjoint files, then serialize shared entrypoint edits, builds and model
benchmarks. P6-04a must land before P3-03a starts, or after P3-03b finishes.
[Sequencing audit](../Tests/Reports/agent-sequencing-2026-10-01.md) records verified entry contracts and unchanged gates.

**Use this section for new work.** The numbered matrix below is the 2026-09-25
snapshot; its counts, task states and "start now" queues are historical, not current
readiness or permission to run concurrent edits. Follow live STATUS ledgers and task
Depends-on lines. New model/module overlaps are listed here, not hidden in old counts.

The owner chose independent models for Meetings, Agent and Dictation cleanup,
reusing exact verified artifacts. [SHARED-BRAIN](in-progress/SHARED-BRAIN/00-README.md) keeps
its folder/IDs but supersedes mandatory delegation/universal-default instructions.
[MODULES-ACTIVATION](in-progress/MODULES-ACTIVATION/00-README.md) derives enabled requirements
and safe deletion from existing choices/work. Neither adds a second store/queue/log.

| Stream | Current authority | Dependency / ownership |
|---|---|---|
| Agent behavior and full duplex | AGENT-OVERHAUL STATUS linked below | P3-01 production voice-route regressions done `c1e635b`; P3-02 actual planner/read-barrier work done `7e3aba1`; P6-01 baseline done `ff40a93`, P6-02a mirror done `670bc35` and P6-02b evidence/UI open; P3-06a bounded shadow foundation committed `5ecc7e6`, scripted zero disagreements; physical/full-suite coverage open; P6-03 journal done `1c68d3e`; P6-04a-1 held/strict-read foundation is committed `6f50e07` (56 installed cases, 12 related flags and owner isolation green); P6-04a-2 SQL authority migration is committed `5de382a` and installed (authority54/recovery56/durability37, all13 targeted flags green; parent open). P1-31a/b and bounded explicit-save P1-31c `4063667` committed; original Y01 passes, current fixed quick 5/10 below 9/10; Qwen full ordinary 17/30 vs Needle 16/30, no promotion. Parent P1-31 full/owner/latency gates remain open |
| Shared files / independent roles | SHARED-BRAIN SB-01…08 | SB-01a existing-byte verification/library proof done `4476a82`; bounded SB-01b legacy installed-row adoption done `8b70b24`; parent SB-01 incomplete; SB-02…08 still todo |
| Module activation | MODULES-ACTIVATION MOD-01…10 | MOD-01 foundation done `450dbaa`; MOD-02 navigation/sidebar integrated `7dc1b0c`, by-eye evidence open; MOD-03…07 may start with coordinated file ownership; MOD-08 model integration after SB-04/05; MOD-09 after SB-01…04/SB-06 |
| MiniCPM cleanup + Apple guard/fallback | Concurrent OpenCode implementation; handoff linked below | Existing formatter/default/guards owned by that executor; coordinate before shared-runtime/library edits |
| Memory lifecycle | memory-lifecycle-consolidation-roadmap.md | Not scheduled; implementation after P4-07a → P4-07 → P4-11; corpus and measurable gate before consolidation |

Agent ledger: [AGENT-OVERHAUL STATUS](in-progress/AGENT-OVERHAUL/STATUS.md).

**Parallel ownership, revised 2026-10-01:** root owns serial build/install and
shared NextNotesApp/AGENTS/README/acceptance integration, preserving frozen foreign
iMessage edits. P6-04a-2 store/manager and fixture workers are frozen after integration; the read-only review found no blocker for this bounded child. P6-03 is committed `1c68d3e`. Root owns the completed authority admission and shared-document handoff. P3-06a bounded source is committed `5ecc7e6`;
physical/full-suite coverage remains open.
The coordinator reviews read-only; root owns roadmap amendments. External
WEBSITE-TO-MAC-EXPERIENCE owns app/site UI. No concurrent manager/Executor or
PermissionGate writer is authorized by these task claims. No worker runs a
full build, installed app test or model benchmark; root waits for both sources
frozen. No owner-store seeds, model/default changes, recovery or IM-16 host.

P6-02a preserves all existing AgentTask fields and original task/artifact order.
P6-02a preserved JSON read authority historically; P6-04a-2 now commits SQL first with a retained tagged JSON export. Cross-file atomicity is impossible: primary failure rejects dispatch, export failure preserves committed history. Older array-only binary rollback remains open. Preserve task
history on corruption/newer versions, guard SQLite plus WAL/SHM, and never apply
UsageLog sanitization to execution fields. Existing local requested bodies/paths
and results remain compatible; new raw read/evidence bodies are not collected.
P6-02b retains original step-7 producer/UI gates and needs a separate source claim:
ActionRuntime metadata hunks preserve iMessage work; ToolStepRunner/Executor
artifact/evidence producers serialize after the active P6-03 Executor claim; approval/review/result/projector
consumers prove integration. Storage alone completes neither parent P6-02 nor
IM-16 durability/attempt/receipt/delivery contracts. MOD/SB moved foundations and
later visual/role-quality gates retain their separate ledgers.

Coordinator completed F-01a/F-01b (`7a94d2d`/`fba4287`, 15 CLI tests) in the moved rates/gates roadmap: Python-only
diagnostic reader repair after reproducing a crash and an omitted measured ASR
condition. Existing F-01 remains done; F-02…04 owner-use work stays pending.
This task does not edit the dictation pipeline or collide with its OpenCode owner.

[Current Agent evidence](../Tests/Reports/toolloop-live/2026-09-30-p1-31-investigation.md)
records exact-file reuse and keeps the ordinary planner. Next bounded Agent work:
draft/combined-read and complex-memory follow-through through the existing runner, after bounded P1-31c explicit-save completion and the
[P1-31b timeout/grounding fixes](../Tests/Reports/toolloop-live/2026-09-30-p1-31b-follow-through.md).
The prompt-only candidate was rejected; final verification and incomplete live diagnostics are in the Agent ledger. This does not complete SB-07 or authorize runtime/cleanup
overlap changes; coordinate those seams with the existing OpenCode executor.


| Shared file / seam | Required coordination |
|---|---|
| ModelRoleStore / role self-tests | SB-02 before SB-03; P4-09 coordinates Agent-only consent/routing; preserve notes IDs/context and cleanup choices |
| NotesModelRuntime / LlamaLLMProvider / prefix and native ownership | SB-03, OpenCode cleanup and P3-07 are sequential writers; preserve P0-14/P0-18/P1-28 fixes; no wrong-file inference on deferred swaps |
| InstalledModelLibrary / ModelLibraryStore | SB-01 artifact adoption, SB-02/04 all-consumer deletion, then MOD-09; no basename-only reuse or Agent-only deletion test |
| LocalModelStore / downloader ownership | SB-04 before MOD-09; cleanup reuses exact files/in-flight fetches through existing machinery; no shared-brain rename |
| Onboarding model offer/resume | SB-05 and MOD-08 coordinate; dictation-only MiniCPM included, Apple-only no fetch, union of missing artifacts |
| Models/role/space-manager UI | SB-06 before MOD-09; independent picker choices; one artifact row and truthful reclaimable bytes |
| Cleanup formatter/router/default | OpenCode owns behavior; SB integration is a targeted resolver/ownership change, never an overwrite or duplicate implementation |
| NextMemory / MemoryReviewer / fixtures | P1-30 privacy preserved; P4-07a → P4-07 → P4-11 before lifecycle; durable undo stays in NextMemory, not disposable knowledge.sqlite |
| NextNotesApp / acceptance / AGENTS.md / README | Single writer; coordinate narrow registrations/doc edits, never reset another executor's dirty file |

Shared runtime execution invariants: exact model identity through generation;
interactive work never loses its voice lease; cleanup uses bounded Apple fallback
when MiniCPM ownership is unavailable; notes wait/yield visibly. Shared files never
share prompts, KV history or cloud permission. Second contexts/resident models
require measured admission/latency under P3-07, not a runtime per module.

[OpenCode cleanup handoff](in-progress/SHARED-BRAIN/OPENCODE-CLEANUP-HANDOFF.md) is the concrete
message to that executor. Documentation updates do not register flags, flip defaults,
run models, mark tasks done or validate runtime behavior.

## Owner decision 2026-10-04: positioning and low-end floor

[POSITIONING-AND-LOCAL-MODEL](in-progress/POSITIONING-AND-LOCAL-MODEL/00-README.md) adds
one stream: the local-model bake-off (MiniCPM5-2B, Qwen 4B, Gemma 4 E4B, a code model)
through the real code paths, and the floor benchmark on an M2/M3 MacBook Air (16 GB,
256 GB): ≥20 tok/s decode (25–30 target) with ASR/voice running, usable memory, fitting disk.
Ordering consequences:
* It reuses existing instrumentation (P2-01 spans, `usage.jsonl`, SB-07 fixtures); it
  serializes with every other model benchmark under the rule above.
* SB-07 recommendation flips, SB-05/MOD-08 onboarding offers and MOD-09 model policy wait
  for its verdict; SB-01…04 foundations do not.
* PAID-RELEASE launch waits for the bake-off verdict and a passing floor benchmark;
  Apple enrolment and build-pipeline work can proceed in parallel.

## Historical 2026-09-25 matrix

Everything below retains the original evidence/counts. Moved NextNotes roadmap
paths are corrected for navigation; historical measurements and recommendations
are superseded where the current section or live ledger says otherwise.

**Written:** 2026-09-25. **Nothing under `roadmap/` is committed** (AGENT-OVERHAUL `00-README.md` §2),
so this is a coordination document and nothing more.

**What this is.** A file-level answer to one question: *given the five roadmaps below, which tasks can
run at the same time and which must be serialised?* It is derived from each task's own
**Files you will change** line plus any file named in its Steps, normalised to a repo-root-relative
path. Where a task names a file only in a **Read for context (do not change)** line, it is in the
read-only column and is **not** a conflict.

**How to check any row.** Every task id in the matrix appears in its roadmap's `STATUS.md` ledger.
153 of the 185 ledger ids name at least one file; the 32 that do not are in §6. To
verify a row, open the task's section in the phase file named in §1.2's index and read its
*Files you will change* line.

## 0. Verdicts, and what each one means here

| Verdict | Meaning | Count |
|---|---|---|
| `SAFE` | exactly one task in all five roadmaps writes it | 258 |
| `SHARED-READ` | one writer, several tasks name it read-only | 31 |
| `SERIALISE` | two or more write it, **and** the roadmaps already say who goes first | 143 |
| `COLLISION` | two or more write it and **no roadmap says who goes first** | 12 |

444 files carry at least one writer. 155 of them have two or more. 37 of those are cross-roadmap.

**A note on the `SERIALISE` / `COLLISION` line.** 118 of the 143 `SERIALISE` rows are
*within* a single roadmap (100 AGENT-OVERHAUL, 16 DICTATION-MEETINGS, 1 iMessage, 1 Phone-Calls) and
are already serialised by that roadmap's own phase gates and `Depends on` chain. They are listed
because an orchestrator batching across workstreams still has to know they are shared. The 25
cross-roadmap `SERIALISE` rows are the ones where a *second* roadmap names the coordination; they are
grouped in §2.2 with the sentence that does it.

## 1. Sources

### 1.1 The five roadmaps

| Roadmap | Ledger | Tasks | States |
|---|---|---|---|
| `roadmap/in-progress/AGENT-OVERHAUL/` | `STATUS.md` (406 lines) | 106 ids | 27 `done`, 1 `done (won't do)` (P0-16), 1 `blocked` (P0-10), rest `todo` |
| `roadmap/done/DICTATION-MEETINGS-LIMITS/` | `STATUS.md` (325 lines) | 40 ids | 25 `done`, rest `todo` |
| `roadmap/in-progress/NextNotes-iMessage/` | `STATUS.md` (109 lines) | 18 ids | all `todo`; 3 gates open |
| `roadmap/backlog/Phone-Calls/` | `STATUS.md` (113 lines) | 21 ids | all `todo`; 4 gates open |
| `roadmap/backlog/memory-lifecycle-consolidation-roadmap.md` | **none** | **no task ids** | not scheduled; implementation follows AO P4-07a → P4-07 → P4-11 |

### 1.2 Which file carries which task's text

`AGENT-OVERHAUL`: P0-01…P0-23 → `01-PHASE-0-MAKE-IT-ANSWER.md` · P1-01…P1-18 → `02-PHASE-1-TOOLS.md` ·
P2-01…P2-08 → `03-PHASE-2-LATENCY.md` · P3-01…P3-10 → `04-PHASE-3-FULL-DUPLEX.md` ·
P4-01…P4-13 → `05-PHASE-4-PROACTIVE.md` · P5-01…P5-04 → `06-PHASE-5-CLOUD-REALTIME.md` ·
P6-01…P6-10 → `07-PHASE-6-DURABLE-JOBS.md`.

`DICTATION-MEETINGS-LIMITS`: D-01a…D-16 → `01-DICTATION.md` · M-01…M-16c → `02-MEETINGS.md`.
`iMessage`: IM-01…IM-03 → `01-PHASE-0-SELF-FLOW.md` · IM-04…IM-10 → `02-PHASE-1-P0-SLICE.md` ·
IM-11…IM-17 → `03-PHASE-2-P1-SLICE.md`.
`Phone-Calls`: PH-01…PH-04 → `01-PHASE-0-GATES.md` · PH-05…PH-13 → `02-PHASE-1-V1.md` ·
PH-14…PH-21 → `03-PHASE-2-V2-AUDIO.md`.

### 1.3 Path normalisation

The five roadmaps name files in four styles. All are normalised to a path relative to the repo root:

| Style as written | Example | Normalised |
|---|---|---|
| fully qualified | `` `Sources/NextNotes/Agent/RealtimeAgent.swift` `` | unchanged |
| relative to `Sources/NextNotes/` | `` `Formatting/CleanupRouter.swift` `` | `Sources/NextNotes/Formatting/CleanupRouter.swift` |
| bare, unique basename | `` `CleanupRouter.swift` `` | resolved against the tree; a bare name with no unique match is **not stated** |
| a type, not a path | `` `CallPolicy` `` | **not stated** — recorded in §5 as an under-declared file, never guessed |

The three styles are all present in the same file: `AGENT-OVERHAUL` Phase 0 writes
`Core/DictationController.swift`, Phase 6 writes `Sources/NextNotes/Support/Usage/UsageRecord.swift`,
and `DICTATION-MEETINGS-LIMITS` writes `Meetings/CallPolicy.swift`. Comparing them without
normalising would have hidden every collision in this document.

### 1.4 What is *not* in the matrix

- A file named in a **Do not** line is excluded even when a parser would catch it. `D-16`'s Files line
  is `Package.swift` and its very next line reads *"Do not … change `Package.swift`"*; it is a spike
  with no product code.
- A file named only to be *reused* is excluded. `PH-18`'s "Everything exists:
  `Transcription/ParakeetEngine.swift`" is a read; only `D-04` (done) and `D-14` and `P3-07` write it.
- The memory-lifecycle roadmap gets a **fifth column keyed by its own section numbers** (§2, §3, §4,
  §5) because it has no task ids and no ledger. Inventing ids for it would be worse than the gap.

## 2. Findings

### 2.1 The 12 `COLLISION` rows

Ten findings across twelve files. Grouped by the decision that resolves them.

---

**C1 — `Sources/NextNotes/Support/Settings.swift` (14 writers: 9 AO, 5 DM)**
Live on both sides: AO `P1-05`, `P4-04`, `P4-05`, `P4-06`, `P4-09`, `P4-13`, `P5-01`; DM `D-15a`,
`M-01`(done), `M-02`(done), `M-14`, `M-15`. Each adds a hidden key; `P1-05`'s line reads
*"`Support/Settings.swift` — hidden `agentNativeToolCalling` (default `true` once the gate below
passes; defaults key only, no UI)"* and `P4-13` and `M-15` both add a consent-shaped default.
**Neither roadmap mentions the other on this file.** `M-14`'s `Depends on` is *"M-01 (soft); AO P0-14;
coordinate AO P3-07a"* and `M-15`'s is *"M-10, M-03"* — neither names `P4-04`/`P4-05`/`P4-06`/`P4-09`/
`P4-13`, and none of the `P4-*` rows names a DM task. The failure mode is a silent key collision, and
`Settings` is where the app decides whether a feature runs at all.
**Owner split:** DM owns every `Meetings/`-shaped key (`M-14`, `M-15`, `M-01`, `M-02`); AO owns every
Agent-shaped key. One registration commit per roadmap, batched, each listing its own keys.

---

**C2 — the five `Formatting/LLM/*` provider files**
`LLMProvider.swift` (AO `P0-17`✓, `P1-05` · DM `M-13`), `LlamaLLMProvider.swift` (AO `P0-14`✓,
`P1-01`, `P1-05` · DM `M-13`), `OpenAICompatibleLLMProvider.swift` (AO `P0-19`✓, `P0-20a`✓, `P1-05` ·
DM `M-13`), `OpenRouterLLMProvider.swift` (AO `P0-17`✓, `P0-19`✓, `P0-20a`✓, `P1-05`, `P4-09` ·
DM `M-13`), `FoundationModelLLMProvider.swift` (AO `P0-20a`✓, `P1-01` · DM `M-12`✓, `M-13`).
`M-13` is *Cut-off answers visible: `finishedByLimit`, one retry, "cut short", scaled cap* — it adds
the same `finishReason` plumbing to all five providers that `P1-05` is already rewriting to send
`tools`/`tool_choice`. `M-13`'s `Depends on` is *"M-12; AO P0-17 (OpenRouter leg only)"*: it names one
already-done AO task and none of the three live ones. `P1-05`'s is *"P1-03, P1-04, P1-06, P0-04, P0-07"* —
no DM task at all. **This is the largest unowned overlap in the document.**
There is one documented exception: DM `M-12`'s ledger records *"P1-10a step 0 landed here verbatim
(both STATUS files; AO's table skips it)"* — a one-sided coordination DM wrote about itself.
**Owner split:** `M-13` lands first and owns `finishedByLimit` on all five providers; `P1-05` then
adds the tools plumbing on top and owns it from then on. `P1-01` is read-only on
`FoundationModelLLMProvider`/`LlamaLLMProvider` (it counts tokens for the eval) and must not edit them.

---

**C3 — `Sources/NextNotes/UI/Settings/AgentSettingsTab.swift` (5 roadmaps)**
AO `P1-17`, `P4-04`, `P5-01`; iMessage `IM-04` (*"one line for a `MessagesAccessSection`"*);
Phone-Calls `PH-05` and `IM-17`. This is the user's third known collision and it is **wider than
stated**. `IM-17`'s Files line is `` `Sources/NextNotes/UI/Settings/IMessageSettingsSection.swift` (new
— a **section** in `AgentSettingsTab`, not a thirteenth `SettingsTab` case)`` and `PH-05`'s is
`` `Sources/NextNotes/UI/Settings/PhoneCallsSettingsSection.swift` (new — a **section** in
`AgentSettingsTab`, not a thirteenth tab)`` — **neither names `AgentSettingsTab.swift` in its Files
line**, though both require a line in the tab's body (`PH-05`: *"A section is one file and one line in
the tab's body"*). Phone-Calls `00-README.md` §8 says the file is *"shared with the iMessage folder.
Coordinate; never revert a file you did not change"* — that is a gesture, not an owner. The
single-writer rule in both new READMEs covers only `NextNotesApp.swift`, `Scripts/acceptance.sh` and
`AGENTS.md`; this file is not in it. memory-lifecycle §5 would add a fourth section
(`MemoriesSection`) to the same tab.
**Owner split:** AO owns the tab through Phase 5; iMessage and Phone-Calls each land their section file
as a **new file only** and hand the one-line registration to the orchestrator, batched with the
registry edits in §4.

---

**C4 — `Sources/NextNotes/Agent/AgentService.swift` (AO `P0-20b`✓, `P4-04`, `P4-10`, `P4-13` · DM `M-14`)**
`M-14` is *Live meeting understanding on speech time, last 3 minutes, own switch*. Its `Depends on` is
*"M-01 (soft); AO P0-14; coordinate AO P3-07a"* — it names `P3-07a`, not the three Phase 4 tasks that
also write the file, and `P4-04`/`P4-10`/`P4-13` name no DM task. All four AO writers are the Agent's
proactive path; `M-14` is the meetings path inside the same actor.
**Owner split:** AO owns `AgentService.swift` for the whole of Phase 4; `M-14` lands after `P4-13`, or
takes a named seam from it (the `Meeting` entry point), and says which in its ledger.

---

**C5 — `Sources/NextNotes/Meetings/MeetingModels.swift` (AO `P4-10`, `P4-13` · DM `M-01`✓, `M-10`✓, `M-11`)**
`M-11` adds `Meeting.coveringCallID: String?` with `decodeIfPresent`. AGENTS.md's rule is that
`MeetingModels.swift` has a hand-written `init(from:)` and *"Adding a property … without
`decodeIfPresent` orphans every meeting on disk"* — so this file is the one place in the meetings half
where a merge mistake is silent and total. `M-11`'s `Depends on` is *"M-02, M-06"*; `P4-10`'s is
*"P0-20b, P1-10a"*; `P4-13`'s is *"P1-16, P4-10, P4-04"*. Nothing crosses.
**Owner split:** `M-11` owns `coveringCallID`; the two AO tasks own nothing on `MeetingModels` until
`M-11` lands, and each states which field it adds.

---

**C6 — `Sources/NextNotes/Meetings/MeetingScheduler.swift` (AO `P4-01` · DM `M-11`)**
`P4-01` adds the cached "Now" block; `M-11` rewrites `answer` `:358`, `callChanged` `:337`,
`stopFinishedMeeting` `:271-290`, `retire` `:417`. Both are live. `M-11`'s dependency line names no AO
task; `P4-01`'s is *"Phase 3 gate, P1-01, P0-18"*. Note `M-02` and `M-06` already read this file
(`shouldAutoRecord`, `callChanged`) and both are done, so the file has a third history.
**Owner split:** `M-11` first (its `answer`/`callChanged` hunks are behavioural and the ARM path is
where the AGENTS.md "one recording per real meeting" rule lives), `P4-01` second.

---

**C7 — `Sources/NextNotes/UI/Meetings/MeetingDetailView.swift` (AO `P4-05`, `P4-10` · DM `M-15`)**
`M-15` is *Speaker identification on by default once models exist; offered after the first multi-voice
meeting*, `Depends on` *"M-10, M-03"*. `P4-05` and `P4-10` are the post-meeting review surfaces. All
three add a section to the same detail view.
**Owner split:** AO owns the detail view for Phase 4; `M-15` lands after `P4-10` or takes a named
region from it.

---

**C8 — `Sources/NextNotes/UI/Island/IslandState.swift` (9 writers)**
AO `P0-23`✓, `P1-16`, `P3-09`, `P4-04`, `P4-13`, Phone-Calls `PH-11`; DM `D-02`✓, `D-03`✓, `M-06`✓.
The live pair is **`P3-09` and `PH-11`**. `P3-09` is *C10 island state owned by VoiceSession (workers
never drive it)* — it moves island state ownership. `PH-11` is *Call activity: the island's existing
`callQuestion` state, and the Activity row*, and it says *"The island already has the state …
Reuse it; do not add a call state"* — which is a direct statement that it will drive the state it
inherits. `PH-11`'s `Depends on` is *"PH-10"*, which names nothing in AO; `P3-09`'s is *"P3-06a, P3-03a;
lands after P3-03b"*.
**Owner split:** `P3-09` owns `IslandState.swift` outright; `PH-11` lands after it and adds its case
through whatever surface `P3-09` leaves, or is folded into `P3-09` as a case. Phone-Calls' own gate
(`G1`) is not closed, so this is not urgent — but it must be decided before `P3-09` starts, because
`P3-09` is the one that makes the ownership question real.

---

### 2.2 The 25 cross-roadmap `SERIALISE` rows, and the sentence that makes each one safe

These are **not** findings — they are confirmations that the coordination you suspected is already
written down. Listed so an orchestrator knows not to re-litigate them.

| File | Writers (cross-roadmap) | The sentence that resolves it |
|---|---|---|
| `Support/Usage/UsageRecord.swift` | AO `P6-07`; DM `D-01b` (evidence only) | DM `STATUS.md`:261 — *"Future AGENT-OVERHAUL P6-07 (optional `taskID` on `UsageRecord`) sequences AFTER all dictation-side usage work, per its own gating."* |
| `Support/Usage/UsageLogSelfTest.swift` | AO `P0-20a`✓, `P0-20b`✓, `P0-20c`✓, `P0-20e`✓, `P6-07`; DM `D-01b` | AO `STATUS.md`:317 — *"`UsageLogSelfTest.swift` is the single runner for every usage case (U/M/D/R/E); add cases, never a second marker."* DM `:261` names D2→P0-20c, D3→D-01b. |
| `Support/Usage/UsageLog.swift` | AO `P0-20a`✓; DM `D-01b`✓ | DM `STATUS.md`:319 — D-01b reuses P0-20c's `usage:` seam rather than adding a second closure. |
| `Core/DictationController.swift` | AO `P0-20c`✓; DM `D-01b`✓, `D-15c` | AO `STATUS.md`:311 — *"**`Core/DictationController.swift` ownership, resolved.** … One owner per call site: P0-20c's rows are frozen; D-01b adds the hold row; P6-07 adds the task id."* |
| `Meetings/CallPolicy.swift` | Phone-Calls `PH-09`, `PH-12`; DM `M-02`✓, `M-11` | `02-PHASE-1-V1.md`:425 — *"**Coordination is mandatory.** DM **M-11** … is `todo` and owns the question … **Do not edit `CallPolicy` while M-11 is in flight** — two answers to one question, and `CallPolicy` is shared."* Plus `00-README.md`:182 — *"Two files in V1 are actively owned by another workstream."* |
| `Meetings/CallDetector.swift` | Phone-Calls `PH-12`; DM `M-02`✓, `M-11` | same sentence, and `02-PHASE-1-V1.md`:430-431 states the split — *"M-11 answers: which detected calls SHOULD arm a meeting? / PH-12 answers: which calls Next placed itself must NEVER arm one?"* |
| `Support/Permissions.swift` | Phone-Calls `PH-05`; iMessage `IM-03`, `IM-04` | `02-PHASE-1-V1.md`:68 — *"if both need it, one row, one request"*; `02-PHASE-1-P0-SLICE.md`:101 — *"Do not add a second permissions row for Contacts — that is `Phone-Calls` PH-05 and one framework means one prompt."* |
| `Agent/RealtimeAgent.swift` | AO (26 tasks); iMessage `IM-11` | `03-PHASE-2-P1-SLICE.md`:63 — *"Do not refactor `RealtimeAgent` beyond the enum case. AGENT-OVERHAUL P3-01…P3-06 own that file's structure and a large change here collides with them."* |
| `Agent/ActionRuntime.swift`, `Agent/Permissions/PermissionBroker.swift` | AO `P3-02/04/08/09`, `P6-06`; iMessage `IM-12` | `03-PHASE-2-P1-SLICE.md`:7 — *"This phase edits existing files — `Agent/RealtimeAgent.swift`, `Agent/ActionRuntime.swift`, `Agent/Permissions/PermissionBroker.swift` — which AGENT-OVERHAUL is actively working. Coordinate per `00-README` §7's shared-files rule."* |
| `Agent/Duplex/TaskBridge.swift` | AO `P3-03`…`P3-09`; iMessage `IM-16` | `03-PHASE-2-P1-SLICE.md`:320 — *"**If P6 is not landed, this task is blocked** — do not build a parallel durability mechanism."* |
| `Transcription/ParakeetEngine.swift` | AO `P3-07`; DM `D-04`✓, `D-14` | DM ledger `D-14` `Depends on` — *"AO P0-06 (done), D-01b evidence, AO P0-20b (soft: **AO P3-07a**)"*. |
| `Formatting/LLM/FoundationModelLLMProvider.swift` | AO `P1-01`; DM `M-13` | Partly: DM `M-12`'s ledger records *"P1-10a step 0 landed here verbatim (both STATUS files; AO's table skips it)"*. The `P1-01`/`M-13` half is **not** covered — see C2. |
| `Meetings/NotesService.swift`, `ChunkedTranscriber.swift`, `DiarizationService.swift`, `NotesGenerator.swift` | AO `P0-20b`✓, `P3-07`; DM (all `done`) | No overlap remains: every DM writer on these four is `done`; the only live AO writer is `P3-07`. |
| `Core/AudioCaptureHub.swift` | AO `P2-08`; DM `D-02`✓ | `D-02` is done. |
| `Support/LatencyTrace.swift` | AO `P2-01`; DM `M-16a`✓ | `M-16a` is done. |
| `Support/SelfTestStoreGuard.swift` | AO `P0-11`✓, `P6-02`; iMessage `IM-07`, `IM-08` | Additive list; each task says *"add … in this commit"*. Merge the appends, never the edits. |
| `THIRD-PARTY-NOTICES.md` | AO `P2-04`, `P2-05`, `P0-16`✓; PH `PH-15`; IM `IM-05` (conditional) | Additive inventory; `IM-05`'s is conditional (*"Do not add a parsing dependency without … a `THIRD-PARTY-NOTICES.md` entry"*). |
| `Package.swift` | AO `P0-13`✓, `P0-16`✓(won't-do); PH `PH-15` | `PH-15` adds a SwiftPM target behind an off-by-default flag. No live AO writer. |

## 3. Recommended parallel plan

Derived from the matrix, not from the roadmaps' own `Depends on` claims. **153 of the 185 ledger ids
name at least one file**; the 32 that do not are the gates, spikes, reports and lettered subtasks
listed in §6.

A task is **clean** when *no other task in any of the five roadmaps writes any file it writes* — not
merely when its own roadmap says it is independent. That is a much smaller set than either roadmap
implies, and it is the honest answer to "what can run in parallel".

### Queue 1 — start now, no coordination needed (10 ids, all live)

| Roadmap | Tasks | Why each is free |
|---|---|---|
| Phone-Calls | `PH-06`, `PH-07`, `PH-13` | Every file is new under `Sources/NextNotes/Phone/`. `PH-06` writes four new files; `PH-07` writes one (`PhoneAgentTool.swift` + the manifest registration); `PH-13` writes the nonce/recovery half. **`PH-07` is in this queue and is still blocked** — not on a file, on `AO P1-03`: *"Blocked without P1-03 … Landing `phone.*` before it exists means two tool catalogues."* Its files are free; its start is not. |
| iMessage | `IM-06`, `IM-10`, `IM-13`, `IM-14`, `IM-15` | All five create files under `Sources/NextNotes/IMessage/`. `IM-13` is the one worth starting first: *"This is the mechanism `Phone-Calls` reuses. Build it once, generically."* `PH-08` needs it. |
| AGENT-OVERHAUL | `P5-02`, `P5-03` | `P5-02` and `P5-03` write only new `Agent/CloudFrontend/*` files. They are gated on `P5-01` and `P5-04`, not on a file. |

Every one of these ten is still behind a **gate** rather than a file (§3 Queue 3), so the queue is
"no coordination needed", not "start today". The two that are genuinely unblocked by anything are
`PH-02` and `PH-03` (below).

**Two tasks worth starting today regardless of the matrix.**
`PH-02` (the DriverKit entitlement request) names no source file at all, so it does not appear
anywhere in this document — and `01-PHASE-0-GATES.md`:138 says to start it *"before PH-01 closes, not
after"*, because the answer may take months. `PH-03` (a Developer ID and a notarization path) writes
only `AGENTS.md` per its own Files line, which is a registry batch (§4.3), and it is *"worth doing even
if V2 is abandoned"*. Both are shared work with the app's release, not with either live roadmap.

### Queue 2 — start now, a named owner decided first (97 ids live)

Every one of these has a documented coordination, or a single obvious owner. The work can proceed
**alongside** another task; what must be decided first is *who writes which file*.

**2a. Registry-batch only — hand your registrations to the orchestrator (all four roadmaps).**
`NextNotes-iMessage/00-README.md`:157 and `Phone-Calls/00-README.md`:178-180 already say it: *"A
sub-agent adds the flag's registration to its task's instructions and does not edit those three files
itself."* Applies to every task that registers a `--selftest-*` flag — all of AO Phase 1–6, all of DM
Phase C/D, all of IM Phase 1–2, all of PH Phase 1–2. See §4 for the batch list.

**2b. An owner is already named. Proceed.**

| Task | Owner of the contested file | Anchor |
|---|---|---|
| `PH-09` | DM `M-11` owns `Meetings/CallPolicy.swift` | `PH-09` only writes the marker; *"PH-12 wires the other side"* |
| `PH-12` | DM `M-11` | `02-PHASE-1-V1.md`:425 + PH `STATUS.md`: *"PH-12 blocked on DM M-11"* |
| `PH-16` | Phone-Calls (`PH-05` created the section file) | one new file, no shared surface |
| `PH-21`, `IM-16` | AO Phase 6 owns `TaskStore` / `TaskBridge` | *"do not build durability here"*; `IM-16` blocked outright if P6 is not landed |
| `IM-11` | AO owns `RealtimeAgent.swift`; `IM-11` adds one enum case at `:4-8` | *"Do not refactor `RealtimeAgent` beyond the enum case."* One case, one line — but it needs a quiet file, and there are 26 AO writers. |
| `IM-12` | AO owns `ActionRuntime` / `PermissionBroker` structure | `03-PHASE-2-P1-SLICE.md`:7 names both files as shared |
| `IM-03` | one Permissions row, shared with `PH-05` | §2.2 |
| `M-16c` | DM (writes only `MeetingSession.swift`, with `M-01`/`M-08`/`M-09`/`M-16a` — all done) | `Depends on: M-08` |
| `D-14` | AO `P3-07a` (soft) | already in `D-14`'s own `Depends on` line |
| `P0-10` | nothing — it is `blocked` on a warm EOU model, which is `P2-07`/`P2-04`'s to fix | AO `STATUS.md` BLOCKED note |

**2c. Needs an owner decision before it starts — the eight collisions, 22 live tasks.**
`P1-05` vs `M-13` (C2) · `P1-01` vs `M-13` (C2) · `P4-04`/`P4-05`/`P4-06`/`P4-09`/`P4-13`/`P5-01` vs
`D-15a`/`M-14`/`M-15` (C1) · `P4-04`/`P4-10`/`P4-13` vs `M-14` (C4) · `P4-10`/`P4-13` vs `M-11` (C5) ·
`P4-01` vs `M-11` (C6) · `P4-05`/`P4-10` vs `M-15` (C7) · `P1-16`/`P3-09`/`P4-04`/`P4-13` vs `PH-11` (C8) ·
`IM-04`/`IM-17` vs `PH-05` and AO's three (C3). Each decision is one line, and §2.1 proposes one.

Note that `M-01`, `M-02`, `M-06`, `M-10`, `P0-14`, `P0-17`, `P0-19`, `P0-20a`, `P0-20b`, `P0-21`,
`P0-23`, `D-02` and `D-03` all appear in the collision graph **only because they are `done`**. They
are not work in flight; they are the history on the file. Every collision above is between tasks that
are both `todo`.

### Queue 3 — blocked

| Blocker | Tasks | Why |
|---|---|---|
| **A human, an iPhone, Full Disk Access** | `IM-01`, `IM-02`, `IM-03` — and therefore **all** of `IM-04`…`IM-17` | `NextNotes-iMessage/STATUS.md`: *"The folder moves to `roadmap/in-progress/` when the gate row closes. Until then no Phase 1 task may be scheduled."* Ten of the iMessage tasks are in Queue 1 and Queue 2 on files and are **still blocked by the folder rule**. `G1` decides `IM-07`'s filter, `G2` whether V1 is possible, `G3` whether `IM-09` is shippable. |
| **A human, an iPhone, Contacts** | `PH-01`, and therefore all of `PH-05`…`PH-13` | `02-PHASE-1-V1.md`:6 — *"Do not start any of it until G1 (PH-01) has closed."* Three of the ten Queue-1 tasks are in this set. |
| **Apple, a developer account, a lawyer** | `PH-14`…`PH-21` | `01-PHASE-0-GATES.md`:46 — *"Any one of G1–G4 failing ends V2."* `G4` is *"not closable by an agent."* |
| **`AO P6-07`** | `IM-16`, `PH-21` | `03-PHASE-2-P1-SLICE.md`:320 — *"**If P6 is not landed, this task is blocked** — do not build a parallel durability mechanism, and do not hand-roll 'resend on wake'."* |
| **`AO P1-03`** | `PH-07` | `02-PHASE-1-V1.md`:166 — *"Blocked without P1-03 … Write the `BLOCKED` note and wait."* |
| **DM `M-11`** | `PH-12` | already recorded in PH's `STATUS.md` as an expected first `BLOCKED` entry |
| **`AO P1-01`** | 11 of the 18 Phase 1 tasks | Phase 1's eval; `P1-01` itself has *"none to write"* but the roadmap orders Phase 1 from it |
| **`AO P2-04` / `P2-07`** | `P0-10` | `P0-10`'s BLOCKED note: the streaming EOU head confirms after the VAD fallback has already committed |
| **`AO P5-01`, `P5-04`** | `P5-02`, `P5-03` | both in Queue 1, both gated on the seam existing first |

## 4. Registry contention

Three files are single-writer by rule, in both new roadmaps' own words:

> `NextNotesApp.swift`, `Scripts/acceptance.sh` and `AGENTS.md` are **single-writer**: the
> orchestrator batches the registrations. — `NextNotes-iMessage/00-README.md` §7, restated at
> `Phone-Calls/00-README.md` §8

`README.md` and `Support/SelfTestStoreGuard.swift` are a fourth and fifth in practice (a `README.md`
tree line per new file, a `SelfTestStoreGuard.fileNames` entry per new store) although no roadmap
calls them single-writer.

### 4.1 `Sources/NextNotes/NextNotesApp.swift` — 57 writers

| Roadmap | Tasks |
|---|---|
| AGENT-OVERHAUL (34) | `P0-02`, `P0-03`, `P0-04`, `P0-11`, `P0-13`, `P0-14`, `P0-18`, `P0-19`, `P0-20a`, `P0-20d`, `P0-23`, `P1-01`, `P1-03`, `P1-05`, `P1-09`, `P1-16`, `P2-01`, `P2-04`, `P2-05`, `P2-06`, `P2-07`, `P3-02`, `P3-03`, `P3-06`, `P3-07`, `P3-09`, `P3-10`, `P4-01`, `P4-02`, `P4-04`, `P4-10`, `P5-04`, `P6-01`, `P6-08` |
| DICTATION-MEETINGS (23) | `D-01b`, `D-02`, `D-03`, `D-04`, `D-05`, `D-06`, `D-10`, `D-12`, `D-13`, `D-15a`, `D-15c`, `M-01`, `M-02`, `M-03`, `M-04`, `M-05`, `M-06`, `M-07`, `M-08`, `M-09`, `M-11`, `M-13`, `M-16a` |
| iMessage | *not stated* — 12 of the 18 register a flag by name in *Verify* (`--selftest-imessage-db`, `-decode`, `-watch`, `-loop`, `-pairing`, `-approval`, `-attachment`, `-privacy`, `-recovery`) and `IM-12` says *"if you add a flag, register it"*, but no iMessage task names the file |
| Phone-Calls | *not stated* — 6 flags named in the ledger's exit row (`PHONE_READINESS_OK`, `PHONE_CONTACT_OK`, `PHONE_PREPARE_OK`, `PHONE_POLICY_OK`, `PHONE_RECEIPT_OK`, `PHONE_MEETING_OK`) plus the six `CALL_*` flags; no task names the file |

**`AGENT-OVERHAUL` P6's five flags are not registered at all** — `STATUS.md`:293-297: *"`--selftest-task-durability`,
`--selftest-task-recovery`, `--selftest-task-retry`, `--selftest-task-graph`, `--jobs-report` are **not
registered yet**; register them when those tasks run (one block in `NextNotesApp.swift`, one AGENTS.md
line, one tier line each)."* That is a planned batch, not a conflict.

This file has a documented failure history, which is why it is worth the rule: DM `STATUS.md` records
**eleven** separate incidents of one task's hunks being swept into another's commit
(`D-01b`: *"`NextNotesApp.swift` also carried M-09's uncommitted registry + runner hunks; only this
task's 28 of 30 hunks were staged"*; `D-05`: *"Never `git commit <path>` on a file parallel agents are
editing"*; `M-08`: *"the shared tree carried two other workstreams' uncommitted hunks in
`NextNotesApp.swift`, `AGENTS.md` and `Scripts/acceptance.sh`"*).

### 4.2 `Scripts/acceptance.sh` — 36 writers

| Roadmap | Tasks |
|---|---|
| AGENT-OVERHAUL (25) | `P0-04`, `P0-11`, `P0-13`, `P0-14`, `P0-18`, `P0-19`, `P0-20a`, `P0-20e`, `P1-01`, `P1-03`, `P1-05`, `P2-01`, `P2-04`, `P2-05`, `P2-06`, `P3-02`, `P3-06`, `P3-07`, `P3-10`, `P4-01`, `P4-04`, `P4-10`, `P5-04`, `P6-01`, `P6-08` |
| DICTATION-MEETINGS (11) | `D-15a`, `M-01`, `M-03`, `M-04`, `M-05`, `M-07`, `M-08`, `M-09`, `M-10`, `M-13`, `M-16a` |
| iMessage | *not stated* — the exit rows name CORE/INTEGRATION flags, and `IM-17` says *"extend `--selftest-ui-strings`"*; the tier lines themselves are unstated |
| Phone-Calls | *not stated* — same shape |

Currently uncommitted: `git diff --numstat` reports **+7/−0** on this file.

### 4.3 `AGENTS.md` — 74 writers, and the paragraph that must survive

| Roadmap | Tasks |
|---|---|
| AGENT-OVERHAUL (53) | `P0-04`, `P0-11`, **`P0-12`**, `P0-13`, `P0-14`, `P0-18`, `P0-19`, `P0-20a`, `P0-20c`, `P0-20d`, `P0-20e`, `P0-21`, `P0-23`, `P1-01`, `P1-03`, `P1-05`, `P1-07`, `P1-11`, `P1-13`, `P1-14`, `P1-15`, `P1-16`, `P1-18`, `P2-01`…`P2-08`, `P3-01`…`P3-10`, `P4-01`…`P4-04`, `P4-09`, `P4-10`, `P4-11`, `P5-04`, `P6-01`, `P6-05`, `P6-08`, `P6-09` |
| DICTATION-MEETINGS (18) | `D-01b`, `D-02`, `D-10`, `D-11`, `D-13`, `D-15a`, `M-01`…`M-05`, `M-07`…`M-11`, `M-13`, `M-16a` |
| iMessage (1) | `IM-17` — *"copy this into `AGENTS.md` under 'What has never run, on macOS' and leave it there"* |
| Phone-Calls (2) | `PH-03`, `PH-21` — `PH-03` cites it as the source of the two OpenSSL traps; `PH-21` copies its never-run list |

**On the uncommitted change — confirmed, and larger than the one paragraph.**
`git diff --numstat -- AGENTS.md` reports **+86/−1 across 6 hunks**. The paragraph you mean is one of
them: hunk `@@ -306,0 +370,15 @@` adds the 15-line invariant *"There is one task ledger, one channel
that starts audio, one tool manifest, and one usage log"* at line 370. It is **not in `HEAD`**:

```
$ grep -n "There is one task ledger" AGENTS.md        → 370
$ git show HEAD:AGENTS.md | grep -n "…"               → (no match)
```

The other five hunks are other workstreams' flag-list and `usage.jsonl` additions
(`--selftest-diarize-hints`, `--selftest-toolloop-live`, the `usage.jsonl` paragraph,
`--selftest-recovery`/`--selftest-usage-log`).

**One correction to the premise, because it changes who owns the risk.** `P0-12` is `done`, committed
`c0c5c41` on 2026-09-24 — it will not run again, and its own row records that it *"preserved"* this
paragraph. `AGENT-OVERHAUL STATUS.md`:307-310 says the same: *"P0-12 preserved it (it is at line 307);
**do not reset it** — the editor may commit it separately so the diff is visible."* Both new roadmaps
repeat the instruction (`NextNotes-iMessage 00-README` §7, `Phone-Calls 00-README` §8: *"`AGENTS.md`
also has an uncommitted change from 2026-09-25 that AGENT-OVERHAUL's P0-12 owns; do not reset it."*).
So the risk is not P0-12's diff — it is **the next commit that touches `AGENTS.md` sweeping all 86
lines in**. That is a registry-batch hazard like any other, and it is why §4.1's staging rule matters
here too.

### 4.4 `README.md` (9) and `Support/SelfTestStoreGuard.swift` (4)

`README.md`: AO `P3-02`, `P3-03`, `P3-04`, `P3-06`…`P3-10` (a tree line per new file) + DM `M-01`.
`SelfTestStoreGuard.swift`: AO `P0-11`✓, `P6-02`; iMessage `IM-07`, `IM-08` — each adds one
`fileNames` entry and each says so in its own commit. Both are append-only in practice; batch the
appends and never let two commits edit the same array literal.

## 5. Defects found in the roadmaps

Reported, not fixed.

1. **`IM-04a` is in the ledger and has no task text.** `NextNotes-iMessage/STATUS.md`:58 and
   `00-README.md`:219, 248, 299 all carry it; **no phase file has a section for it.** Worse,
   `IM-04`'s Files line still contains the two rows the ledger moved to it —
   `` `Sources/NextNotes/Support/Permissions.swift` — one new row `` and
   `` `Sources/NextNotes/UI/Settings/AgentSettingsTab.swift` — one line for a `MessagesAccessSection` ``.
   So the Permissions row is currently claimed by both `IM-04` and `IM-04a`, and `IM-04a` has nothing
   to build. The matrix credits the row to `IM-04` because that is the only text that exists.
2. **`IM-04`'s ledger row and its task text disagree on `Depends on`.** Ledger: *"**none** (split
   2026-09-25 — see below)"*. `02-PHASE-1-P0-SLICE.md`:18: *"**Depends on:** IM-03"*. An executor
   reading either one gets a different answer.
3. **D-01c does not exist.** The three-way you asked about names `D-01b / D-01c`. DM `STATUS.md`:261
   says so explicitly: *"Note: the question named a 'D-01c' — no such ID exists here; the
   injected-failures scope it described is D-15c (todo)."* **`D-15c` is the third party**, and it writes
   `Core/DictationController.swift` and `NextNotesApp.swift`. The three-way is real and it is
   `P0-20c` / `D-01b` / `D-15c` — with `P6-07` a fourth on `UsageRecord.swift` specifically.
4. **14 lettered AGENT-OVERHAUL subtasks have ledger rows and no task section.** `P0-14b`, `P1-10a`,
   `P1-10b`, `P2-03b`, `P3-03a/b`, `P3-04a/b`, `P3-06a/b`, `P3-07a/b/c/d` exist only as *steps* inside
   their parent's section (e.g. `*P1-10a — result cap and context budget*` at
   `02-PHASE-1-TOOLS.md`:3136). Their `Depends on` lines therefore cannot be checked against a file
   list of their own, and the matrix inherits the parent's list. This matters because **DM names two
   of them as coordination targets**: `M-12` claims *"AO P1-10a step 0"* and `M-14` says *"coordinate AO
   P3-07a"*.
5. **`M-12` landed a piece of `P1-10a` and AO's table does not know.** DM `STATUS.md` (M-12 row):
   *"P1-10a step 0 landed here verbatim (both STATUS files; AO's table skips it)"* — DM documents the
   gap in its own ledger; **AO `STATUS.md`'s `P1-10a` row still reads `Depends on: P1-01` and
   `todo`.** One-sided coordination.
6. **`P6-07`'s dependency line omits the dictation half it sequences after.** `P6-07` `Depends on` is
   *"P6-06, P0-20e"*. The sequencing exists only in DM's ledger (`STATUS.md`:261). `P6-07` also writes
   `UsageRecord.swift`, which `D-01b` touched (DM `STATUS.md`:325), and that link is in neither ledger.
7. **A file-list path that does not exist.** `07-PHASE-6-DURABLE-JOBS.md`:856 names
   `` `Sources/NextNotes/Agent/Agent/RealtimeAgent+ToolLoop.swift` `` — a doubled `Agent/`. The real
   path is `Sources/NextNotes/Agent/RealtimeAgent+ToolLoop.swift`. Normalised here, but it will fail a
   `grep` in P6-09's own step.
8. **`PH-07` needs a change in a file neither it nor `P1-03` claims.**
   `Agent/FunctionCalling/FunctionCallRelevance.swift:177` has `consequentialIDs` as
   `private static let`, and `PH-07` needs a public accessor: *"**Ask for it once, in P1-03, and share
   it** — do not add a second grading."* **`P1-03`'s Files line does not list that file**, and `PH-07`'s
   Files line is one entry (`PhoneAgentTool.swift` + the manifest registration). Neither roadmaps'
   ledgers mention it. It is the one place where the roadmaps agree on the answer and disagree on who
   writes it — the same shape as C2.
9. **Two `Settings.swift` / permissions collisions are named only in prose, never in a ledger
   `Depends on`.** `Support/Permissions.swift` and `UI/Settings/AgentSettingsTab.swift` appear in
   `Phone-Calls/00-README.md`:182 (*"shared with the iMessage folder"*) and in `PH-05`/`IM-04`'s prose,
   but in **no** `Depends on` cell in any of the four ledgers. The coordination exists; it is just not
   where a scheduler would find it. See C3.
10. **The memory-lifecycle roadmap has no `STATUS.md`, no task ids and no `Files` lines.** It is
    sequenced behind `P4-07a` in prose (*"Nothing in §2 or §3 may start before it is `done`"*) and it
    names `Memory/NextMemory.swift`, `Knowledge/KnowledgeStore.swift` (§3.3 — *"tables in the existing
    store, not a new file"*) and `AgentSettingsTab.swift` (§5), all of which collide with live work.
    It is in the matrix under its own section numbers. It cannot be scheduled from as written.

## 6. What could not be determined

- **The iMessage and Phone-Calls registry lines are not stated.** Twelve `IM-*` and six `PH-*` tasks
  register a `--selftest-*` flag by name in *Verify* without naming `NextNotesApp.swift` or
  `Scripts/acceptance.sh`. I did not infer the registrations; §4.1/§4.2 mark them *not stated* and the
  queues treat them as registry-batch work.
- **Bare type names are not paths.** `PH-09` says *"`CallPolicy` consults that marker"* without a path;
  I counted `PH-09` as a writer of `Meetings/CallPolicy.swift` on the strength of PH's own `00-README`
  §8, which names the file, but the task text does not. Same for `M-16c` (`MeetingSession.swift`) and
  `IM-15`'s voice-note file, which the roadmap never names at all.
- **`IM-04a`'s file list does not exist**, so its row in §2.1 C3 and the `Support/Permissions.swift`
  row are inferred from `IM-04`'s Files line plus `00-README.md`:299. Not a guess about intent, but
  the ledger and the phase file disagree and I could not tell which is current.
- **32 of 185 ledger ids name no file at all** and are absent from the matrix:
  **AGENT-OVERHAUL (15)** `P0-01` (its own line reads *"none in source"*), the 14 lettered subtasks
  `P0-14b`, `P1-10a`, `P1-10b`, `P2-03b`, `P3-03a/b`, `P3-04a/b`, `P3-06a/b`, `P3-07a/b/c/d`;
  **DICTATION-MEETINGS (5)** `D-01`, `D-15`, `M-16` (parents whose ledger cells say *"see subtasks"*),
  `M-16b` (*done*; its scope was absorbed by `P0-20b`, per its own evidence), `D-16` (a spike:
  *"**Files you will change:** none in `Sources/`"*);
  **iMessage (3)** `IM-01`, `IM-02`, `IM-04a` (the last is defect 1 in §5 — it has no task text at all);
  **Phone-Calls (9)** `PH-01`, `PH-02`, `PH-04`, `PH-10`, `PH-14`, `PH-17`, `PH-18`, `PH-19`, `PH-20` —
  Phase 0's gates and every V2 task, none of which has a *Files* line.
- **`P0-20` is a parent** superseded by `P0-20a`–`e`, which each carry their own list. It appears in
  the matrix only through the `Core/DictationController.swift` and `Support/MetricsStore.swift` paths
  its own body names, and it should be read as a pointer to its five children, not as a task.
- **I did not attempt to resolve the 118 within-roadmap `SERIALISE` rows to an order.** They are
  governed by each roadmap's own phase gates and `Depends on` chain, which is the roadmap's job and
  not a collision between workstreams. Listing them is enough for a cross-workstream orchestrator.

## 7. The matrix

444 rows. Verdict counts: **258 `SAFE` · 31 `SHARED-READ` · 143 `SERIALISE` · 12 `COLLISION`.**
A task id in a writing column means that task's own *Files you will change* line, or a file named in
its Steps with a write verb, names that path. A task id in the read-only column means the path appears
only in a **Read for context (do not change)** line, or under a **Do not** — it is not a conflict.

| File (repo-root relative) | AGENT-OVERHAUL | DICTATION-MEETINGS | iMessage | Phone-Calls | memory-lifecycle | read-only (named in a *Read for context* line) | Verdict |
|---|---|---|---|---|---|---|---|
| `AGENTS.md` | P0-04, P0-11, P0-12, P0-13, P0-14, P0-18, P0-19, P0-20a, P0-20c, P0-20d, P0-20e, P0-21, P0-23, P1-01, P1-03, P1-05, P1-07, P1-11, P1-13, P1-14, P1-15, P1-16, P1-18, P2-01, P2-02, P2-03, P2-04, P2-05, P2-06, P2-07, P2-08, P3-01, P3-02, P3-03, P3-04, P3-05, P3-06, P3-07, P3-08, P3-09, P3-10, P4-01, P4-02, P4-03, P4-04, P4-09, P4-10, P4-11, P5-04, P6-01, P6-05, P6-08, P6-09 | D-01b, D-02, D-10, D-11, D-13, D-15a, M-01, M-02, M-03, M-04, M-05, M-07, M-08, M-09, M-10, M-11, M-13, M-16a | IM-17 | PH-03, PH-21 | — | D-03, D-10, D-11, D-12, D-15a, D-15b, D-16, M-02, M-04, M-05, M-06, M-08, M-09, M-11, P0-20b, P0-20c, P0-20d, P0-21, P1-06, P1-09, P1-16, P2-07, P3-06, P3-07, P3-08, P3-09, P3-10, P4-10, P4-13, P6-04, P6-05, P6-06, P6-08 | SERIALISE |
| `Makefile` | — | — | — | PH-15 | — | — | SAFE |
| `Package.swift` | P0-13, P0-16 | — | — | PH-15 | — | — | SERIALISE |
| `README.md` | P3-02, P3-03, P3-04, P3-06, P3-07, P3-08, P3-09, P3-10 | M-01 | — | — | — | — | SERIALISE |
| `Resources/agent-persona-base.md` | P4-03 | — | — | — | — | — | SAFE |
| `Scripts/acceptance.sh` | P0-04, P0-11, P0-13, P0-14, P0-18, P0-19, P0-20a, P0-20e, P1-01, P1-03, P1-05, P2-01, P2-04, P2-05, P2-06, P3-02, P3-06, P3-07, P3-10, P4-01, P4-04, P4-10, P5-04, P6-01, P6-08 | D-15a, M-01, M-03, M-04, M-05, M-07, M-08, M-09, M-10, M-13, M-16a | — | — | — | — | SERIALISE |
| `Scripts/cleanup-selftest-rows.py` | P0-11 | — | — | — | — | — | SAFE |
| `Scripts/gen-llama-architectures.sh` | P0-13, P0-16 | — | — | — | — | — | SERIALISE |
| `Scripts/make-voice-fixtures.sh` | P2-01 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/01-PHASE-0-MAKE-IT-ANSWER.md` | P3-10 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Activation/ActivationController.swift` | P2-07, P3-09, P3-10 | — | — | — | — | P0-06 | SERIALISE |
| `Sources/NextNotes/Activation/AgentCaptureController.swift` | P0-10, P0-23, P1-15, P2-01, P2-02, P2-03, P2-04, P2-05, P2-07, P2-08, P3-01, P3-03, P3-04, P3-06, P3-08, P3-09, P3-10 | — | — | — | — | P0-23, P1-14, P1-15, P2-01, P5-01 | SERIALISE |
| `Sources/NextNotes/Activation/LocalVoiceTurnDetector.swift` | P2-03, P2-04, P2-07 | — | — | — | — | — | SERIALISE |
| `Sources/NextNotes/Activation/SmartTurn/SmartTurnArbiter.swift` | P2-04 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Activation/SmartTurn/SmartTurnModel.swift` | P2-04 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Activation/SmartTurn/SmartTurnModels.swift` | P2-04 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Activation/SmartTurn/SmartTurnSelfTest.swift` | P2-04 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Activation/SpokenApproval.swift` | P3-08 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Activation/VoiceTurnPolicy.swift` | P1-07, P1-15, P3-03, P4-02 | — | — | — | — | P1-02, P1-07, P4-06 | SERIALISE |
| `Sources/NextNotes/Activation/WakeWord/WakeWordAudioMonitor.swift` | P3-10 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Activation/agent-tasks.json` | P3-01 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/ACPConfirmation.swift` | P0-08 | — | — | — | — | P3-03, P3-08 | SHARED-READ |
| `Sources/NextNotes/Agent/AcousticEchoProcessor.swift` | P2-05, P2-08 | — | — | — | — | P2-05 | SERIALISE |
| `Sources/NextNotes/Agent/ActionRuntime.swift` | P3-02, P3-04, P3-08, P3-09, P6-06 | — | IM-12 | — | — | IM-10, P0-07, P3-02, P3-08, P4-13, P6-04, P6-06 | SERIALISE |
| `Sources/NextNotes/Agent/Activity/AgentActivityProjector.swift` | P6-08 | — | — | — | — | P1-06, P3-03, P6-08 | SHARED-READ |
| `Sources/NextNotes/Agent/Activity/AgentActivityStore.swift` | P3-03, P3-09, P6-03 | — | — | — | — | P3-03, P3-09, P6-03 | SERIALISE |
| `Sources/NextNotes/Agent/Agent/RealtimeAgent+ToolLoop.swift` | P6-09 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/AgentAnswerBudget.swift` | P0-05, P4-04 | — | — | — | — | P0-20a, P1-18, P4-08, P4-10 | SERIALISE |
| `Sources/NextNotes/Agent/AgentAnswersSelfTest.swift` | P0-14, P0-18 | — | — | — | — | — | SERIALISE |
| `Sources/NextNotes/Agent/AgentCapabilityManifest.swift` | P1-03, P1-09 | — | — | — | — | — | SERIALISE |
| `Sources/NextNotes/Agent/AgentCapabilityManifestSelfTest.swift` | P1-03 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/AgentDirectIntent.swift` | P1-07, P1-08, P1-13 | — | — | — | — | P1-02, P1-08, P2-03 | SERIALISE |
| `Sources/NextNotes/Agent/AgentHistoryBudget.swift` | P1-18 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/AgentModels.swift` | P1-04, P3-08 | — | — | — | — | P0-07, P3-08, P6-06 | SERIALISE |
| `Sources/NextNotes/Agent/AgentPrompts.swift` | P4-03, P4-10 | — | — | — | — | — | SERIALISE |
| `Sources/NextNotes/Agent/AgentRefusalGuard.swift` | P1-03, P1-09 | — | — | — | — | P1-07, P1-11, P4-02, P4-03 | SERIALISE |
| `Sources/NextNotes/Agent/AgentReplyRenderer.swift` | P1-10 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/AgentService.swift` | P0-20b, P4-04, P4-10, P4-13 | M-14 | — | — | — | P4-13 | COLLISION |
| `Sources/NextNotes/Agent/AgentSessionBoundary.swift` | P1-18 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/AgentSessionSelfTest.swift` | P1-18 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/AgentToolCall.swift` | P1-04 | — | — | — | — | P0-04 | SHARED-READ |
| `Sources/NextNotes/Agent/AgentToolLoop.swift` | P1-04, P1-10 | — | — | — | — | P1-04 | SERIALISE |
| `Sources/NextNotes/Agent/AgentTurnIntent.swift` | P1-08 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/Backend/ACPAgentBackend.swift` | P0-20a, P3-09 | — | — | — | — | — | SERIALISE |
| `Sources/NextNotes/Agent/Backend/CodexComputerUse.swift` | P0-20a, P1-12 | — | — | — | — | P1-01, P1-10, P1-12 | SERIALISE |
| `Sources/NextNotes/Agent/Backend/CodexQuotaStore.swift` | P1-12 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/CloudFrontend/CloudFrontendCapabilities.swift` | P5-01 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/CloudFrontend/CloudFrontendPolicy.swift` | P5-01 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/CloudFrontend/CloudRealtimeTransport.swift` | P5-01 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/CloudFrontend/CloudStreamSpeechBacking.swift` | P5-01 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/CloudFrontend/GeminiLiveFrontend.swift` | P5-03 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/CloudFrontend/GeminiLiveMessages.swift` | P5-03 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/CloudFrontend/GeminiLiveModels.swift` | P5-03 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/CloudFrontend/OpenAIRealtimeEvents.swift` | P5-02 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/CloudFrontend/OpenAIRealtimeFrontend.swift` | P5-02 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/CloudFrontend/RealtimeCloudFixtureServer.swift` | P5-04 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/CloudFrontend/RealtimeCloudKeyStore.swift` | P5-01 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/CloudFrontend/RealtimeCloudSelfTest.swift` | P5-04 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/CloudFrontend/RealtimePCMConverter.swift` | P5-01 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/ConcurrentVoiceSelfTest.swift` | P0-06, P0-07, P3-04 | — | — | — | — | P3-01, P3-02 | SERIALISE |
| `Sources/NextNotes/Agent/Duplex/AgentDeliveryPrompts.swift` | P3-04 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/Duplex/FrontendResponder.swift` | P3-05, P3-07, P3-08, P3-10, P5-01 | — | — | — | — | — | SERIALISE |
| `Sources/NextNotes/Agent/Duplex/IslandOwnership.swift` | P3-09 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/Duplex/LocalToolLoopWorker.swift` | P3-07 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/Duplex/OutputScheduler.swift` | P3-04, P3-08 | — | — | — | — | — | SERIALISE |
| `Sources/NextNotes/Agent/Duplex/SpokenApproval.swift` | P3-08 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/Duplex/TaskBridge.swift` | P3-03, P3-04, P3-05, P3-07, P3-08, P3-09 | — | IM-16 | — | — | — | SERIALISE |
| `Sources/NextNotes/Agent/Duplex/TaskStatusRenderer.swift` | P3-03, P3-08 | — | — | — | — | — | SERIALISE |
| `Sources/NextNotes/Agent/Duplex/VoiceContracts.swift` | P2-05, P3-06, P3-10, P5-01 | — | — | — | — | — | SERIALISE |
| `Sources/NextNotes/Agent/Duplex/VoiceDuplexWorkSelfTest.swift` | P3-02, P3-09 | — | — | — | — | — | SERIALISE |
| `Sources/NextNotes/Agent/Duplex/VoiceOverlapSelfTest.swift` | P3-07 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/Duplex/VoiceSession.swift` | P3-06, P3-09, P5-01 | — | — | — | — | — | SERIALISE |
| `Sources/NextNotes/Agent/Duplex/VoiceSessionReducerSelfTest.swift` | P3-06 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/Duplex/agent-tasks.json` | P3-03, P3-08 | — | — | — | — | — | SERIALISE |
| `Sources/NextNotes/Agent/FunctionCalling/FunctionCallStore.swift` | P4-13 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/FunctionCalling/FunctionCallWatcher.swift` | P0-20b, P4-13 | — | — | — | — | P1-16 | SERIALISE |
| `Sources/NextNotes/Agent/GoogleWorkspaceCLI.swift` | P1-09, P4-13 | — | — | — | — | P1-04 | SERIALISE |
| `Sources/NextNotes/Agent/IMessage/RemotePreparedAction.swift` | — | — | IM-13 | — | — | — | SAFE |
| `Sources/NextNotes/Agent/Identity/AgentAvatarSelfTest.swift` | P3-09 | — | — | — | — | P3-09 | SHARED-READ |
| `Sources/NextNotes/Agent/Identity/AgentAvatarState.swift` | P4-04 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/LLMProviderTools.swift` | P1-05 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/LiveEval/ToolLoopLiveEval.swift` | P1-01 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/LiveEval/ToolLoopLiveEvalCases.swift` | P1-01, P3-05 | — | — | — | — | — | SERIALISE |
| `Sources/NextNotes/Agent/LiveEval/ToolLoopLiveEvalFixtures.swift` | P1-01 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/LiveEval/ToolLoopLiveEvalGrader.swift` | P1-01, P1-11 | — | — | — | — | — | SERIALISE |
| `Sources/NextNotes/Agent/MeetingAgent.swift` | P0-20b, P4-10 | — | — | — | — | P1-04, P1-10, P1-17, P4-05 | SERIALISE |
| `Sources/NextNotes/Agent/MeetingAgentFitSelfTest.swift` | P4-10 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/MeetingEvidenceMatcher.swift` | P4-10 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/MeetingTranscriptWindows.swift` | P4-10 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/PendingAction.swift` | P1-02, P1-07 | — | — | — | — | P4-06 | SERIALISE |
| `Sources/NextNotes/Agent/Permissions/FirstIngestionGate.swift` | P4-13 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/Permissions/PermissionBroker.swift` | P3-08 | — | IM-12 | — | — | — | SERIALISE |
| `Sources/NextNotes/Agent/Permissions/PermissionGate.swift` | P1-16, P3-08 | — | — | — | — | P3-08, P4-01 | SERIALISE |
| `Sources/NextNotes/Agent/Permissions/STATUS.md` | P4-13 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/Permissions/ToolCallReview.swift` | P3-08 | — | — | — | — | P3-08 | SHARED-READ |
| `Sources/NextNotes/Agent/Permissions/first-ingestion.json` | P4-13 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/Permissions/function-calling.json` | P4-13 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/Planner/AgentPlannerBackend.swift` | P1-05 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/Planner/FoundationModelsToolPlanner.swift` | P1-05 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/Planner/LlamaGrammarPlanner.swift` | P1-05 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/Planner/NativeToolsSelfTest.swift` | P1-05 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/Planner/OpenAIToolsPlanner.swift` | P1-05 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/Planner/PromptConventionPlanner.swift` | P1-05 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/Planner/ToolStepRunner.swift` | P1-05 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/PlannerTraceEvent.swift` | P1-01 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/Proactive/MeetingSuggestionStore.swift` | P4-05 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/Proactive/OwedItems.swift` | P4-04, P4-05 | — | — | — | — | — | SERIALISE |
| `Sources/NextNotes/Agent/Proactive/ProactiveBrief.swift` | P4-04 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/Proactive/ProactiveLedger.swift` | P4-04 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/Proactive/ProactiveOffers.swift` | P4-06 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/Proactive/ProactiveSelfTest.swift` | P4-04, P4-05, P4-06, P4-13 | — | — | — | — | — | SERIALISE |
| `Sources/NextNotes/Agent/Proactive/ProactiveService.swift` | P4-04, P4-05, P4-06 | — | — | — | — | — | SERIALISE |
| `Sources/NextNotes/Agent/Proactive/ProactiveSink.swift` | P4-04 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/Proactive/notes.md` | P4-05 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/Proactive/proactive-ledger.json` | P4-04 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/RealtimeAgent+ToolLoop.swift` | P0-04, P0-05, P0-07, P0-08, P0-14, P0-17, P0-20a, P0-22, P1-01, P1-02, P1-03, P1-04, P1-05, P1-06, P1-08, P1-10, P1-11, P1-12, P1-17, P1-18, P2-01, P3-02, P3-04, P3-06, P3-07, P4-01, P4-03, P4-09 | — | — | — | — | P6-09 | SERIALISE |
| `Sources/NextNotes/Agent/RealtimeAgent.swift` | P0-03, P0-05, P0-07, P0-20a, P1-01, P1-02, P1-03, P1-06, P1-08, P1-10, P1-11, P1-17, P1-18, P2-01, P2-03, P3-01, P3-02, P3-03, P3-04, P3-06, P3-09, P3-10, P4-03, P4-06, P4-07, P4-08 | — | IM-11 | — | — | IM-11, P0-05, P0-08, P0-14, P0-23, P1-02, P1-12 | SERIALISE |
| `Sources/NextNotes/Agent/RealtimeAgentLocalModelSelfTest.swift` | P3-01 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/RealtimeAgentToolLoopSelfTest.swift` | P0-05, P0-17, P0-20a, P1-02, P1-04, P1-06, P1-08, P1-10, P1-11, P1-13, P1-17, P1-18, P3-01 | — | — | — | — | P1-01, P3-01 | SERIALISE |
| `Sources/NextNotes/Agent/RealtimeAudioSession.swift` | P1-14, P2-01, P2-05, P2-06, P3-04, P3-06 | — | — | — | — | P2-06, P3-04 | SERIALISE |
| `Sources/NextNotes/Agent/STATUS.md` | P1-02, P1-04, P1-14, P4-10 | — | — | — | — | — | SERIALISE |
| `Sources/NextNotes/Agent/Schedules/AgentSchedule.swift` | P4-12 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/Schedules/AgentScheduler.swift` | P4-12, P4-13 | — | — | — | — | P4-04 | SERIALISE |
| `Sources/NextNotes/Agent/Schedules/DigestSelfTest.swift` | P4-06, P4-12 | — | — | — | — | — | SERIALISE |
| `Sources/NextNotes/Agent/Schedules/PodcastSelfTest.swift` | P4-12 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/Schedules/RoutineAuthoritySelfTest.swift` | P4-12 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/Schedules/STATUS.md` | P4-12 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/Schedules/ScheduleSelfTest.swift` | P4-12 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/Schedules/ScheduleTools.swift` | P4-12 | — | — | — | — | P4-06, P4-13 | SHARED-READ |
| `Sources/NextNotes/Agent/Schedules/ScheduledRunner.swift` | P0-20a, P1-06, P1-17, P4-01, P4-03, P4-06, P4-12 | — | — | — | — | P1-17 | SERIALISE |
| `Sources/NextNotes/Agent/Schedules/agent-schedules.json` | P4-12 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/Speech/AgentSpeechPolicy.swift` | P0-09 | — | — | — | — | P1-10 | SHARED-READ |
| `Sources/NextNotes/Agent/Speech/AgentSpeechSynthesizer.swift` | P2-01, P2-05, P2-06, P2-07 | — | — | — | — | P0-09, P1-14, P3-04 | SERIALISE |
| `Sources/NextNotes/Agent/Speech/AgentStreamingSpeechBacking.swift` | P2-06 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/Speech/KokoroAgentVoice.swift` | P2-05 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/Speech/PocketAgentVoice.swift` | P2-01, P2-05, P2-06, P2-08 | — | — | — | — | P2-07 | SERIALISE |
| `Sources/NextNotes/Agent/Speech/StreamingSpeechBuffer.swift` | P0-09, P2-01, P2-06 | — | — | — | — | — | SERIALISE |
| `Sources/NextNotes/Agent/Speech/TTSPipelineSelfTest.swift` | P2-06 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/Speech/VoicePlaybackReference.swift` | P2-01, P2-08 | — | — | — | — | — | SERIALISE |
| `Sources/NextNotes/Agent/Tasks/AgentTask.swift` | P3-03, P6-04 | — | — | — | — | — | SERIALISE |
| `Sources/NextNotes/Agent/Tasks/AgentTaskManager.swift` | P3-01, P3-03, P3-04, P3-09, P6-04, P6-05, P6-07, P6-10 | — | — | — | — | P4-01, P6-01 | SERIALISE |
| `Sources/NextNotes/Agent/Tasks/Durable/STATUS.md` | P6-03, P6-10 | — | — | — | — | — | SERIALISE |
| `Sources/NextNotes/Agent/Tasks/Durable/TaskDependency.swift` | P6-10 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/Tasks/Durable/TaskEventJournal.swift` | P6-03 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/Tasks/Durable/TaskGraphSelfTest.swift` | P6-10 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/Tasks/Durable/TaskHeartbeat.swift` | P6-05 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/Tasks/Durable/TaskRecoveryPlanner.swift` | P6-04 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/Tasks/Durable/TaskRecoverySelfTest.swift` | P6-04 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/Tasks/Durable/TaskRetryPolicy.swift` | P6-06 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/Tasks/Durable/TaskRetrySelfTest.swift` | P6-06 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/Tasks/Durable/TaskStore.swift` | P6-02, P6-03, P6-04, P6-09 | — | — | PH-21 | — | — | SERIALISE |
| `Sources/NextNotes/Agent/Tasks/Durable/TaskStoreSchema.swift` | P6-02, P6-03 | — | — | — | — | — | SERIALISE |
| `Sources/NextNotes/Agent/Tasks/Durable/TaskStoreSelfTest.swift` | P6-01, P6-02, P6-03, P6-04, P6-05, P6-06, P6-09 | — | — | — | — | — | SERIALISE |
| `Sources/NextNotes/Agent/Tasks/Durable/agent-tasks.json` | P6-04 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/ToolClaimGuard.swift` | P1-11 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/ToolLoopBudget.swift` | P1-06 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/ToolStepOutcome.swift` | P1-04 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/Tools/AgentToolExecutor.swift` | P1-01, P1-17, P3-02, P3-09, P4-13 | — | — | — | — | P1-17 | SERIALISE |
| `Sources/NextNotes/Agent/Tools/FilesystemTools.swift` | P1-03 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/Tools/ToolRouter.swift` | P1-03 | — | — | — | — | P1-03, P1-04 | SHARED-READ |
| `Sources/NextNotes/Agent/Voice/MainActorStallProbe.swift` | P2-01 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/Voice/VoiceActivityMonitor.swift` | P2-05 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/Voice/VoiceDuckSelfTest.swift` | P2-05 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/Voice/VoiceLatencySelfTest.swift` | P2-01, P2-02, P2-07 | — | — | — | — | — | SERIALISE |
| `Sources/NextNotes/Agent/Voice/VoiceLatencyTimeline.swift` | P2-01 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/Voice/VoiceModelWarmer.swift` | P2-07 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/VoiceAnnouncementQueue.swift` | P3-04 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/VoiceCapabilityConversationSelfTest.swift` | P1-07, P1-10, P3-03, P3-05, P3-08, P3-10 | — | — | — | — | P3-10 | SERIALISE |
| `Sources/NextNotes/Agent/VoiceCapabilitySnapshot.swift` | P1-03 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/VoiceConversationCoordinator.swift` | P0-06, P0-07, P0-20a, P1-03, P1-07, P1-08, P2-01, P2-02, P2-03, P3-01, P3-02, P3-03, P3-05, P3-06, P3-07, P3-08, P3-10, P4-02, P4-06 | — | — | — | — | P1-02, P1-18, P4-08, P6-09 | SERIALISE |
| `Sources/NextNotes/Agent/VoiceConversationSelfTest.swift` | P3-01, P3-04 | — | — | — | — | P3-01 | SERIALISE |
| `Sources/NextNotes/Agent/VoiceConversationWork.swift` | P1-04, P3-03, P3-07 | — | — | — | — | — | SERIALISE |
| `Sources/NextNotes/Agent/VoiceDeliverySelfTest.swift` | P0-09, P2-06, P3-04 | — | — | — | — | — | SERIALISE |
| `Sources/NextNotes/Agent/VoiceFrontendFailure.swift` | P3-10 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/VoicePlaybackDelivery.swift` | P3-04 | — | — | — | — | P2-06 | SHARED-READ |
| `Sources/NextNotes/Agent/VoiceWorkLifecycleSelfTest.swift` | P3-01 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Agent/WorkspaceToolRunner.swift` | P1-09, P1-10 | — | — | — | — | P1-09 | SERIALISE |
| `Sources/NextNotes/Agent/WorkspaceTools.swift` | P1-09, P3-08 | — | — | — | — | P3-08 | SERIALISE |
| `Sources/NextNotes/Calendar/CalendarService.swift` | P4-01 | — | — | — | — | D-06 | SHARED-READ |
| `Sources/NextNotes/Calendar/Google/GoogleCalendarProvider.swift` | P0-19 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Calendar/Google/GoogleOAuthClient.swift` | P0-19 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Computer/ComputerToolExecutor.swift` | P1-04 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Contents/PlugIns/SystemExtensions.plist` | — | — | — | PH-15 | — | — | SAFE |
| `Sources/NextNotes/Core/AudioCaptureHub.swift` | P2-08 | D-02 | — | — | — | D-01b, D-02 | SERIALISE |
| `Sources/NextNotes/Core/AudioDeviceBufferSize.swift` | P2-08 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Core/Compute/ComputeJob.swift` | P0-06, P3-07 | — | — | — | — | P0-06 | SERIALISE |
| `Sources/NextNotes/Core/Compute/ComputeScheduler.swift` | P0-06, P3-07 | — | — | — | — | M-08, P3-07, P6-05, P6-10 | SERIALISE |
| `Sources/NextNotes/Core/Compute/ModelResidencyPolicy.swift` | P2-07, P3-07 | — | — | — | — | P2-07 | SERIALISE |
| `Sources/NextNotes/Core/DictationController.swift` | P0-20, P0-20c | D-01b, D-02, D-03, D-04, D-05, D-12, D-13, D-15c | — | — | — | P1-06 | SERIALISE |
| `Sources/NextNotes/Core/DictationErrorText.swift` | — | D-04 | — | — | — | — | SAFE |
| `Sources/NextNotes/Core/DictationHoldOutcome.swift` | — | D-01b | — | — | — | — | SAFE |
| `Sources/NextNotes/Core/STATUS.md` | — | D-15c | — | — | — | — | SAFE |
| `Sources/NextNotes/Core/SystemAudioCapture.swift` | — | M-09 | — | — | — | — | SAFE |
| `Sources/NextNotes/Core/TextInjector.swift` | — | D-15b | — | — | — | — | SAFE |
| `Sources/NextNotes/Dictionary/CorrectionLearner.swift` | — | D-10 | — | — | — | — | SAFE |
| `Sources/NextNotes/Dictionary/DictionaryStore.swift` | — | D-10 | — | — | — | — | SAFE |
| `Sources/NextNotes/Formatting/AppleModelWarmth.swift` | — | D-06 | — | — | — | — | SAFE |
| `Sources/NextNotes/Formatting/CleanupEvalCases.swift` | — | D-11 | — | — | — | — | SAFE |
| `Sources/NextNotes/Formatting/CleanupGuard.swift` | — | D-11 | — | — | — | — | SAFE |
| `Sources/NextNotes/Formatting/CleanupRouter.swift` | — | D-01a, D-06, D-07, D-08, D-09, D-11, D-12 | — | — | — | D-06, D-08, D-09, D-12 | SERIALISE |
| `Sources/NextNotes/Formatting/CleanupTrace.swift` | — | D-01a, D-08, D-12 | — | — | — | D-01a | SERIALISE |
| `Sources/NextNotes/Formatting/CleanupWarmthProbe.swift` | — | D-06, D-08 | — | — | — | — | SERIALISE |
| `Sources/NextNotes/Formatting/FoundationModelFormatter.swift` | — | D-01a, D-06, D-07, D-08 | — | — | — | D-01a | SERIALISE |
| `Sources/NextNotes/Formatting/IncrementalCleanup.swift` | — | D-12 | — | — | — | — | SAFE |
| `Sources/NextNotes/Formatting/LLM/ChatTemplate.swift` | P0-04, P0-18 | — | — | — | — | — | SERIALISE |
| `Sources/NextNotes/Formatting/LLM/ChatTemplateSelfTest.swift` | P0-04 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Formatting/LLM/FoundationModelLLMProvider.swift` | P0-20a, P1-01 | M-12, M-13 | — | — | — | P0-05, P1-01, P1-05 | COLLISION |
| `Sources/NextNotes/Formatting/LLM/GBNFGrammar.swift` | P1-05 | — | — | — | — | P1-05 | SHARED-READ |
| `Sources/NextNotes/Formatting/LLM/GGUFMetadata.swift` | P0-13 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Formatting/LLM/LLMProvider.swift` | P0-17, P1-05 | M-13 | — | — | — | P0-05, P0-14 | COLLISION |
| `Sources/NextNotes/Formatting/LLM/LlamaArchitectures.swift` | P0-13, P0-16 | — | — | — | — | — | SERIALISE |
| `Sources/NextNotes/Formatting/LLM/LlamaHelpers.swift` | P0-04, P0-14 | — | — | — | — | — | SERIALISE |
| `Sources/NextNotes/Formatting/LLM/LlamaLLMProvider.swift` | P0-14, P1-01, P1-05 | M-13 | — | — | — | P0-05, P1-01 | COLLISION |
| `Sources/NextNotes/Formatting/LLM/LlamaLoadProbe.swift` | P0-13 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Formatting/LLM/LocalVoiceDecision.swift` | P2-02, P3-03, P3-05, P3-08, P3-10, P4-02, P4-03 | — | — | — | — | P1-07 | SERIALISE |
| `Sources/NextNotes/Formatting/LLM/LocalVoiceFrontend.swift` | P0-06, P0-20a, P2-01, P2-02, P2-03, P3-03, P3-04, P3-05, P3-07, P3-08, P3-10, P4-01 | — | — | — | — | P4-02, P5-01 | SERIALISE |
| `Sources/NextNotes/Formatting/LLM/LocalVoiceFrontendSelfTest.swift` | P2-02, P3-05 | — | — | — | — | — | SERIALISE |
| `Sources/NextNotes/Formatting/LLM/LocalVoiceFrontendSpeculationSelfTest.swift` | P2-03 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Formatting/LLM/NotesModelRuntime.swift` | P0-02, P0-04, P0-06, P0-14, P0-18, P0-20a, P1-05, P3-07, P4-09 | — | — | — | — | P0-05, P0-13, P1-06, P1-10, P3-07 | SERIALISE |
| `Sources/NextNotes/Formatting/LLM/OpenAICompatibleLLMProvider.swift` | P0-19, P0-20a, P1-05 | M-13 | — | — | — | P1-04 | COLLISION |
| `Sources/NextNotes/Formatting/LLM/OpenRouterLLMProvider.swift` | P0-17, P0-19, P0-20a, P1-05 | M-13 | — | — | — | P0-05, P0-17, P4-09, P5-01 | COLLISION |
| `Sources/NextNotes/Formatting/LLM/OpenRouterReasoning.swift` | P0-17 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Formatting/LLM/PrefixCacheSelfTest.swift` | P0-18 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Formatting/LLM/PrefixReuse.swift` | P0-18 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Formatting/LLM/STATUS.md` | P4-03 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Formatting/LLM/VoiceSpeculationPolicy.swift` | P2-03 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Formatting/LLM/agent-persona-base.md` | P4-03 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Formatting/LLM/library.json` | P0-13 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Formatting/SentenceChunker.swift` | — | D-08, D-12 | — | — | — | D-07, D-08 | SERIALISE |
| `Sources/NextNotes/Formatting/StructurePlan.swift` | — | D-01a, D-09 | — | — | — | — | SERIALISE |
| `Sources/NextNotes/Formatting/StructurePlanner.swift` | — | D-01a, D-06, D-09 | — | — | — | — | SERIALISE |
| `Sources/NextNotes/IMessage/Agent/IMessageConversationMapper.swift` | — | — | IM-11 | — | — | — | SAFE |
| `Sources/NextNotes/IMessage/Agent/IMessageInteractionAdapter.swift` | — | — | IM-11 | — | — | — | SAFE |
| `Sources/NextNotes/IMessage/Agent/IMessageModels.swift` | — | — | IM-11 | — | — | — | SAFE |
| `Sources/NextNotes/IMessage/Agent/RemoteAgentTurn.swift` | — | — | IM-11 | — | — | — | SAFE |
| `Sources/NextNotes/IMessage/Attachments/MessagesAttachment.swift` | — | — | IM-14 | — | — | — | SAFE |
| `Sources/NextNotes/IMessage/Attachments/MessagesAttachmentCopier.swift` | — | — | IM-14 | — | — | — | SAFE |
| `Sources/NextNotes/IMessage/Attachments/MessagesAttachmentPolicy.swift` | — | — | IM-14 | — | — | — | SAFE |
| `Sources/NextNotes/IMessage/Attachments/MessagesAttachmentReader.swift` | — | — | IM-14 | — | — | — | SAFE |
| `Sources/NextNotes/IMessage/Attachments/MessagesAttachmentSelfTest.swift` | — | — | IM-14 | — | — | — | SAFE |
| `Sources/NextNotes/IMessage/Database/MessagesDatabase.swift` | — | — | IM-04 | — | — | — | SAFE |
| `Sources/NextNotes/IMessage/Database/MessagesDatabaseHealth.swift` | — | — | IM-04 | — | — | — | SAFE |
| `Sources/NextNotes/IMessage/Database/MessagesDatabaseSelfTest.swift` | — | — | IM-04 | — | — | — | SAFE |
| `Sources/NextNotes/IMessage/Database/MessagesDecoder.swift` | — | — | IM-05 | — | — | — | SAFE |
| `Sources/NextNotes/IMessage/Database/MessagesDecoderSelfTest.swift` | — | — | IM-05 | — | — | — | SAFE |
| `Sources/NextNotes/IMessage/Database/MessagesQueries.swift` | — | — | IM-04 | — | — | — | SAFE |
| `Sources/NextNotes/IMessage/Database/MessagesSchema.swift` | — | — | IM-04 | — | — | — | SAFE |
| `Sources/NextNotes/IMessage/IMessageBridge.swift` | — | — | IM-08 | — | — | — | SAFE |
| `Sources/NextNotes/IMessage/IMessageConfiguration.swift` | — | — | IM-07 | — | — | — | SAFE |
| `Sources/NextNotes/IMessage/IMessageDelivery.swift` | — | — | IM-16 | — | — | — | SAFE |
| `Sources/NextNotes/IMessage/IMessageReport.swift` | — | — | IM-17 | — | — | — | SAFE |
| `Sources/NextNotes/IMessage/IMessageSelfTest.swift` | — | — | IM-17 | — | — | — | SAFE |
| `Sources/NextNotes/IMessage/Pairing/RemoteIdentity.swift` | — | — | IM-07, IM-09 | — | — | — | SERIALISE |
| `Sources/NextNotes/IMessage/Pairing/RemoteIdentityStore.swift` | — | — | IM-07 | — | — | — | SAFE |
| `Sources/NextNotes/IMessage/Pairing/SelfChannel.swift` | — | — | IM-07 | — | — | — | SAFE |
| `Sources/NextNotes/IMessage/Pairing/SelfChannelPairing.swift` | — | — | IM-07 | — | — | — | SAFE |
| `Sources/NextNotes/IMessage/Pairing/SelfChannelSelfTest.swift` | — | — | IM-07 | — | — | — | SAFE |
| `Sources/NextNotes/IMessage/Sending/IMessageActionVerifier.swift` | — | — | IM-10 | — | — | — | SAFE |
| `Sources/NextNotes/IMessage/Sending/IMessageActionVerifierSelfTest.swift` | — | — | IM-10 | — | — | — | SAFE |
| `Sources/NextNotes/IMessage/Sending/IMessageOutboundStore.swift` | — | — | IM-08 | — | — | — | SAFE |
| `Sources/NextNotes/IMessage/Sending/IMessageVoiceNote.swift` | — | — | IM-15 | — | — | — | SAFE |
| `Sources/NextNotes/IMessage/Sending/MessagesAppleEvent.swift` | — | — | IM-09 | — | — | — | SAFE |
| `Sources/NextNotes/IMessage/Sending/MessagesSender.swift` | — | — | IM-09 | — | — | — | SAFE |
| `Sources/NextNotes/IMessage/Sending/OutboundLedgerSelfTest.swift` | — | — | IM-08 | — | — | — | SAFE |
| `Sources/NextNotes/IMessage/Sending/OutboundMessageLedger.swift` | — | — | IM-08 | — | — | — | SAFE |
| `Sources/NextNotes/IMessage/Watcher/AttachmentJoinResolver.swift` | — | — | IM-06 | — | — | — | SAFE |
| `Sources/NextNotes/IMessage/Watcher/MessagesWALWatcher.swift` | — | — | IM-06 | — | — | — | SAFE |
| `Sources/NextNotes/IMessage/Watcher/MessagesWatcher.swift` | — | — | IM-06 | — | — | — | SAFE |
| `Sources/NextNotes/IMessage/Watcher/MessagesWatcherSelfTest.swift` | — | — | IM-06 | — | — | — | SAFE |
| `Sources/NextNotes/IMessage/Watcher/MessagesWatermark.swift` | — | — | IM-06 | — | — | — | SAFE |
| `Sources/NextNotes/IMessage/imessage-settings.json` | — | — | IM-07 | — | — | — | SAFE |
| `Sources/NextNotes/Integrations/Composio/ComposioBrowserAuth.swift` | P0-19 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Integrations/MCP/MCPSession.swift` | P0-19 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/IslandOwnership.swift` | P3-09 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Knowledge/Assembler.swift` | P4-08, P4-09 | — | — | — | — | — | SERIALISE |
| `Sources/NextNotes/Knowledge/GraphStore.swift` | P4-07a | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Knowledge/KnowledgeAsk.swift` | P0-20a, P4-08 | — | — | — | — | — | SERIALISE |
| `Sources/NextNotes/Knowledge/KnowledgeAskSelfTest.swift` | P1-17 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Knowledge/KnowledgeIndexSelfTest.swift` | P0-21 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Knowledge/KnowledgeIndexer.swift` | P0-21 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Knowledge/KnowledgeTools.swift` | P0-21, P1-03, P1-17 | — | — | — | — | P0-21, P1-03, P4-01, P4-09, P5-01 | SERIALISE |
| `Sources/NextNotes/Knowledge/next-memory.json` | P4-07a | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Meetings/AudioProcessOwner.swift` | — | M-02 | — | — | — | — | SAFE |
| `Sources/NextNotes/Meetings/AudioRetentionSelfTest.swift` | — | M-10 | — | — | — | — | SAFE |
| `Sources/NextNotes/Meetings/CallDetector.swift` | — | M-02, M-11 | — | PH-12 | — | M-06 | SERIALISE |
| `Sources/NextNotes/Meetings/CallPolicy.swift` | — | M-02, M-11 | — | PH-09, PH-12 | — | — | SERIALISE |
| `Sources/NextNotes/Meetings/ChunkedTranscriber.swift` | P0-20b, P3-07 | M-01, M-07, M-09, M-16a | — | — | — | D-03 | SERIALISE |
| `Sources/NextNotes/Meetings/DiarizationService.swift` | P0-20b | M-03, M-08, M-16a | — | — | — | — | SERIALISE |
| `Sources/NextNotes/Meetings/DiarizeAssignSelfTest.swift` | — | M-04 | — | — | — | — | SAFE |
| `Sources/NextNotes/Meetings/DiarizeHintsSelfTest.swift` | — | M-03 | — | — | — | — | SAFE |
| `Sources/NextNotes/Meetings/FinalTranscriptService.swift` | — | M-01 | — | — | — | — | SAFE |
| `Sources/NextNotes/Meetings/MeetingActionReconciler.swift` | P4-10 | — | — | — | — | P1-04 | SHARED-READ |
| `Sources/NextNotes/Meetings/MeetingAudioWriter.swift` | — | M-10 | — | — | — | — | SAFE |
| `Sources/NextNotes/Meetings/MeetingBacklogSelfTest.swift` | — | M-07 | — | — | — | — | SAFE |
| `Sources/NextNotes/Meetings/MeetingContextExtractor.swift` | — | M-14 | — | — | — | — | SAFE |
| `Sources/NextNotes/Meetings/MeetingContextReconciler.swift` | — | M-14 | — | — | — | — | SAFE |
| `Sources/NextNotes/Meetings/MeetingContextStore.swift` | — | M-14 | — | — | — | P4-10 | SHARED-READ |
| `Sources/NextNotes/Meetings/MeetingController.swift` | — | M-08 | — | — | — | M-08 | SHARED-READ |
| `Sources/NextNotes/Meetings/MeetingDiarizer.swift` | — | M-01, M-03, M-04 | — | — | — | — | SERIALISE |
| `Sources/NextNotes/Meetings/MeetingFinalPass.swift` | — | M-01 | — | — | — | — | SAFE |
| `Sources/NextNotes/Meetings/MeetingFinalsSelfTest.swift` | — | M-01 | — | — | — | — | SAFE |
| `Sources/NextNotes/Meetings/MeetingModels.swift` | P4-10, P4-13 | M-01, M-10, M-11 | — | — | — | M-16a | COLLISION |
| `Sources/NextNotes/Meetings/MeetingNotesContext.swift` | P4-04 | — | — | — | — | P5-01 | SHARED-READ |
| `Sources/NextNotes/Meetings/MeetingPipeline.swift` | — | M-01, M-10 | — | — | — | — | SERIALISE |
| `Sources/NextNotes/Meetings/MeetingQualityProbe.swift` | — | M-01, M-16a | — | — | — | — | SERIALISE |
| `Sources/NextNotes/Meetings/MeetingResumeSelfTest.swift` | — | M-08 | — | — | — | — | SAFE |
| `Sources/NextNotes/Meetings/MeetingResumer.swift` | — | M-08 | — | — | — | P6-04 | SHARED-READ |
| `Sources/NextNotes/Meetings/MeetingScheduler.swift` | P4-01 | M-11 | — | — | — | M-02, M-06 | COLLISION |
| `Sources/NextNotes/Meetings/MeetingSession.swift` | — | M-01, M-08, M-09, M-16a, M-16c | — | — | — | — | SERIALISE |
| `Sources/NextNotes/Meetings/MeetingStore.swift` | — | M-01, M-08, M-10 | — | — | — | P4-05, P6-01, P6-04 | SERIALISE |
| `Sources/NextNotes/Meetings/MeetingTapRetrySelfTest.swift` | — | M-09 | — | — | — | — | SAFE |
| `Sources/NextNotes/Meetings/MeetingTranscribeTally.swift` | P0-20b | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Meetings/NotesGenerator.swift` | P0-20b | M-05, M-12, M-13 | — | — | — | — | SERIALISE |
| `Sources/NextNotes/Meetings/NotesLongformSelfTest.swift` | — | M-05, M-12 | — | — | — | — | SERIALISE |
| `Sources/NextNotes/Meetings/NotesPrompts.swift` | — | M-05 | — | — | — | — | SAFE |
| `Sources/NextNotes/Meetings/NotesService.swift` | P0-20b, P4-04, P4-05 | M-05, M-08, M-10, M-16a | — | — | — | P4-05 | SERIALISE |
| `Sources/NextNotes/Meetings/NotesTruncationSelfTest.swift` | — | M-13 | — | — | — | — | SAFE |
| `Sources/NextNotes/Meetings/SpeakerCountHint.swift` | — | M-03 | — | — | — | — | SAFE |
| `Sources/NextNotes/Meetings/SpeakerVoicePrints.swift` | — | M-03 | — | — | — | M-03 | SHARED-READ |
| `Sources/NextNotes/Meetings/StageWatchdog.swift` | — | M-08 | — | — | — | — | SAFE |
| `Sources/NextNotes/Meetings/notes.md` | — | M-08 | — | — | — | — | SAFE |
| `Sources/NextNotes/Meetings/transcript.live.json` | — | M-01 | — | — | — | — | SAFE |
| `Sources/NextNotes/Memory/Consolidation/MemoryLineage.swift` | P4-07a | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Memory/Consolidation/next-memory.json` | P4-07a | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Memory/ExplicitMemoryStatement.swift` | P4-07 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Memory/MemoryGuard.swift` | P4-07a | — | — | — | — | P4-07, P4-07a, P4-11 | SHARED-READ |
| `Sources/NextNotes/Memory/MemoryReviewAppleModel.swift` | P4-11 | — | — | — | — | P1-05, P4-12 | SHARED-READ |
| `Sources/NextNotes/Memory/MemoryReviewLedger.swift` | P4-11 | — | — | — | — | P4-11 | SHARED-READ |
| `Sources/NextNotes/Memory/MemoryReviewSelfTest.swift` | P4-06, P4-07, P4-11 | — | — | — | — | — | SERIALISE |
| `Sources/NextNotes/Memory/MemoryReviewer.swift` | P0-11, P0-20a, P4-07, P4-07a, P4-11 | — | — | — | — | P1-04, P4-07a, P4-12 | SERIALISE |
| `Sources/NextNotes/Memory/MemorySelfTest.swift` | P1-18, P4-07a | — | — | — | — | P4-03 | SERIALISE |
| `Sources/NextNotes/Memory/MemorySources.swift` | P4-11 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Memory/MemoryTools.swift` | P4-11 | — | — | — | — | P4-11 | SHARED-READ |
| `Sources/NextNotes/Memory/NextMemory.swift` | P4-07a, P4-08 | — | — | — | §2 (tiers), §3 (consolidation) | IM-14, P0-11, P1-04, P4-07, P4-07a, P4-08 | SERIALISE |
| `Sources/NextNotes/Memory/RoutineSuggestions.swift` | P4-06, P4-11 | — | — | — | — | P4-06 | SERIALISE |
| `Sources/NextNotes/Memory/STATUS.md` | P4-07a, P4-11 | — | — | — | — | — | SERIALISE |
| `Sources/NextNotes/Memory/agent-memory-review.json` | P4-11 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/NextNotesApp.swift` | P0-02, P0-03, P0-04, P0-11, P0-13, P0-14, P0-18, P0-19, P0-20a, P0-20d, P0-23, P1-01, P1-03, P1-05, P1-09, P1-16, P2-01, P2-04, P2-05, P2-06, P2-07, P3-02, P3-03, P3-06, P3-07, P3-09, P3-10, P4-01, P4-02, P4-04, P4-10, P5-04, P6-01, P6-08 | D-01b, D-02, D-03, D-04, D-05, D-06, D-10, D-12, D-13, D-15a, D-15c, M-01, M-02, M-03, M-04, M-05, M-06, M-07, M-08, M-09, M-11, M-13, M-16a | — | — | — | M-16a, P1-04, P2-01, P3-07 | SERIALISE |
| `Sources/NextNotes/Persona/AgentGrounding.swift` | P1-03, P4-03 | — | — | — | — | P4-01 | SERIALISE |
| `Sources/NextNotes/Persona/AgentNow.swift` | P4-01, P4-09 | — | — | — | — | — | SERIALISE |
| `Sources/NextNotes/Persona/AgentNowSelfTest.swift` | P4-01 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Persona/AgentPromptContext.swift` | P3-05, P4-01, P4-03, P4-08, P4-10 | — | — | — | — | P1-03, P3-05 | SERIALISE |
| `Sources/NextNotes/Persona/PersonaCareEval.swift` | P3-05, P4-03 | — | — | — | — | P3-05 | SERIALISE |
| `Sources/NextNotes/Persona/PersonaSelfTest.swift` | P3-04, P4-01, P4-03, P4-08 | — | — | — | — | — | SERIALISE |
| `Sources/NextNotes/Persona/PersonaStore.swift` | P4-03 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Phone/Agent/PhoneAgentTool.swift` | — | — | — | PH-07 | — | — | SAFE |
| `Sources/NextNotes/Phone/Contacts/ContactPermission.swift` | — | — | — | PH-05 | — | — | SAFE |
| `Sources/NextNotes/Phone/Contacts/PhoneContactResolver.swift` | — | — | — | PH-06 | — | — | SAFE |
| `Sources/NextNotes/Phone/Contacts/PhoneNumberDisambiguator.swift` | — | — | — | PH-06 | — | — | SAFE |
| `Sources/NextNotes/Phone/Contacts/PhoneNumberNormalizer.swift` | — | — | — | PH-06 | — | — | SAFE |
| `Sources/NextNotes/Phone/PhoneCallController.swift` | — | — | — | PH-13 | — | — | SAFE |
| `Sources/NextNotes/Phone/PhoneConfiguration.swift` | — | — | — | PH-05 | — | — | SAFE |
| `Sources/NextNotes/Phone/PhoneReadiness.swift` | — | — | — | PH-05 | — | — | SAFE |
| `Sources/NextNotes/Phone/PhoneReadinessProbe.swift` | — | — | — | PH-05 | — | — | SAFE |
| `Sources/NextNotes/Phone/Tests/PhoneContactSelfTest.swift` | — | — | — | PH-06 | — | — | SAFE |
| `Sources/NextNotes/Phone/Tests/PhoneReadinessSelfTest.swift` | — | — | — | PH-05 | — | — | SAFE |
| `Sources/NextNotes/Scripts/STATUS.md` | — | M-01 | — | — | — | — | SAFE |
| `Sources/NextNotes/Scripts/agent-tasks.json` | P4-04 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Scripts/library.json` | P0-13 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Scripts/meeting.json` | P4-10 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Scripts/proposals.json` | P4-10 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Scripts/transcript.live.json` | — | M-01 | — | — | — | — | SAFE |
| `Sources/NextNotes/Support/ContentionSelfTests.swift` | — | D-14 | — | — | — | — | SAFE |
| `Sources/NextNotes/Support/DictationHygieneSelfTest.swift` | — | D-15a, D-15b | — | — | — | — | SERIALISE |
| `Sources/NextNotes/Support/LatencyTrace.swift` | P2-01 | M-16a | — | — | — | M-16a, P0-20a | SERIALISE |
| `Sources/NextNotes/Support/MetricsStore.swift` | P0-20, P2-01 | — | — | — | — | M-16a, P0-20a | SERIALISE |
| `Sources/NextNotes/Support/ModelDownloader.swift` | P2-04 | — | — | — | — | P0-19 | SHARED-READ |
| `Sources/NextNotes/Support/ModelLibrary/00-README.md` | P0-02 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Support/ModelLibrary/HuggingFaceClient.swift` | P0-13 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Support/ModelLibrary/InstalledModelLibrary.swift` | P0-02, P0-11, P0-13, P0-14 | — | — | — | §2.2 (tier defaults?) — not stated | P0-03 | SERIALISE |
| `Sources/NextNotes/Support/ModelLibrary/ModelLibrarySelfTests.swift` | P0-02 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Support/ModelLibrary/ModelLibraryStore.swift` | P0-02, P0-13 | — | — | — | — | P0-01, P0-14 | SERIALISE |
| `Sources/NextNotes/Support/ModelLibrary/ModelLoadNotice.swift` | P0-14 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Support/ModelLibrary/ModelOpenFailureStore.swift` | P0-14 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Support/ModelLibrary/ModelSupportSelfTest.swift` | P0-02, P0-13, P0-14 | — | — | — | — | — | SERIALISE |
| `Sources/NextNotes/Support/ModelRoles/ModelRoleSelfTest.swift` | P0-03, P0-22, P1-12, P4-09 | — | — | — | — | P0-19, P5-04 | SERIALISE |
| `Sources/NextNotes/Support/ModelRoles/ModelRoleStore.swift` | P0-03, P0-11, P0-14, P0-22, P1-01, P1-08, P1-12, P4-09 | — | — | — | — | P0-17, P0-22, P1-01, P1-12 | SERIALISE |
| `Sources/NextNotes/Support/ModelRoles/STATUS.md` | P0-03 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Support/Notifications.swift` | P4-04, P4-05 | — | — | — | — | — | SERIALISE |
| `Sources/NextNotes/Support/Permissions.swift` | — | — | IM-03, IM-04 | PH-05 | — | PH-05 | SERIALISE |
| `Sources/NextNotes/Support/PrivateNetworking.swift` | P0-19 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Support/PrivateNetworkingSelfTest.swift` | P0-19 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Support/RunLog.swift` | — | D-15a | — | — | — | P0-20c | SHARED-READ |
| `Sources/NextNotes/Support/RunStore.swift` | — | D-15a | — | — | — | — | SAFE |
| `Sources/NextNotes/Support/SelfTestStoreGuard.swift` | P0-11, P6-02 | — | IM-07, IM-08 | — | — | — | SERIALISE |
| `Sources/NextNotes/Support/Settings.swift` | P0-17, P0-21, P1-05, P4-04, P4-05, P4-06, P4-09, P4-13, P5-01 | D-15a, M-01, M-02, M-14, M-15 | — | — | — | P0-05 | COLLISION |
| `Sources/NextNotes/Support/StoreIsolationSelfTest.swift` | P0-11 | — | — | — | — | P6-01 | SHARED-READ |
| `Sources/NextNotes/Support/Usage/JobReport.swift` | P6-08 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Support/Usage/ModelPassRecorder.swift` | P0-20a, P6-07 | — | — | — | — | — | SERIALISE |
| `Sources/NextNotes/Support/Usage/STATUS.md` | — | D-01b | — | — | — | — | SAFE |
| `Sources/NextNotes/Support/Usage/UsageLog.swift` | P0-20a | D-01b | — | — | — | P6-07 | SERIALISE |
| `Sources/NextNotes/Support/Usage/UsageLogSelfTest.swift` | P0-20a, P0-20b, P0-20c, P0-20e, P6-07 | — | — | — | — | — | SERIALISE |
| `Sources/NextNotes/Support/Usage/UsageRecord.swift` | P0-20a, P6-07 | — | — | — | — | — | SERIALISE |
| `Sources/NextNotes/Support/Usage/UsageReport.swift` | P0-20d | — | — | — | — | P6-08 | SHARED-READ |
| `Sources/NextNotes/Support/Usage/UsageSummary.swift` | P0-20d | — | — | — | — | P6-07 | SHARED-READ |
| `Sources/NextNotes/Support/agent-tasks.json` | P6-02 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Support/imessage-settings.json` | — | — | IM-07 | — | — | — | SAFE |
| `Sources/NextNotes/Tests/Fixtures/generate.sh` | — | M-16a | — | — | — | — | SAFE |
| `Sources/NextNotes/Tests/Fixtures/manifest.json` | — | M-16a | — | — | — | — | SAFE |
| `Sources/NextNotes/Tests/Fixtures/meetings/manifest.json` | — | M-16a | — | — | — | — | SAFE |
| `Sources/NextNotes/Tests/Fixtures/next-memory.json` | P4-07a | — | — | — | — | — | SAFE |
| `Sources/NextNotes/Transcription/02-MEETINGS.md` | — | D-04 | — | — | — | — | SAFE |
| `Sources/NextNotes/Transcription/ParakeetEngine.swift` | P3-07 | D-04, D-14 | — | — | — | — | SERIALISE |
| `Sources/NextNotes/Transcription/ParakeetInput.swift` | — | D-04 | — | — | — | — | SAFE |
| `Sources/NextNotes/Transcription/StreamingASR.swift` | — | M-01, M-07 | — | — | — | — | SERIALISE |
| `Sources/NextNotes/Transcription/TranscriptionEngine.swift` | — | D-02 | — | — | — | D-02 | SHARED-READ |
| `Sources/NextNotes/UI/Agent/ActivityView.swift` | P6-08 | — | — | — | — | P6-08 | SHARED-READ |
| `Sources/NextNotes/UI/Agent/AgentView.swift` | P0-03, P0-15, P4-06 | — | — | — | — | P0-14, P0-18 | SERIALISE |
| `Sources/NextNotes/UI/Agent/IdeasView.swift` | P4-06 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/UI/DesignSystem.swift` | P0-20d, P1-16, P4-04 | — | — | — | — | P1-16 | SERIALISE |
| `Sources/NextNotes/UI/Dictation/DictationView.swift` | — | D-10 | — | — | — | — | SAFE |
| `Sources/NextNotes/UI/Dictation/TranscriptionRow.swift` | — | D-10 | — | — | — | — | SAFE |
| `Sources/NextNotes/UI/Dictionary/DictionaryPanel.swift` | — | D-10 | — | — | — | — | SAFE |
| `Sources/NextNotes/UI/HUDView.swift` | — | D-02 | — | — | — | — | SAFE |
| `Sources/NextNotes/UI/Island/IslandState.swift` | P0-23, P1-16, P3-09, P4-04, P4-13 | D-02, D-03, M-06 | — | PH-11 | — | D-05, P3-09, P4-04 | COLLISION |
| `Sources/NextNotes/UI/Island/IslandView.swift` | P0-23, P1-16, P3-09, P4-04 | M-06 | — | — | — | — | SERIALISE |
| `Sources/NextNotes/UI/Meetings/MeetingActionsView.swift` | P4-05 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/UI/Meetings/MeetingDetailView.swift` | P4-05, P4-10 | M-15 | — | — | — | — | COLLISION |
| `Sources/NextNotes/UI/STATUS.md` | P1-16 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/UI/Settings/AgentSettingsTab.swift` | P1-17, P4-04, P5-01 | — | IM-04 | — | §5 (MemoriesSection) | — | COLLISION |
| `Sources/NextNotes/UI/Settings/DictationSettingsTab.swift` | — | D-15a | — | — | — | — | SAFE |
| `Sources/NextNotes/UI/Settings/FastListeningSection.swift` | P4-13 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/UI/Settings/IMessageSettingsSection.swift` | — | — | IM-17 | — | — | — | SAFE |
| `Sources/NextNotes/UI/Settings/MeetingsSettingsTab.swift` | — | M-01, M-14 | — | — | — | — | SERIALISE |
| `Sources/NextNotes/UI/Settings/MemoriesSection.swift` | P4-11 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/UI/Settings/ModelLibrary/ModelLibraryViews.swift` | P0-02 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/UI/Settings/ModelRoleSection.swift` | P4-09 | — | — | — | — | P0-01 | SHARED-READ |
| `Sources/NextNotes/UI/Settings/ModelsSettingsTab.swift` | P0-02, P0-13, P0-20d, P4-09 | — | — | — | — | P0-01, P0-03 | SERIALISE |
| `Sources/NextNotes/UI/Settings/OpenRouterModelSelection.swift` | P0-17, P4-09 | — | — | — | — | — | SERIALISE |
| `Sources/NextNotes/UI/Settings/PersonaSection.swift` | P4-03 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/UI/Settings/PhoneCallsSettingsSection.swift` | — | — | — | PH-05, PH-16 | — | — | SERIALISE |
| `Sources/NextNotes/UI/Settings/ProactiveSection.swift` | P4-04, P4-05, P4-06 | — | — | — | — | — | SERIALISE |
| `Sources/NextNotes/UI/Settings/RealtimeCloudConsentSheet.swift` | P5-01 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/UI/Settings/RealtimeCloudSection.swift` | P5-01 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/UI/Settings/UsageSection.swift` | P0-20d | — | — | — | — | — | SAFE |
| `Sources/NextNotes/UI/Settings/proactive-ledger.json` | P4-04 | — | — | — | — | — | SAFE |
| `Sources/NextNotes/UI/UIStringsLint.swift` | P0-15 | — | — | — | — | — | SAFE |
| `THIRD-PARTY-NOTICES.md` | P0-16, P2-04, P2-05 | — | IM-05 | PH-15 | — | — | SERIALISE |
| `Tests/Fixtures/README.md` | — | M-16a | — | — | — | — | SAFE |
| `Tests/Fixtures/meetings/generate.sh` | — | M-16a | — | — | — | — | SAFE |
| `Tests/Fixtures/memory-review.json` | P4-07, P4-11 | — | — | — | — | — | SERIALISE |
| `Tests/Reports/NextNotes-iMessage-P2-____.md` | — | — | IM-17 | — | — | — | SAFE |
| `roadmap/done/agent-analysis-2026-09-23/H2-caps-voice.md` | P3-10 | — | — | — | — | P1-14, P3-10 | SHARED-READ |
| `shared/dictionary-test-vectors.json` | — | D-10 | — | — | — | D-10 | SHARED-READ |
