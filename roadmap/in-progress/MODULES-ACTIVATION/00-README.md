# MODULES-ACTIVATION: start here

This folder is the implementation roadmap for letting the user turn each of the
app's three modules on or off: **Dictation, Meetings, Assistant**.

It is executed task by task by a coding agent that has **no access to the
conversation that produced it**. Everything you need is in these files, the
repo, and `AGENTS.md`. Read this file completely, then `AGENTS.md` at the repo
root, then `STATUS.md` in this folder.

`roadmap/` is git-ignored. Never commit anything under it. Never write roadmap
or plan files into `docs/`.

---

## 1. Model contract (owner revision, 2026-09-30)

Meeting notes, Agent answers and Dictation cleanup have independent appropriate
model choices. Exact verified artifacts are reused through the existing library;
modules do not own duplicate copies. SHARED-BRAIN now means shared files, not
mandatory notes→Agent delegation. Its [contract](../SHARED-BRAIN/00-README.md)
is authoritative for artifact identity, workload consent and runtime ownership.
The owner chose MiniCPM cleanup with Apple guard/fallback; concurrent OpenCode work
owns that implementation. No task state becomes green from this documentation change.

Use the union of enabled modules' missing artifacts for setup/storage; shared bytes
count once. Dictation-only may need MiniCPM, so do not automatically skip model setup.
Do not delete a shared file on module disable while another enabled consumer,
pending job, lease or required fallback needs it. No extra reference-count store.
Current one-file residency is a runtime constraint, not forced role equality.

## Owner decision 2026-10-04: positioning and low-end floor

See [POSITIONING-AND-LOCAL-MODEL](../POSITIONING-AND-LOCAL-MODEL/00-README.md). The user is
non-technical and the reference machine is an M2/M3 MacBook Air with 16 GB RAM and 256 GB
storage. What changes here:
* **MOD-08** asks which modules a person wants in plain words and never shows a model,
  file size choice or download picker; setup appears as one progress state.
* **MOD-09** fetches the benchmark-selected artifact for enabled modules silently; the
  Models tab grouping is an advanced view, not part of the default path.
* **Disk budget:** the union of enabled modules' artifacts must fit a 256 GB Mac with the
  existing free-space reserve kept; fewer distinct artifacts (one shared model) is preferred.
The §3 module defaults are unchanged.

## 1. Why

Some users want only one or two modules. Some have storage limits and should be
able to use one module and its models without downloading the models for the
modules they don't use.

Today there is no master switch for Dictation or Meetings:

* `Support/Settings.swift:789` has only `agentEnabled` (default `false`).
  `AgentService.isReady = agentEnabled && gwsSignedIn` is the only module gate.
* Dictation and Meetings are always on; gating is per-behavior (TCC grants,
  `engine`, `meetingsAutoRecord`, `callDetectionEnabled`).
* `UI/Sidebar.swift:105` filters only `comparison`, `settings`, `search`.
* Onboarding (`UI/Onboarding/OnboardingFlow.swift:8`) is 7 fixed steps;
  `brain` downloads the notes model (~5 GB) even for a dictation-only user.
* Models tab lists everything flat, not grouped by module.

The fix has four parts, in order: a source of truth (Phase A), runtime gates
that respect it without stranding in-flight work (Phase B), onboarding + model
policy so a disabled module never downloads (Phase C), and one self-test that
pins the matrix (Phase D).

## 2. Non-goals

* No second store, ledger, queue, or usage log. Module flags live in
  `Settings` (the existing pattern, same as `agentEnabled`). Downloads still go
  through `LocalModelStore` / `ModelLibraryStore`. Metrics still go through
  `usage.jsonl`. AGENTS.md's single-ledger rule applies.
* No per-module hotkeys, windows, or docks. One sidebar, filtered.
* No automatic model deletion without asking. Disable offers Keep/Delete once
  only for exclusive, unused files that can actually be freed. Shared files remain;
  show their consumers and do not promise their bytes can be reclaimed.
* No copy that names model files, parameter counts, or tech nouns outside
  technical-details rows. `--selftest-ui-strings` stays green.

## 3. Defaults (product decision, do not relitigate)

| Module | Key | Default | Reason |
|---|---|---|---|
| Dictation | `moduleDictationEnabled` | `true` | the app *is* dictation today |
| Meetings | `moduleMeetingsEnabled` | `true` | `meetingsAutoRecord=true` today |
| Assistant | `agentEnabled` (existing, reused) | `false` | unchanged |

Absent key = default above. Existing users see zero change. A fresh user picks
on the new onboarding screen (MOD-08) and can change everything in Settings.

## 4. File map

| File | What it holds |
|---|---|
| `00-README.md` | this file: why, defaults, order, rules |
| `STATUS.md` | the ledger — **update it after every task** |
| `01-PHASE-A-FOUNDATION.md` | MOD-01 … MOD-03: source of truth, sidebar, Modules tab |
| `02-PHASE-B-RUNTIME-GATES.md` | MOD-04 … MOD-07: hotkey, scheduler, agent, index gates |
| `03-PHASE-C-ONBOARDING-MODELS.md` | MOD-08 … MOD-09: onboarding picker, model policy |
| `04-PHASE-D-ACCEPTANCE.md` | MOD-10: `--selftest-modules`, acceptance tier |

**IDs are fixed: MOD-01 … MOD-10. Never renumber.** Lettered subtasks
(`MOD-04a`) are allowed; record each as its own `STATUS.md` row.

## 5. Order and dependencies

```
MOD-01 (source of truth)
  ├─ MOD-02 (sidebar) ─┐
  ├─ MOD-03 (Modules tab) ─┤
  │                        ├─ MOD-04 … MOD-07 (runtime gates, parallel once 01 lands)
  │                        ├─ MOD-08 (onboarding, needs MOD-01 only)
  │                        └─ MOD-09 (models policy, needs MOD-01 + SB-01…04 + SB-06)
  └─ MOD-10 (self-test, needs everything above)
```

MOD-04…MOD-07 touch disjoint files and may run in parallel once MOD-01 lands.
MOD-09 and SHARED-BRAIN share `LocalModelStore`, library deletion and Models UI.
**SB-01…04 own artifact reuse, independent roles and workload fallback; SB-06
owns role/file copy. MOD-09 lands after them and adds enabled-consumer accounting
and module guards.** MOD-08 can build screen routing after MOD-01, but final model
offers/resume wait for SB-04/SB-05. No `prepareSharedBrain` rename. See §7.

## 6. Workflow (per task)

1. Read the task's section. `grep -n` every anchor; line numbers drift.
2. Write the red-first self-test change, confirm it fails.
3. Make the change. `make build && make install OPEN=0`.
4. Run the task's Verify block. One `via-open` run only where the task says so.
5. Update `STATUS.md` in the same commit as the code.

General gates: `make test`, `--selftest-settings`, `--selftest-ui-strings`
(no banned words in new copy).

## 7. Shared files (who owns what)

* `Support/Settings.swift` — MOD-01 owns the three module keys. SB-02 may add
  scoped notes consent if the existing seam is insufficient; coordinate that key.
  AGENT-OVERHAUL P4 tasks also write here: batched registration,
  one commit per roadmap, never revert a key you did not add.
* `UI/Sidebar.swift`, `Support/NavigationState.swift` — MOD-02 owns for this
  roadmap. SHARED-BRAIN does not touch them.
* `UI/Settings/*` — MOD-03 owns the Modules tab + banners; SB-06 owns the
  independent-role/shared-file copy inside the Models tab. Different files mostly; the Models
  tab itself is shared — SB-06 lands first, MOD-09 second.
* `Sources/NextNotes/NextNotesApp.swift`, `Scripts/acceptance.sh`, `AGENTS.md`
  — single-writer by rule. Sub-agents add the flag registration to their task
  instructions; the orchestrator batches them.
* `MeetingModels.swift` — hand-written `init(from:)`; new fields are
  `decodeIfPresent` or every meeting on disk vanishes. No task here adds a
  field, and that is on purpose.

## 8. Glossary

* **Module**: Dictation, Meetings, or Assistant as the user sees them.
* **Model choice**: an independent workload assignment; cleanup uses its existing
  engine setting, meetingNotes and Agent use their existing roles.
* **Shared artifact**: exact verified model bytes referenced by multiple choices;
  one library row/path and download, without shared prompts or permissions.
* **Guard**: an early return / hidden row when the module is off. Never a
  second switch that disagrees with `Settings`.
* **Strand**: leaving a recording, download, or approval behind when its module
  is turned off mid-flight. Every gate task names its no-strand rule.

## Agent follow-up evidence — 2026-09-30

[P1-31b report](../../../Tests/Reports/toolloop-live/2026-09-30-p1-31b-follow-through.md) records honest TIMEOUT classification and broad-mail grounding on existing seams. The save/draft/combined-read prompt experiment was rejected after ordinary quick 5/10→4/10; interruptions under heavy load are not model scores. Final source keeps the original planner instructions. No Agent/notes/cleanup default or model file changed. Parent Agent quality gates remain open; this is neither SB-07 completion nor module/memory-lifecycle implementation. Follow AGENT-OVERHAUL STATUS for retained-source verification and next work.


### Current bounded Agent save evidence — 2026-09-30

P1-31c committed as `4063667`: [explicit-memory report](../../../Tests/Reports/toolloop-live/2026-09-30-p1-31c-explicit-memory.md). The original Cyril save now executes one guarded `memory.remember` and survives durable reopen; ordinary and Needle-first-enabled Y01 pass. Integrated production/usage/store/voice checks and 30 correction tests pass. Fixed Qwen quick 4/10→5/10 still fails the unchanged 9/10 gate; Y01 is outside that set and whole-case p95 worsens 51.417→59.094 s, so no broad quality/latency gain is claimed. General drafts/combined work and complex memory requests remain. Parent P1-31/Phase 1 stay open; this does not complete SB role-quality work or P4-07a→P4-07→P4-11 memory-lifecycle prerequisites.
