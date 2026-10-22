# SHARED-BRAIN: independent roles, shared model files

**Owner decision: 2026-09-30.** This roadmap replaces the former mandatory
Meeting-notes → Agent delegation. The folder name, SB-01…SB-08 IDs and planned
`--selftest-shared-brain` flag remain stable so existing links keep working.
The flag will test independent roles and shared files, not identical providers.
This is a plan; no task becomes implemented or green because this document changed.

Read this file, root `AGENTS.md`, and this folder's `STATUS.md` before working.
`roadmap/` is git-ignored; never commit it or put plans in the published `docs/`.
Reports belong in `Tests/Reports/`.

## 1. Product and ownership contract

Dictation cleanup, meeting notes and Agent answers each use a model appropriate
to their work. They may select the same model or different models. Turning off
Assistant must not stop meeting notes or change their assignment. Changing the
Agent model must not rewrite the meeting-notes or cleanup choice.

Three separate decisions:

| Concern | Existing owner | Rule |
|---|---|---|
| Role assignment | `ModelRoleStore` for Agent/meetingNotes; existing cleanup settings and `CleanupRouter` for cleanup | Independent choices, prompts, budgets and consent |
| Downloaded artifacts | `InstalledModelLibrary`, `ModelLibraryStore`, `ModelDownloader`, `LocalModelStore` | One verified physical copy of each exact artifact |
| Loaded inference state | `NotesModelRuntime`, `ComputeScheduler`, residency policy | Request uses its chosen model; interactive work stays fluent |

No new model-assignment store, download manager, queue, usage log or runtime per
module. Extend the existing seams. A small pure catalog is data, not another store.

**Artifact identity** means the exact weights/version and quantization, proven by
trusted artifact metadata and a verified digest. Repository revision and filename
identify a download; filename, display name, family name or parameter count alone
never prove two files identical. Reuse the existing verified library row and path,
even under a different basename. Reuse existing in-flight download ownership for
the same artifact. Hash at adoption/verification when needed, never per turn.
Different quantizations, revisions, adapters and auxiliary heads are not interchangeable.

An installed model is reusable for a role only if it is runnable and that role's
quality requirements permit it. File availability is not proof of suitability.
Preserve stored assignments and decode tokens; defaults apply only to unset choices.

## 2. MiniCPM cleanup handoff (concurrent OpenCode work)

The owner chose MiniCPM5-2B as the default cleanup engine, with Apple as its guard
and fallback. The concurrent executor has recorded its picker implementation and
benchmark in `Tests/Reports/MODEL-COMPARE-CLEANUP-2026-09-30.md`; the current unset
preference still selects Apple. The intended default prefers MiniCPM when its exact
verified artifact is ready, with Apple as the no-download fallback otherwise. That
executor owns the default behavior and its tests; this roadmap does not duplicate
its formatter or claim shared-file adoption/runtime contention gates are complete.

* Keep cleanup's MiniCPM selection independent of Agent and meetingNotes.
* Reuse the exact compatible MiniCPM artifact from the existing library; do not
  copy it into a cleanup folder or download it again for another module.
* Keep Apple validation/fallback on the original transcript, existing deterministic
  structure/dictionary safeguards, and the unchanged grounded text on total failure.
* Do not introduce a model-based selector before every cleanup, an extra always-run
  model pass, or a new delay. Reuse existing guard behavior and measure its latency.
* Do not set `activeAgentModelID` or another role's choice to run cleanup. A deferred
  swap is not success: if MiniCPM cannot be acquired promptly and safely, take the
  existing Apple fallback. Never run another loaded file and label it MiniCPM.
* Extend the existing runtime's request/model ownership seam. A select/body/restore
  sequence without ownership through generation is unsafe under actor reentry.
* Sharing weights does not share prompts, conversation history, KV state or consent.
* Use existing `usage.jsonl`; name the engine that actually ran and fallback outcome.

## 3. Runtime, consent and module rules

One loader does not mean one mandatory model assignment. The current one-resident
file limit remains the initial capacity policy, not a product promise of concurrent
models. Bind the selected spec to each request and verify it at execution. Existing
leases and native-context ownership protect running work. Do not switch models under
an active voice lease, evict an interactive model for background work, or silently
execute a request on whichever file is loaded. Background notes yield/wait with
visible state; cleanup uses its bounded Apple fallback. Any additional context or
resident model requires capacity/latency evidence and extends the existing runtime
(AGENT-OVERHAUL P3-07), not a runtime per module.

Cloud consent belongs to the workload and source, not the shared file. Preserve
independent Agent and notes cloud IDs and context limits. An Agent cloud choice or
P4-09 Agent consent does not authorize uploading a meeting transcript or dictation.
Keep graph, memory and file-source consents scoped to the actual reader.

MODULES-ACTIVATION uses the union of requirements for enabled modules. Shared bytes
count once. Disabling a module offers deletion only for files no other enabled
consumer, pending job, runtime lease or required fallback needs. Explicit library
removal still follows verified trial/deletion policy and repairs affected roles.
No extra persisted reference-count ledger: derive consumers from existing choices,
module flags and live/durable work.

## 4. Defaults and benchmarks

There is no universal `defaultCandidateID`. Catalog recommendations are per role.
SB-01 is behavior-preserving: retain today's notes default and existing Agent choices.
MiniCPM cleanup follows the owner's separate implementation. Qwen3-4B, MiniCPM5-2B
and Gemma 4 E4B are initial benchmark candidates, not promised winners for every job.
SB-07 chooses recommendations on each workload's quality, disk/RAM and latency.
A good notes score is not an Agent tool score. Keep Apple as the no-download path
where available; otherwise explain the space/setup need honestly.

### Owner decision 2026-10-04: positioning and low-end floor

See [POSITIONING-AND-LOCAL-MODEL](../POSITIONING-AND-LOCAL-MODEL/00-README.md). What changes here:
* **Recommendations become silent and benchmark-driven.** SB-07's per-role evidence comes
  from that roadmap's bake-off (MiniCPM5-2B, Qwen 4B, Gemma 4 E4B, a code model) run
  through the real code paths on the reference floor: M2/M3 MacBook Air, 16 GB, 256 GB.
* **The person never picks or downloads a model on the default path.** SB-05 onboarding
  fetches the recommended artifact with visible progress and no choice; the SB-06 picker
  is an advanced, opt-in view. Stored explicit choices are still preserved.
* **One resident model is preferred.** When workload scores allow, recommend the same
  artifact for several roles; this is a capacity preference, not forced role equality.
  A second resident model needs floor-machine evidence under P3-07.
* **Floor gate for a recommendation:** ≥20 tok/s decode (25–30 target) with ASR/voice
  running, memory that leaves the Mac usable, and total model disk that fits a 256 GB Mac.
No task changes state because of this note; the MiniCPM cleanup choice stands until
the bake-off produces evidence.

## 5. File map and order

| File | Tasks |
|---|---|
| `01-CATALOG-AND-DELEGATION.md` | SB-01…03: shared catalog, independent roles, request ownership |
| `02-FALLBACK-AND-SURFACES.md` | SB-04…06: per-role reuse/fallback, onboarding, Settings |
| `03-BENCHMARK-AND-GATE.md` | SB-07…08: workload benchmarks and shared-file gate |
| `STATUS.md` | Progress and evidence; update after each task |

**Order:** SB-01 → SB-02 → SB-03 → SB-04 → SB-05/SB-06 → SB-07 → SB-08.
SB-07 fixture/harness preparation can start earlier; recommendation flips wait for
SB-01…06 and the relevant quality gates. MOD-09 requires SB-01…04 and SB-06;
MOD-08 can build module routing after MOD-01 but its model offer/resume integration
waits for SB-04/SB-05. Cleanup implementation can proceed independently; coordinate
before either executor changes its model resolver or shared runtime.

## 6. Workflow and shared files

Use red-first cases, `make build`, `make install OPEN=0`, the task Verify block,
and `make test`. Run self-tests through `Scripts/run-selftest.sh`, foreground,
one at a time; isolated stores only. No owner settings/downloads changed by fixtures.
Status edits under this ignored folder are local; commit production/tests/reports only.

* SB-01 owns catalog metadata/adoption; SB-02 owns role compatibility/migration.
* SB-03 owns runtime/model request binding; coordinate with P0-14/P0-18/P1-28
  and P3-07 before edits. Never undo their awaited selection or cache-reset fixes.
* SB-04 owns reuse-before-download and workload fallback; SB-05/SB-06 own model
  offer/copy. MOD-08/MOD-09 add module guards and enabled-consumer accounting.
* OpenCode owns MiniCPM formatter, default and Apple guard/fallback. SB tasks
  integrate artifact reuse/ownership with it; do not overwrite concurrent changes.
* `NextNotesApp.swift`, `Scripts/acceptance.sh`, `AGENTS.md` are single-writer.
  Coordinate registrations; no blanket restore of shared dirty files.

## 7. Glossary

* **Role**: what the model is asked to do; independent from module activation.
* **Artifact**: exact verified model bytes; reusable across roles.
* **Recommendation**: measured default for an unset role, not a user-choice rewrite.
* **Shared files**: one artifact/path, potentially used by several modules.
* **Request ownership**: chosen model and context remain correct through generation.

## Agent follow-up evidence — 2026-09-30

[P1-31b report](../../../Tests/Reports/toolloop-live/2026-09-30-p1-31b-follow-through.md) records honest TIMEOUT classification and broad-mail grounding on existing seams. The save/draft/combined-read prompt experiment was rejected after ordinary quick 5/10→4/10; interruptions under heavy load are not model scores. Final source keeps the original planner instructions. No Agent/notes/cleanup default or model file changed. Parent Agent quality gates remain open; this is neither SB-07 completion nor module/memory-lifecycle implementation. Follow AGENT-OVERHAUL STATUS for retained-source verification and next work.

**Explicit owner switch, 2026-09-30:** root AGENTS records the owner setting `activeAgentModelID` to the existing MiniCPM5-2B artifact for cleanup residency, while the Agent role remains cloud. Preserve that explicit choice. The prohibition on rewriting `activeAgentModelID` binds silent cleanup reuse; it does not undo this owner switch or authorize changing another role. Agent-local quality is a separate workload gate; sharing a file is not a recommendation.


### Current bounded Agent save evidence — 2026-09-30

P1-31c committed as `4063667`: [explicit-memory report](../../../Tests/Reports/toolloop-live/2026-09-30-p1-31c-explicit-memory.md). The original Cyril save now executes one guarded `memory.remember` and survives durable reopen; ordinary and Needle-first-enabled Y01 pass. Integrated production/usage/store/voice checks and 30 correction tests pass. Fixed Qwen quick 4/10→5/10 still fails the unchanged 9/10 gate; Y01 is outside that set and whole-case p95 worsens 51.417→59.094 s, so no broad quality/latency gain is claimed. General drafts/combined work and complex memory requests remain. Parent P1-31/Phase 1 stay open; this does not complete SB role-quality work or P4-07a→P4-07→P4-11 memory-lifecycle prerequisites.
