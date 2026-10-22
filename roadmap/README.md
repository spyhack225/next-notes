# Roadmap index

Plans for Next Notes. This folder is git-ignored on purpose: plans stay local and are never
published (the published site is `docs/`, so plans never go there). Test reports and evidence go
in `Tests/Reports/`, which is tracked. Read root `AGENTS.md` before acting on anything here.

## The four folders

| Folder | What goes in it | Rule |
|---|---|---|
| `in-progress/` | Roadmaps with active, ongoing work | Has a live `STATUS.md`; someone has claimed or is executing a task, or it is the current owner decision |
| `todo/` | Planned work not started yet | Scheduled and wanted, but no task has been claimed |
| `done/` | Finished plans, audits and research | Kept as dated evidence; not re-executed as current requirements |
| `backlog/` | Not needed now: parked, superseded or long-horizon | Kept intact; moving it back to `todo/` is an owner decision |

A folder move changes where a plan lives, never the state of a task. Each roadmap's own
`STATUS.md` ledger is the only record of implementation state, and documentation changes never
turn a task green. Two things sit outside the four folders:

- [`BUILD-ORDER.md`](BUILD-ORDER.md): the live cross-roadmap coordination (dependency order,
  file collisions, who may run in parallel). Its "Current coordination" section is current; its
  numbered 2026-09-25 matrix is a dated snapshot.
- `references/`: imported repositories, images and memory used as source material (about
  860 MB). Not this app's implementation contract and not a roadmap.

## In progress

| Roadmap | Purpose | Status / next step |
|---|---|---|
| [VOICE-TURN-DETECTION](in-progress/VOICE-TURN-DETECTION/00-README.md) | Silero listening/pause events + Smart Turn v3.2, ASR/TTS contracts, latency and mid-sentence pause qualification | Owner-requested plan and offline benchmark tooling, 2026-10-22; coordinated with ASR/TTS agents. Product integration/native benchmarks remain todo. [STATUS](in-progress/VOICE-TURN-DETECTION/STATUS.md) |
| [POSITIONING-AND-LOCAL-MODEL](in-progress/POSITIONING-AND-LOCAL-MODEL/00-README.md) | Who it is for (four non-technical personas), the 16 GB MacBook Air floor benchmark, the local-model bake-off and silent default (owner decision 2026-10-04) | Created 2026-10-04; PL-01 floor modifiers and PL-05 persona evals are unblocked. [STATUS](in-progress/POSITIONING-AND-LOCAL-MODEL/STATUS.md) |
| [AGENT-OVERHAUL](in-progress/AGENT-OVERHAUL/00-README.md) | Agent tools, latency, full duplex, proactivity, durable jobs; also computer/browser validity ([CU-01…CU-05](in-progress/AGENT-OVERHAUL/09-CELL-USE-COMPUTER-BROWSER.md)) | Phase 6 durable jobs and Phase 3 voice ownership under active work; quick gate 3/10 against 9/10. [STATUS](in-progress/AGENT-OVERHAUL/STATUS.md), [remaining work](in-progress/AGENT-OVERHAUL/REMAINING-WORK.md) |
| [WEBSITE-TO-MAC-EXPERIENCE](in-progress/WEBSITE-TO-MAC-EXPERIENCE/00-README.md) | The landing page's look and interaction in the Mac app (fixed light theme, owner decision 2026-10-01) | UX-00…UX-11 in progress; UX-11 theme foundation installed, on-screen accessibility and motion gates open. [STATUS](in-progress/WEBSITE-TO-MAC-EXPERIENCE/STATUS.md) |
| [SHARED-BRAIN](in-progress/SHARED-BRAIN/00-README.md) | Artifact identity, independent model roles per workload, shared verified files, fallback, quality gates (folder name kept; scope revised 2026-09-30) | SB-01a/01b done; SB-01 catalog in progress; SB-02…08 todo. [STATUS](in-progress/SHARED-BRAIN/STATUS.md), [cleanup handoff](in-progress/SHARED-BRAIN/OPENCODE-CLEANUP-HANDOFF.md) |
| [MODULES-ACTIVATION](in-progress/MODULES-ACTIVATION/00-README.md) | Turning Dictation, Meetings and Assistant on or off, their requirements, shared bytes and deletion | MOD-01 done; MOD-02 navigation integrated, by-eye evidence open; MOD-03…10 todo. [STATUS](in-progress/MODULES-ACTIVATION/STATUS.md) |
| [NextNotes-iMessage](in-progress/NextNotes-iMessage/00-README.md) | Reach the agent by iMessage from your phone | IM-01…IM-15 and IM-17a–f done; IM-16 hosting blocked on AGENT-OVERHAUL Phase 6 durable delivery and recovery. [STATUS](in-progress/NextNotes-iMessage/STATUS.md) |
| [DICTATION-MEETINGS-RATES-AND-GATES](in-progress/DICTATION-MEETINGS-RATES-AND-GATES/00-README.md) | Evidence-gated follow-ups (D-13, D-14) from the dictation/meetings limits work | F-01/F-01a/F-01b done. `make app` refreshes the gates report: D-14 now reads "won't do (evidence)" (F-03 can be recorded); D-13 needs about 69 more owner holds (F-02, F-04 wait). [STATUS](in-progress/DICTATION-MEETINGS-RATES-AND-GATES/STATUS.md) |

## To do

| Roadmap | Purpose | Status / next step |
|---|---|---|
| [DURABLE-AGENT-SESSIONS](todo/DURABLE-AGENT-SESSIONS/00-README.md) | Durable conversations, request identity, checkpoints and qualified recovery through existing Swift/SQLite seams; preserve full duplex | Owner-requested detailed roadmap, 2026-10-22; documentation complete, implementation not started. [STATUS](todo/DURABLE-AGENT-SESSIONS/STATUS.md) |
| [PAID-RELEASE](todo/PAID-RELEASE.md) | A signed, notarized, self-updating paid download; the source stays public | Not started. Owner 2026-10-04: no paid launch before the PL-02 bake-off verdict and a passing floor benchmark; Phases 0–3 may proceed meanwhile |

## Backlog

| Roadmap | Purpose | Why parked / what would bring it back |
|---|---|---|
| [Phone-Calls](backlog/Phone-Calls/00-README.md) | V1: the agent starts a phone call; V2: the agent conducts it | No task started since it was written (2026-09-25). Gated on G1–G4 (a capability spike with an iPhone, Apple's DriverKit entitlement, Developer ID distribution, a legal review). The 2026-10-04 positioning is Mac-first, not phone-first. Revisit after iMessage IM-16 and AGENT-OVERHAUL X08 |
| [Memory lifecycle](backlog/memory-lifecycle-consolidation-roadmap.md) | Memory tiers, consolidation and undo | Self-described "not scheduled"; no task IDs or ledger yet. Starts only after AGENT-OVERHAUL P4-07a → P4-07 → P4-11 close and its fixture corpus exists; then move to `todo/` |
| [S1-MINI-WINDOWS](backlog/S1-MINI-WINDOWS.md) | Optional S1-mini dictation cleanup on Windows | Windows is not a priority (owner 2026-10-04: Mac users on a 16 GB MacBook Air); the Windows app has never run on real hardware |

## Done

| Item | What it was |
|---|---|
| [agent-analysis-2026-09-23/](done/agent-analysis-2026-09-23/AGENT-QUALITY-ANALYSIS-2026-09-23.md) | Read-only research (latency, tools, concurrency, quality, model comparison, capability audits, live log audit) that fed AGENT-OVERHAUL and DICTATION-MEETINGS-LIMITS |
| [MEETING-RECORDING-RELIABILITY](done/MEETING-RECORDING-RELIABILITY/00-README.md) | Meeting interruption, memory and storage pressure, truthful temporary audio | Implemented 19–20 October 2026 and reviewed adversarially six rounds: the frame/clock measurement, the saved-coverage facts, the notes' disclosure, the speaker and title paths. The acceptance run is the owner's: the machine's directory service failed, so no flag could be run against the final source, and the physical long call is still open. [STATUS](done/MEETING-RECORDING-RELIABILITY/STATUS.md) |
| [DICTATION-MEETINGS-LIMITS](done/DICTATION-MEETINGS-LIMITS/00-README.md) | Dictation and meeting limits (D-, M- tasks); D-13/D-14 continue in RATES-AND-GATES |
| [MEETING-CONSOLE-2026-09-26](done/MEETING-CONSOLE-2026-09-26/00-README.md) | The movable meeting panel: Notes, Actions, History, Ask |
| [AGENT-COMPETITOR-GAP-2026-09-20](done/AGENT-COMPETITOR-GAP-2026-09-20.md) | Competitor gap audit and build order |
| [COMPUTER-BROWSER-USE-2026-09-22](done/COMPUTER-BROWSER-USE-2026-09-22.md) | Computer and browser use plan; follow-ups are AGENT-OVERHAUL CU-01…CU-05 |
| [FEEDBACK-2026-09-19-STATUS](done/FEEDBACK-2026-09-19-STATUS.md) | Ten-workstream feedback round ledger |
| [PERSONAL-AGENT](done/PERSONAL-AGENT.md) | Personality, memory, routines, second brain |
| [Next_Notes_v1](done/Next_Notes_v1_Roadmap.md) … [v2](done/Next_Notes_v2_Roadmap.md), [v3](done/Next_Notes_v3_Roadmap.md), [v4](done/Next_Notes_v4_Roadmap.md), [v3/v4 status](done/ROADMAP-V3-V4-STATUS.md) | The original version roadmaps |

## Standing owner decisions

- **2026-10-04, positioning:** non-technical Mac users; the product must be fast on a 16 GB
  MacBook Air. See POSITIONING-AND-LOCAL-MODEL. Windows work is not a priority.
- **2026-10-01, implementation eligibility:** independently testable Agent work may proceed
  below the 9/10 quick bar; quality, owner, latency, full-duplex and recovery gates are
  unchanged. See [Agent README §4.1](in-progress/AGENT-OVERHAUL/00-README.md#41-implementation-eligibility-and-quality-gates--owner-decision-2026-10-01).
- **2026-10-01, design:** the full site theme on every surface; UX-11 owns the foundation.
- **2026-09-30, models:** Meetings, Agent and Dictation cleanup choose models independently.
  Exact verified files are shared through the existing library and downloader; prompts,
  histories, request ownership and cloud consent stay scoped to each workload. Cleanup prefers
  MiniCPM when its verified file is ready, with Apple as the no-download fallback; explicit
  choices stay. File reuse requires verified exact identity, never a filename match. No second
  model store, download queue or usage log per module.

## Reading older files

`done/` keeps historical measurements; model-related files carry an explicit supersession
notice. Do not re-execute old single-model, universal-default or Agent-only deletion
instructions as current requirements. Imported `references/`, raw logs and test measurements are
source material and are preserved rather than rewritten to fit a newer architecture.
The readiness audit of 2026-09-30 ([report](../Tests/Reports/roadmap-readiness-2026-09-30.md))
records why the then-todo plans were not started.
