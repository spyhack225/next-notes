# SHARED-BRAIN status ledger — independent roles, shared files

**Revised 2026-09-30 by owner direction.** The owner revision changed no SB implementation status; later Agent-only diagnostics below do not complete SB tasks.
The folder/IDs/flag stay stable; mandatory Meeting-notes → Agent delegation and
the universal Qwen default are superseded by `00-README.md`'s contract.

States: `todo` not started; `red` failing gate demonstrated; `green` gate passed;
`done` implementation committed; `blocked` missing precondition recorded below;
`in progress` claimed with verification/commit still pending.
Roadmap edits are local/ignored; commits name production/tests/reports only.

## Ledger

| ID | Title | Blocked on | State | Date | Evidence | Commit |
|---|---|---|---|---|---|---|
| SB-01 | SharedModelCatalog + verified artifact adoption/reuse | nothing | in progress | 2026-09-30 | Bounded SB-01a begun; catalog, cross-workload reuse and full gate remain open | — |
| SB-01a | Verify existing bytes before recording library artifact proof | nothing; child of SB-01 | done (bounded foundation) | 2026-09-30 | Actual downloader/library `MODEL_ARTIFACT_FAILED`→`MODEL_ARTIFACT_OK`; integrated `MODEL_LIBRARY_OK`, role/cleanup/store/usage/voice checks and 30 correction tests pass. Legacy/alias/stale registration pinned; model trial latency remains red. [Report](../../../Tests/Reports/shared-artifacts/2026-09-30-sb-01a.md) | `4476a82` |
| SB-01b | Verify and adopt matching legacy installed row before another fetch | SB-01a; child of SB-01 | done (bounded manifest adoption) | 2026-10-01 | Legacy alias regression failed before the fix; actual byte hashing and persisted proof passed afterward. Installed model-library, Settings, UI-string and store-isolation checks passed. Original row, ID, path and choices were preserved. Built-in models, stale proofs and all-workload coverage remain parent-task gaps. [Report](../../../Tests/Reports/shared-artifacts/2026-10-01-sb-01b.md). | `8b70b24` |
| SB-02 | Independent notes/Agent/cleanup choices + scoped consent | SB-01 | todo | | | |
| SB-03 | Request/model ownership + actual-provider labels | SB-01, SB-02 | todo | | | |
| SB-04 | Workload-local reuse/download/Apple policy | SB-01…03 | todo | | | |
| SB-05 | Onboarding/resume from enabled requirements and missing bytes | SB-04 | todo | | | |
| SB-06 | Independent role controls + shared file rows | SB-02…04 | todo | | | |
| SB-07 | Per-workload quality/resource benchmark + recommendations | SB-01…06 | todo | | | |
| SB-08 | Legacy shared-brain flag pins independence/reuse/ownership | SB-07 | todo | | | |

## Phase gates

| Phase | Gate |
|---|---|
| Catalog/roles/runtime SB-01…03 | Old settings/files preserved; exact artifact reused; distinct choices and actual request identity pinned; no voice/cleanup regression |
| Fallback/surfaces SB-04…06 | Workload-scoped fallback/consent; enabled-union bytes; shared-file deletion protections; onboarding/settings/UI strings |
| Benchmark/gate SB-07…08 | SHARED_BRAIN_OK plus independent role-quality reports; Agent meets AO full/owner gate, notes meets predeclared corpus rubric; cleanup evidence and overlap latency recorded |

## BLOCKED notes

For each blocker record ID/date, tried action, exact failing/absent marker, missing
precondition and next step. An absent model or consent is not a successful run.

## Decisions and deviations

- 2026-09-30: Owner requested parallel execution of ready todo work. Folder moved
  to `roadmap/in-progress/`; only SB-01a is claimed. Existing downloader/library
  verification is repaired before a catalog-only layer is added. SB-02…08 remain
  todo; cleanup choices/runtime and other role selections remain with their owners.

- 2026-09-30: Owner approved independent appropriate models for Meetings, Agent
  and Dictation cleanup with exact-file reuse; same model is optional.
- 2026-09-30: Cleanup default/Apple guard-fallback belongs to the concurrent OpenCode
  executor. Coordinate metadata/runtime/registration files; no duplicate formatter.
- 2026-09-30: MiniCPM5-2B cleanup SHIPPED by the OpenCode executor as a picker row
  (`CleanupEngineChoice.miniCPM`, `MiniCPMCleanupFormatter`, Apple guard+fallback
  from the original transcript), decided by `Tests/Reports/MODEL-COMPARE-CLEANUP-2026-09-30.md`
  (MiniCPM 3/42 at 0.59 s vs Apple 0/42 at 3.03 s, Qwen3-4B 8/42, Qwen3.5-4B 11/42).
  The recorded implementation currently uses Apple for an unset fresh-install
  preference (Models tab does not offer MiniCPM yet). Agent model/role untouched.
  Owner's Mac set to MiniCPM. This is implementation evidence, not completion of
  shared-file adoption or contention/ownership gates.
- 2026-09-30: Owner direction for the cleanup executor: prefer MiniCPM for an unset
  choice when its verified artifact is ready; Apple remains the no-download fallback
  otherwise. Preserve explicit stored choices; fixture the current default gap.
- 2026-09-30: Existing notes/Agent settings and cloud IDs remain independent; no
  mass migration or universal recommendation flip. Implementation still todo.
- 2026-09-30: [P1-31a Agent investigation](../../../Tests/Reports/toolloop-live/2026-09-30-p1-31-investigation.md)
  reuses four exact existing local artifacts for paired quick diagnostics and Qwen
  full ordinary 17/30 vs Needle 16/30 (owner 7/10 vs 8/10). No promotion:
  quality gates fail and total-case p95 worsens 49.038→51.012 s. Other full arms,
  role-specific notes/cleanup evidence and overlap remain; SB-07 and all SB tasks
  remain todo. Agent policy/harness work belongs to AO P1-31a, not shared catalog
  adoption or request-ownership completion.

## Agent follow-up evidence — 2026-09-30

[P1-31b report](../../../Tests/Reports/toolloop-live/2026-09-30-p1-31b-follow-through.md) records honest TIMEOUT classification and broad-mail grounding on existing seams. The save/draft/combined-read prompt experiment was rejected after ordinary quick 5/10→4/10; interruptions under heavy load are not model scores. Final source keeps the original planner instructions. No Agent/notes/cleanup default or model file changed. Parent Agent quality gates remain open; this is neither SB-07 completion nor module/memory-lifecycle implementation. Follow AGENT-OVERHAUL STATUS for retained-source verification and next work.

**Explicit owner switch, 2026-09-30:** root AGENTS records the owner setting `activeAgentModelID` to the existing MiniCPM5-2B artifact for cleanup residency, while the Agent role remains cloud. Preserve that explicit choice. The prohibition on rewriting `activeAgentModelID` binds silent cleanup reuse; it does not undo this owner switch or authorize changing another role. Agent-local quality is a separate workload gate; sharing a file is not a recommendation.

SB-01a committed as `4476a82`. Parent SB-01 remains in progress: revision/catalog metadata, legacy adoption, cleanup/notes consumers, concurrent fetch ownership and deletion accounting remain. The existing S1-mini trial latency gate is red at 7.2 s and 6.5 s versus 5 s; no threshold changed. No full SB/role-quality gate is claimed.

- 2026-10-01: SB-01b claimed after committed SB-01a. Bound the continuation to
  checking runnable legacy rows with trusted requested SHA/size at the existing
  background pre-fetch seam and persisting proof on the original row. No role,
  default, cleanup, runtime, download queue or owner-weight operation is claimed;
  catalog/revision metadata and all other parent gates remain pending.

- 2026-10-01: Built-in reuse is still unimplemented: `reloadFromDisk` synthesizes
  `built-in/gemma-4-e4b` with nil proof on each refresh, and the notes downloader
  does not retain its checked proof in the library. SB-01b checks non-built-in
  legacy manifest rows only. No zero-fetch proof for installed built-in Gemma,
  stale-nonnil-proof re-verification or all-workload adoption is claimed. Parent
  SB-01 stays in progress regardless of the bounded child's passing fixtures.


### Current bounded Agent save evidence — 2026-09-30

P1-31c committed as `4063667`: [explicit-memory report](../../../Tests/Reports/toolloop-live/2026-09-30-p1-31c-explicit-memory.md). The original Cyril save now executes one guarded `memory.remember` and survives durable reopen; ordinary and Needle-first-enabled Y01 pass. Integrated production/usage/store/voice checks and 30 correction tests pass. Fixed Qwen quick 4/10→5/10 still fails the unchanged 9/10 gate; Y01 is outside that set and whole-case p95 worsens 51.417→59.094 s, so no broad quality/latency gain is claimed. General drafts/combined work and complex memory requests remain. Parent P1-31/Phase 1 stay open; this does not complete SB role-quality work or P4-07a→P4-07→P4-11 memory-lifecycle prerequisites.
