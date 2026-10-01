# Todo roadmap readiness — 2026-09-30

Owner requested parallel execution of ready roadmap work. This audit uses current
task ledgers, prerequisite states, production call sites and the dirty working
tree; the dated BUILD-ORDER collision matrix is not a readiness verdict.

## Claimed independent slices

| Roadmap / task | Readiness evidence | Owner / boundary | State |
|---|---|---|---|
| MODULES-ACTIVATION MOD-01 | Task and ledger say no prerequisite. Existing Settings is the one persistence owner; no master Dictation/Meetings keys or ModulePolicy exist at claim. | `module_foundation`: two keys, existing Assistant bit, pure policy, production reader, focused driver. No UI/runtime/download changes. | MOD-01 done `450dbaa`; moved to `roadmap/in-progress/MODULES-ACTIVATION`. Integrated build/install, 30 correction tests, Settings/UI strings pass. Later UI/runtime tasks open. |
| SHARED-BRAIN SB-01a | SB-01 has no prerequisite. Audit found existing destination length bypasses digest verification; expected remote SHA is discarded rather than retained as checked-byte proof on library rows. | `artifact_identity`: existing downloader verification, additive library proof, narrow verified-row/reuse producer, tiny fixtures. No model-role/default/cleanup/native-runtime changes. | SB-01a done `4476a82`; actual downloader/library red→green and integrated MODEL_LIBRARY_OK. Moved to `roadmap/in-progress/SHARED-BRAIN`; parent SB-01 incomplete, model-trial latency red. |

Root independently owns AGENT-OVERHAUL P1-31c explicit memory saves. All three
streams use the shared working tree. Root serializes full builds, installation and
model-backed tests; worker drivers are small and isolated. A folder move does not
complete any task, authorize a dependency skip, or prove role quality.

## Remaining todo inventory

| Roadmap | Current result | Why not assigned an implementation worker |
|---|---|---|
| Phone-Calls | G1 / PH-01 still todo, capability evidence absent. P1-03 manifest prerequisite is already done, which alone does not satisfy the folder gate. | V1 waits for background `tel:` capability measured with owner/iPhone; V2 additionally waits entitlement, distribution and legal evidence. PH-04 dated gate inventory can be prepared independently, but cannot close these gates. |
| DICTATION-MEETINGS-RATES-AND-GATES | F-01 already done `99d4a46`; live production code records `laneWait`. F-02…04 still todo. | Original readiness reader failed; coordinator claimed Python-only F-01a and moved this folder to in-progress. F-01a/F-01b committed as `7a94d2d`/`fba4287`; fifteen subprocess fixtures pass. Owner-use follow-ups remain pending. No dictation runtime edit. |
| WEBSITE-TO-MAC-EXPERIENCE | UX-00 baseline still todo; UX-01…10 depend on it or later UI/Agent gates. | Website is concurrently dirty. Source audit/fixture visual baseline can begin independently; it cannot replace real journey/timing evidence or authorize premature Agent/island implementation. Not assigned while the two prerequisite-free source slices occupy available workers. |
| memory-lifecycle-consolidation-roadmap.md | Not scheduled. AGENT-OVERHAUL P4-07a, P4-07 and P4-11 are all todo. | Lifecycle mutation waits for the full provenance → explicit capture → review chain. Corpus design is allowed earlier, but does not make lifecycle implementation ready. |
| PAID-RELEASE.md | Phase 0 owner decisions are not recorded as locked. Source build must remain ungated. | Do not infer price/trial/enrolment/seller decisions or introduce licensing gates from recommended defaults. Distribution needs signing/notarization evidence. |
| S1-MINI-WINDOWS.md | Optional proposal; Windows real-hardware cleanup evidence absent. | It requires a pinned model/runtime and license/spec verification before shipping; no new dependency or weight download was started. Existing Windows dictation is code-complete but not hardware-verified. |
| BUILD-ORDER.md | Coordination document, not a feature task. | Current ownership section updated; historical matrix remains a dated snapshot. |

## Gate reader finding

Read-only command `python3 Scripts/dictation-stats.py --gates` failed on the current
baseline with `UnboundLocalError: cannot access local variable 'stamp' where it is not
associated with a value` at line 85. Its early gates branch calls a function that
is defined later in `main`. No owner content was printed or changed.

The D-14 reader also observes the presence of `stages.laneWait` but does not count
dictation ASR starts waiting at least one second, despite that being its second
declared proceed condition. Neither defect is evidence that lane ownership should
change. Reader repair requires focused red/green CLI fixtures at that producer;
the owner-use thresholds must stay unchanged. Root approved coordinator ownership
of F-01a. The [reader repair report](dictation-gates/2026-09-30-f01a-reader.md)
records 10/11 failures against the frozen old script and 11/11 passes against the
retained producer fix. Follow-up [F-01b](dictation-gates/2026-09-30-f01b-observation.md)
repairs the skipped default seven-day bar and prevents an arbitrary older cutoff
from inventing observation days. Fifteen CLI fixtures pass; the owner diagnostic
is still 73 holds and four observed days short. No owner-use task was closed.

## Navigation and remaining verification

Selected folders moved intact. Resolved Markdown references and literal old todo
paths for SHARED-BRAIN, MODULES-ACTIVATION and the rates/gates folder were updated
throughout local roadmap docs and root AGENTS. The three selected folders' thirteen local
Markdown links all resolve; a repository scan found no remaining old absolute
roadmap path references outside imported/compiled content. Roadmap files remain
Git-ignored and were not force-added.

No build, install, model download, weight copy, default change, cloud call or
external message was performed by this readiness audit. Worker validation and
root integration are recorded separately when they happen; none is claimed here.

Completed worker evidence: [MOD-01](modules/2026-09-30-mod01-foundation.md)
and [SB-01a](shared-artifacts/2026-09-30-sb-01a.md). The module matrix driver passes
all eight combinations with a persistence mutation proving it can fail; the
artifact driver exercises the actual downloader, row recording and manifest
reopening. Root integrated and committed both slices; this report does not turn later
UI/runtime/role/quality tasks green.

## Final integration

Root P1-31c explicit personal-memory saves committed as `4063667`. Original Y01
passes ordinary and Needle-first-enabled arms with a guarded save; production
regressions prove durable reopening and denied/failed saves receive no confirmation.
[Agent report](toolloop-live/2026-09-30-p1-31c-explicit-memory.md). Fixed Qwen quick
is 5/10 against fresh 4/10, still below 9/10; that subset excludes Y01. Parent
Agent full/owner/latency gates stay open.

The integrated build/install succeeds. Thirty dictionary/spoken-form tests and
production, model library/roles, memory, Settings/UI strings, capability, usage,
store isolation, cleanup, grader and voice checks pass. The existing S1-mini
trial latency check remains red (7.2 s, repeat 6.5 s versus 5 s), so no full
model-quality gate is claimed. Disk exhaustion was recorded honestly; only
completed disposable build output/app snapshots were cleared. No weight or
owner store was removed. Concurrent OpenCode source changes were preserved;
Settings and app-entrypoint commits stage only the owned module/artifact hunks.

MOD-02…07 can follow the committed MOD-01 foundation with coordinated file
ownership; model integration MOD-08/09 still waits for the declared SB chain.
SB-01 remains in progress, and memory lifecycle stays unscheduled.
