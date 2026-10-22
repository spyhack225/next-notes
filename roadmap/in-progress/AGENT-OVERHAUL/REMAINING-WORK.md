# Agent Overhaul: exact remaining work — 2026-10-04

> ## Reconciled 2026-10-08
>
> Documentation-only. The ledger of record is [STATUS.md](STATUS.md); read its Reconciled 2026-10-08 block for the evidence table, SHAs and report links. The [status audit](../../../Tests/Reports/agent-overhaul-progress/2026-10-08-status-audit.md) found this checklist stale for Phase 2 and for the quality position. Rows touched below carry a `2026-10-08` line; the original 2026-10-04 text is kept after the label **Historical**. No percentage is asserted.
>
> - Quality: Mini quick 10/10 x3 (`d32b123`), then 9/10 x3 (installed `c2b11e7`); latest retained full pair 25/30 and 23/30 with owner 9/10 (required 8/9, O08 refuses) at `2afe575`. The full/owner gate stays open. Therefore "quick 3/10" and "Quick156 is3/10" below are Historical.
> - Phase 2 is more implemented than the 2026-10-04 rows say (P2-03/05/06/07 have bounded verified children; P2-02 single decision was rejected), but L1/L2 200 ms, 0.9 s first audio and the 200 ms cold duck all remain unmet.
> - Still unchanged and open: `VoiceSession` shadow only, P3-06b, P4-05/06, P5, P6 recovery/retry/IM-16, P2-04 and P2-08.
> - Not re-run by this pass: every number is copied from its cited report.

**Historical (2026-10-04; superseded where it conflicts with the block above):**

<!-- repeated-read-usage438439-current -->
**Measured follow-up, staged442:** seeded-call handling now reaches the unfinished
read (RF05/RF07 pass), but normal32 still fails RF03 and first26 fails RR08.
Added scalar observations preserve both predicates and confirm the shared cause:
SQL serialization loses sub-second attempt starts, making the new saved start equal
to the old one while the cached actual start differs. Revision, attempt, process
owner, original objective and all instructions match. The responsible date codec
is being repaired; admission and repeated recovery remain incomplete. A disk-full
441 usage run is retained INPUT_INVALID. After bounded owned-artifact cleanup,
442 usage passes79 with the same4/5/5 managed attribution. No latency, retry,
owner migration, IM-16 or parent completion is promoted.

**Current implementation — 2026-10-04:** staged original438 → fixed439 changes
only Manager and RecoveryPlanner across1,144 compiler inputs; all fixture inputs
and registration are identical. Managed usage is bounded-verified: six typed and
three voice attribution assertions fail originally; fixed typed79 and the actual
voice checks pass. Selected revised4/spawned5/voice5 provider passes equal saved
rows and now carry exact managed task IDs through the existing log/projections;
known token fields, privacy and unavailable cost controls pass. Nested knowledge,
ordinary owner reports and full P6-07 acceptance remain open.

Repeated read recovery is **incomplete**: original normal32/8 → fixed32/2 still
fails successor completion and unfinished-read execution (RF05/RF07). Empty-latest
31/8 →31/0, changed-source24/1 →24/0, and first-continuation26/0 →26/0 pass.
The two-read failure is being repaired in existing seeded-call handling; no changed
fixture plan or weakened assertion is accepted. Related checks complete23/24 PASS;
ACP final-response/EOF control has two conjunct failures with attribution under
review. Original438 passes the same ACP flag; no double completion or cause is
inferred from its labels. The actual usage27/metrics/isolation controls pass.
Original437's skipped voice handoff is retained invalid; the corrected strict
joined-worker/retained-Island COMMON is identical in438/439. Historical100ms/5ms,
9/10 model gates, broad recovery, physical interaction, IM-16 and parent completion
remain open. [Actual progress](../../../Tests/Reports/agent-overhaul-closure/p3-task-bridge-production/manager-voice-worker-ownership-production/repeated-read-usage438439-progress.json).


<!-- current-d3-implementation -->
**Explicit recovered-read implementation, 2026-10-04:** qualified original430
RED8/26 → unchanged fixed431 PASS26. Six responsible producers change across1,142
compiler inputs; fixture, UI, App registration and Bridge remain identical. A real
prior child exits with revision3, three corrections and a completed native read.
An explicit action admits attempt2 only after exact primary/history/receipt checks
and prior PID absence; alive, stale revision, damaged/uncertain/consequential history
and primary refusal stay held. The actual successor consumes all corrections and
the saved first read, reads only the unfinished second file, and rejects the offered
write before card/receipt/backing. Both native Source/bundle maps remain stable.
Related431 completes23/26 PASS. ACP100ms and C03/F09 receipt5ms remain failed;
live native-tools has one llama grammar-invalid round (4/5), with Apple5/5.
The retained original430 repeats the same llama4/5/Apple5/5 failure, establishing
that it predates recovery. No fixed rerun erases the failure. All storage, recovery56, restoration188, privacy40, owner isolation,
permission, voice delivery/routing/duplex and UI controls pass.

The same original430 capture-endpoint8/Island32 pass with one frontend call and
joined owners. A controlled first-audio receipt on the exact native playback token
reaches the actual IslandPanel consumer; physical sound/display-frame/100ms and
full CORE remain open. Builds428/429 are retained compiler INPUT_INVALID; their
scoped same-COMMON throw/argument corrections precede both430/431.
First-attempt native read continuation is verified; repeated recovery, broader
retry/voice/consequential recovery, owner migration, physical UI, IM-16 and parent
P3/P6 completion remain open. Parallel agents reuse three active worktrees for
repeated read recovery, calendar unknown-outcome verification and integration review.
ACP schema producer432→433 is bounded-verified: all64 actual writers change from
two validated version reads to one, with no assignments and only TaskStore differing
across1,142 compiler inputs. Same explicit recovered-read26 and23 related controls
PASS. Whole worker remains FAILED: fixed small127.676333ms/history104.743083ms exceed
100ms; original small75.997375ms passed/history101.998708ms failed. The extra observed
small-budget failure is retained, cause unproven. One matched unchanged attribution
pair completes: original66.016708/85.951625ms; fixed small56.34875ms passes while
history still fails (its numeric marker is interleaved/unqualified). No failure is erased. C03/F09 receipt5ms remain failed; C03 close split qualifies, F09 raw
SQL profile interleaving stays unqualified. No speed or wider readiness is claimed.
[Exact ACP/close comparison](../../../Tests/Reports/agent-overhaul-closure/p3-task-bridge-production/manager-voice-worker-ownership-production/activity-close432433-qualified-results.json).
[Actual recovery pair](../../../Tests/Reports/agent-overhaul-closure/p3-task-bridge-production/manager-voice-worker-ownership-production/recovered-read430431-qualified-results.json),
[endpoint8/Island32](../../../Tests/Reports/agent-overhaul-closure/p3-task-bridge-production/manager-voice-worker-ownership-production/endpoint430-qualified-results.json).

<!-- calendar-unknown434436-progress -->
**Calendar unknown outcome, 2026-10-04:** qualified original434 fails32 of82
outcome assertions and8 of31 post-read assertions; unchanged fixed436 passes82+31
through eleven normal/direct/legacy modes and three actual held-read modes.
Only four responsible product files differ across1,143 compiler inputs; all fixtures
and registration remain identical. Normal and direct callers read the exact sent
resource with the approved fields. Positive evidence requires a committed terminal
receipt; mismatches, unavailable reads, missing preparation, failed saves and lost
primary/cancellation authority remain unknown, without a second INSERT or replay.
Prior duplicate114/helper10/resource10 controls remain green. Fixed whole worker
still fails the inherited ACP history100ms target at114.033250ms; small98.023875ms
passes. Related23/23 controls PASS, including actual tool review/mail unknown outcomes,
permissions, storage, reader40, owner isolation21files32defaults and duplex/Island consumers.
Build435 is retained compiler INPUT_INVALID; its correction only names the exact
existing callback type in fixed436. The frozen87 forecast was wrong: actual source
and both runs contain82, with no input/predicate change. Real account/crash,
consequential retry, effect cessation, broader recovery, IM-16 and parent gates remain
open. [Exact comparison](../../../Tests/Reports/agent-overhaul-closure/p3-task-bridge-production/manager-voice-worker-ownership-production/calendar-unknown434436-qualified-results.json).

**Calendar resource identity, 2026-10-04:** qualified original426 completes
all ten actual CLI modes: existing114 and helper10 remain green, while nine of ten
prepared-resource identity assertions fail. Fixed427 passes those same114+10 with
only Executor changed across1,141 compiler inputs. The existing prepared UUID now
reaches both normal/injected Workspace proposal constructors; direct proposal IDs
are preserved. Whole worker still fails inherited ACP100ms (original two timing
failures, fixed one); related427 completes20/22 PASS. Only ACP100ms and receipt5ms
remain failed; all storage/authority/voice/Island/UI/privacy controls pass. Original425 remains incomplete and its
timeout cause unmeasured. This fixes current receipt-to-resource traceability;
legacy missing aliases, reconciliation, effect retries, real account/crash proof and
parent completion stay open. Parallel work is implementing explicit recovered
native-read continuation and actual capture-endpoint-to-panel verification.
[Actual pair](../../../Tests/Reports/agent-overhaul-closure/p3-task-bridge-production/manager-voice-worker-ownership-production/calendar-identity426427-qualified-results.json).

**Schema-probe producer, 2026-10-04:** original423 observes two validated
schema-version reads in each actual C03/F09 receipt path; unchanged fixed424
observes one, with only two TaskStore lines changed across1,141 compiler inputs.
The same transaction still checks complete schema, foreign keys, marker and file
identity; connection, synchronization and checkpoint behavior remain unchanged.
The duplicate-read assertions now pass. Both strict5ms targets still fail, so this
is a verified producer simplification, not latency closure. Original423's separate
legacy revision-worker budget failure is retained without scheduler attribution;
it occurs before the added observers and is absent in424. Related424 completes
20/22 PASS; strict5ms and actual ACP100ms fail (small117.090959ms,
history140.089459ms). All functional storage/authority/read-isolation checks pass;
no current full-suite or latency acceptance is claimed.
[Actual pair](../../../Tests/Reports/agent-overhaul-closure/p3-task-bridge-production/manager-voice-worker-ownership-production/schema-probe423424-qualified-results.json).

**Recovery characterization, 2026-10-04:** staged422 passes ten actual
revision3/read/receipt/fresh-reader/old-Task-drain checks plus the unchanged56
recovery cases. Compiler1,141 inputs and native Source/bundle maps remain invariant.
The existing task stays held at attempt1 with all three instructions and its
completed read receipt; automatic dispatch remains zero. This adds an isolated
production-path scenario, not a recovery producer or process-crash proof. Explicit
recovered admission, new-attempt window and uncertain-effect eligibility remain
open. Related422 has10/11 valid checks PASS; ACP history110.1165ms>100ms
fails. Three reader launch inputs were rejected and retained; actual stdout-only
reader40 passes. No worker recheck erases the timing failure. Next is confined read
continuation with conservative prior-process/receipt authority.
[Actual characterization](../../../Tests/Reports/agent-overhaul-closure/p3-task-bridge-production/manager-voice-worker-ownership-production/recovery422-qualified-results.json).

**Latest implementation, 2026-10-04:** calendar duplicate readback qualifies
original420: 38 target assertions fail across114 unchanged checks →421: all114
pass, ten existing Workspace helper groups pass and worker2933 passes. Only
WorkspaceToolRunner differs across1,140 compiler inputs. An occupied event ID now
requires the same actual GET and exact reviewed field comparison before a verified
receipt; mismatched/unavailable results remain explicitly unverified. Primary
refusal launches no CLI process, and terminal receipt refusal retains fired evidence
without success delivery. The isolated peer exercises actual CLI Process/pipe/error
handling, not a real Google account. Original accepted insertion already performs
one INSERT/GET; its F06 failure concerns detail wording, not an effect failure.
Related421 completes20/21 PASS, including A7/Island/UI strings and isolation;
only inherited C03/F09 receipt5ms fails. Retry resource IDs,
creator attribution, crash/recovery, latency and parent gates remain open.
[Exact calendar pair](../../../Tests/Reports/agent-overhaul-closure/p3-task-bridge-production/manager-voice-worker-ownership-production/calendar420421-qualified-results.json).

**Current verification, 2026-10-04:** explicit duplex A7 qualifies
original418 RED2 ownership assertions →419 SAME scenario PASS. Both runs observe
four samples/two with actual worker steps at the unchanged20ms cadence; worker
attempts18→0, worker-driven kind samples0 both. All69 typed checks pass in419;
only the existing IslandOwnership switch differs across1,139 compiler inputs.
Original417 remains INPUT_INVALID; the scoped SAME COMMON publication correction
precedes both418/419. Related419 completes27/28 PASS, including three consecutive
normal32 Island runs and worker2818. Only inherited C03/F09 receipt5ms fails;
full CORE/physical/parent acceptance remains open. Isolated ACP observation416
passes worker2818 without reproducing historical100ms failure (55.04425ms history
stall); no latency fix is claimed. Parallel agents continue explicit recovery,
receipt-cost investigation and actual Capture endpoint/Island panel implementation.
[Exact A7 pair](../../../Tests/Reports/agent-overhaul-closure/p3-task-bridge-production/manager-voice-worker-ownership-production/a7-418419-qualified-results.json).

**Latest implementation,2026-10-04:** scoped filesystem receipt evidence qualifies
original414 RED7/57 →415 SAME57 PASS, whole worker2818 PASS. Only ActionRuntime
changes across1,139 compiler inputs: a returned mutation records its exact path in
its linked verifying receipt before readback; required save refusal retains fired
evidence and reports action-ran/result-not-saved without success or replay.
Original413's incorrect primary-refusal control is retained unqualified; the same
strict history/binding correction precedes both414/415. Related checks complete
17/18 PASS; only unchanged C03/F09 receipt5ms fails. Full reconciliation, retry/crash/recovery, A7/CORE and historical latency
gates stay open. [Exact pair](../../../Tests/Reports/agent-overhaul-closure/p3-task-bridge-production/manager-voice-worker-ownership-production/verifying414415-qualified-results.json).

**Previous bounded implementation,2026-10-04:** task activity freshness qualifies411 RED4/69
→412 SAME69 PASS through the real typed submission/Manager/SQL/journal/effect path.
Accepted corrections refresh heartbeat/lastProgress in the existing transaction;
refusal rolls back and the same Task/attempt/start binding stays exact. Related
checks complete12/14: unchanged receipt5ms and actual ACP history138.97375ms
against100ms fail; both are retained and the ACP producer trace is active.
Full new-attempt/recovery, duplex A7, CORE, latency and
parent acceptance remain open; the parallel agents continue A7 and consequential
receipt verification. [Exact pair](../../../Tests/Reports/agent-overhaul-closure/p3-task-bridge-production/manager-voice-worker-ownership-production/window411412-qualified-results.json).

**2026-10-04 — Typed work and real approval preemption are bounded-verified; roadmap open.**
Typed extraction376 RED15/29 →377 PASS31 is qualified jointly with the strict
permission race382 RED1/40 →383 PASS40: no obsolete card or grant, one retained
read and one revised effect. Existing worker/revision authority is rechecked after
permission enrichment. Integration383 passes29/30 flags, including worker2710,
restoration188, authority58, actual tool loop and write isolation21files32defaults;
its unchanged receipt5ms failure remains retained.

Real approval preemption now passes386 delivery636. Actual384/385 preserved the
correct output, generation, playback token, pending result, current Gate and zero
effects; their sole failure expected the entire prompt during its first streamed
clause. SAME input/control fixture correction checks the exact first clause and
queued remainder, then the exact full prompt after the existing drain. Both native
and phrase owners join. This is software producer/consumer proof, not physical audio.

The task writer386→387 now validates its same locked transaction once: four
schema reads become one through two responsible producers. Ten storage flags and
29/30 integration flags pass; C03 receipt6.075583ms still exceeds5ms. Typed revision journal388 RED5/64 →389 SAME64 PASS now retains instructions
and completed output through restart hold and actual journal refusal;29/30
integration flags pass, inherited5ms still fails. Output tokens390 RED8/23 →391 SAME23 PASS now refuse stale append, finish,
cancel, replay and wrong history attribution;636 scheduler controls and29/30
integration flags pass. Voice revision journal392 RED4/138 →394 SAME138 PASS now persists running
corrections and permission amendments/retries through the same primary transaction;
API40 and29/30 related flags pass. Signing393 and first394 disk-full status corpus
are retained INVALID/incomplete; unchanged394 repeat qualifies. Receipt5ms remains
failed. Delivery priority395 RED10/85 →396 SAME85 PASS (721 scheduler/23 token
checks) retains unheard results without an attempt and refuses replay of heard
results after a committed answer. Related396 passes29/30 after unchanged worker2710
repeat; the first worker history/noReview failure is retained, cause not proven.
ACP399 RED6/47 callback checks and RED3/51 normal post-authorization checks →400
SAME47 PASS/worker2761 PASS. Only Session changes; exact current/refused-hold controls
allow and held/successor/waiting controls refuse after authorization. Related400
passes29/30; unchanged5ms receipt still fails.
Build398 packaging ENOSPC is INVALID; original397 measured waiting-control correction
and its100ms scheduling failure remain retained. Failed Process publication401 RED3/57 →402 SAME57 PASS now preserves the
original permission/notification owner when construction throws;7/7 related flags
pass, priorworker2761 remains green. This repeated Session compatibility proof
does not complete normal effect authority. Question-answer journal403 RED8/163 →404 SAME163 PASS now commits the exact
answer before resuming Work; required journal refusal keeps the saved question.
Strict restart-cancel C25 already passes both via existing authority admission, so
no proposed extra SELECT/guard was added. Related404 completes12/13; only unchanged C03 receipt5ms fails.
Root is checking normal Island ownership through actual local, ACP, typed and scheduled
writers. Build405/406 compile failures are retained INVALID (missing shared title and an
accidental legacy-helper parameter). Their same-COMMON corrections precede both
variants; original407 compiles, but native stops at typed-result qualification
after11/32 checks (INPUT_INVALID). Its97.58s run/maps/sample are retained; no fixed
producer or native ownership verdict is claimed. The actual shared transport cancellation
prerequisite now qualifies408 RED4 →409 SAME cases PASS: the consumed prompt settles
once on task cancellation, sibling reply/notification remains intact and pre-cancelled
requests write no frame. Only JSONRPC changes across1,138 compiler inputs; all six
related flags pass (worker2761/ACP confirmation/MCP/review/receipt5/write isolation).
The unchanged normal Island scenario now qualifies409 RED12/32 →410 SAME32 PASS.
Seven responsible producers preserve conversation ownership through actual local,
ACP, typed and scheduled writers. Related410 completes10/11 functional flags;
unchanged C03/F09 receipt5ms failures stay open. All three consecutive SAME32 Island
runs and five remaining UI/concurrency/task flags pass. The existing duplex flag passes,
but its explicit roadmap A7 Island assertion has not been located; separate source audit
is active. Full CORE, physical presentation and parent acceptance remain open. Parallel agents
reuse existing checkouts for Island, consequential receipt verification and typed
revision activity freshness. Completed artifact cleanup removed six retired trees
and obsolete401/402/403 bundles (about2.68GiB net); useful404 and compact comparison
evidence remain. Prepared source is not acceptance. Full P3/P6/quality/latency,
whole-App read, recovery, IM-16, owner quit/install and clean-checkout delivery stay open.
[Typed joint proof](../../../Tests/Reports/agent-overhaul-closure/p3-task-bridge-production/manager-voice-worker-ownership-production/typed-joint383-qualified-results.json),
[real Gate proof](../../../Tests/Reports/agent-overhaul-closure/p3-task-bridge-production/manager-voice-worker-ownership-production/d3-gate386-qualified-results.json).
<!-- /current-d3-implementation -->

This is a completion checklist derived from [STATUS.md](STATUS.md), not a second
progress ledger. STATUS owns task states and evidence. Phase files retain their
task contracts and dependencies. A verified child does not complete its parent.
Prepared patches, predicted test counts and successful compilation are not product
acceptance. There is no defensible overall completion percentage.

## Current position

The roadmap is **in progress, not finished**. Most Phase 0/1 plumbing is committed,
but the Agent quality gate is still unmet. Phase 2 has instrumentation and measured
failures. Phase 3 has production-path/effect-barrier foundations and bounded shadow
playback repairs; the unified ledger, output scheduler and live ownership migration
are unfinished. Phase 6 has real SQL authority, journalling, held restart, local/ACP
attempt and receipt admission, but not complete recovery, stale monitoring or retry.
Proactivity is partly implemented; optional cloud realtime remains planned.

Latest bounded Phase3 work: canonical progress retains qualified original299 RED11/46 →300 same46 PASS. Status/cancellation now has qualified original310 RED102 →fixed311 functional PASS (285 status,28 stored-copy projections,7 mixed-result controls,17 selector helper checks), with46 progress and57 ownership retained. All28 other integrated flags pass, including delivery, worker2678, restoration188 and isolation21files32defaults. Whole lifecycle remains FAILED solely on unchanged5ms receipt target:5.416916ms. Stable latency stays open. Strict copy/origin/two-row companion COMMON controls ran on both versions; original inputs were not removed. Stored-copy checks are not legal-transition proof, and ordinary punctuated command callsites now pass19 in315 after original314 six actual failures (scripted frontend,0 effects; model/account/effect proof remains open). ACP-by-voice, legal-transition producer, structured frontend receipts and spoken approvals continue in three parallel worktrees. ACP original316 qualifies15 actual routing failures. Scalar320 confirms truthful warned output; strict COMMON full warning/receipt expectations then qualify original321 RED1 closed-ID retirement →fixed322 same78 PASS/whole lifecycle exit0/maps invariant. The reducer retires only genuine terminal IDs while closed;all29 related flags PASS, and prior5ms failures remain retained. Packaging319 ENOSPC and317 signing failures are INVALID. Actual typed original324 reports59 failures/84; introduced325 D8 is retained, then corrected SAME84 COMMON qualifies326 RED2 →327 same84/whole routing PASS and9 related flags. SAME Work retains exact objective and formats raw only in its prompt. Actual model routing-only324/327 both fail the same two calendar cases; first-text deltas-41…612ms are not isolated route-end timings.100ms route-overhead acceptance remains OPEN; full adapter/schema/revision/no-filler/cloud/live/P2 requirements stay open. The current spoken-approval bounded foundation and full legal-transition frontier are distinguished below. Prepared patches are not native acceptance. Parent exits and coherent clean-checkout delivery remain open.

Spoken approval update, 2026-10-04: qualified original344 fails only the session-close playback-scope assertion across505 delivery checks, including221 actual approval checks. Fixed345 passes505 after the existing Scheduler/Gate resets the exact retained weak voice owner; strict validation, exact pending payload and the existing0.350s quiet window remain unchanged. Related345 passed27/29 flags, including worker2710, restoration188 and owner isolation21files32defaults. Actual346 traced the two additional fixture failures: the original amendment now takes the deterministic approval route, commits revision1 and replaces the old card before a model stream. SAME COMMON347 preserves the original words and verifies that route, plus a separate real partial-model correction exercising the effect barrier. Native347 passes505 delivery checks, both duplex correction paths and C06; only the inherited5ms receipt target remains failed. This is a bounded software foundation, not full P3-08 acceptance. Actual348 reproduces six ordered-revision failures across81 checks with existing84 receipt/context20/routing controls green. Its receipt attribution qualifies all eight existing authority landmarks for both C03/F09; both unchanged5ms assertions fail. Fixed349 passes the same81 revision checks and whole routing, with only Coordinator/Manager changed across1124 compiler inputs. Current349 integration finishes28/29 PASS, including worker2710/restoration188/isolation21files32defaults; only inherited5ms fails. No full phase acceptance. Historical334–343 fixture, admission and packaging failures are retained. Physical/account/live, stable latency, full dependencies and full phase gates remain open. Actual side-talk350 reproduces24 failures across52 checks, with81/84/context20 controls green; fixed352 passes the same52/whole routing. The existing current-decision producer now withholds history/review/memory admission for side-talk, finishes silently, and closes through existing Capture tick policy; the held actual worker survives and delivers next session. Only five responsible producers differ across1125 compiler inputs. Packaging351 ENOSPC is INVALID (identical compiler sources to352), not a product pass. Related352 integration completes28/29 PASS; only inherited5ms fails. Live10side/10positive×3 and physical gates remain open. [Actual approval qualification](../../../Tests/Reports/agent-overhaul-closure/p3-task-bridge-production/manager-voice-worker-ownership-production/approval-qualified347-results.json). [Revision original](../../../Tests/Reports/agent-overhaul-closure/p3-task-bridge-production/manager-voice-worker-ownership-production/ordered-revision-original348-qualified.json).

Frontend controls and ACP activity update, 2026-10-04: actual original354 qualifies22 failures in98 frontend schema checks,11 in53 offered model-approval checks, and3 in56 voice ACP activity checks. Fixed355 passes the same three sections and whole routing/delivery558; prior84 typed receipts,81 ordered revisions,52 side-talk and context20 remain green. Only five responsible producers differ across1128 compiler inputs. Related29 finishes28 PASS, including worker2710/restoration188/durability37/authority58/ACP/MCP/confirmation and owner isolation21files32defaults. The unchanged C03/F09 receipt5ms failure remains open. This verifies actual available schemas, captured offered request/edited-payload/revision refusal and the same Manager-bound ACP activity consumer using controlled external frontends/temporary peer. It does not establish real-model quality, physical grants/effects, full client health, FrontendResponder/D3, P2-02 or full parent readiness. [Qualified original/fixed and integration](../../../Tests/Reports/agent-overhaul-closure/p3-task-bridge-production/manager-voice-worker-ownership-production/schema-acp-fixed355-qualified-results.json).

**2026-10-04 — Current-schema save work verified, latency remains open.** Actual356 confirms the existing full-save writer reads schema5 four times and executes one redundant version assignment on both C03/F09. Same COMMON357 records the same four reads and zero assignments after a one-condition change in TaskStoreSchema; COMMIT/CLOSE/authority controls and all other compiler inputs remain unchanged. Ten relevant flags pass, including worker2710, restoration188, authority58, durability37, task-reader40 and write isolation21files32defaults. Whole lifecycle still fails only the unchanged two5ms receipt assertions: this is removal of confirmed unnecessary producer work, **not a latency repair or parent completion**. Two wrapper output-path refusals are retained INVALID; the unchanged early-entry reader40 passes with its established temporary-output runner. [Actual pair and regressions](../../../Tests/Reports/agent-overhaul-closure/p3-task-bridge-production/manager-voice-worker-ownership-production/schema-assignment-fixed357-results.json).

Scoped Dictionary/capability/grounding/Now confinement is applied for the first-entry nonterminal conductor. Native366 stopped before all38 cases: its nonexistent temporary-directory URL guard rejected identical canonical paths because directory hints differ before creation. The Foundation replay confirms that representation defect; after directory creation, the existing shared admission check passes unchanged. This run is **INPUT_INVALID**, not a reproduced product failure. That SAME guard-only correction qualified original367 RED13/38 and fixed369 PASS38; the shared after-creation guard stayed unchanged. Typed activity confinement now runs in376/377, with bounded joint stale-permission acceptance now verified in382/383; full task gates remain open. The live corpus remains queued; historical write invariance does not prove whole mounted-App read isolation, and source-only reviews are not acceptance.


Scheduled completion update, 2026-10-04: original332 reproduces four actual admission/history failures; fixed333 passes the same eight added checks, worker2710 and durability37. Both public and admitted callbacks refuse nonterminal outcomes before cache/SQL/journal/export mutation, preserving the same retained operation and clean return. Only Manager and persistence-result producers differ across1118 compiler inputs; Source/bundle invariance holds. Compile331 is INVALID and preserved; the exact UUID comparison correction precedes both versions. Whole333 lifecycle still fails unchanged C03 receipt5ms; all28 other integration flags PASS, including current typed routing, restoration188 and isolation21files32defaults. Full nonterminal legality, spoken approvals, recovery, effect/health and parent exits remain open.

Terminal continuation update, 2026-10-04: compile328 is INVALID (optional diagnostic access), corrected identically before both versions. Serial original329 confirms13 target failures across33 added checks: voice3, scheduled4 and late-unbound6; durability37 passes. Earlier overlapping329 invocations are preserved as UNQUALIFIED. Serial329 additionally fails unchanged receipt5ms and ACP burst-history134.142916ms against100ms; latency remains open. Same33 fixed330 checks pass through actual consumers: worker2702 and durability37 PASS, no DEBUG trap. Only Manager/TaskStatus/persistence-result producer changes across1118 compiler inputs; source/bundle invariance holds. Whole lifecycle still FAILS unchanged C03 receipt5ms. All28 other integration flags PASS (including unchanged typed84/D8, restoration188 and owner isolation21files32defaults); complete legal transitions, latency, phase/recovery/live ownership and coherent delivery remain open.

The quit crash is additional blocking reliability work, not a completed roadmap
phase. Builds 131–152 were separately staged; these results do not mean a new build
was installed or the original owner's SIGSEGV was reproduced and eliminated.

| Verified bounded work | Actual before/after evidence | Limit |
|---|---|---|
| Production voice route and effect barrier, P3-01/P3-02 | Installed original failures and actual fixed duplex regressions | Does not establish P3 ledger/output ownership |
| SQL/journal, held restart, local/ACP attempts and receipts | Accepted P6-02a/P6-03/P6-04a children and P6-05a…k/P6-06a…p | Does not authorize restart replay or IM-16 |
| Artifacts, verified mail sources and cached card projection | P6-02b-1/2; staged127 RED28 → staged128 worker1908 PASS for -3 | Actual visible UI, unloaded restart and installed verification open |
| Shadow pause/end and Apple resume publication | P3-06a-1/3/4/5/6 qualified producer comparisons | Other backends, full trace coverage and live Island ownership open |
| Knowledge/memory | P4-08a/b, P4-07a and staged155 RED13/70 →156 PASS70 committed-input proof | Native caption/source chips, reader/Assembler and proactive acceptance open |
| Notes quit ownership | Original131 RED3/7 → fixed132 PASS7, later integrated repeats | Original crash and whole-app shutdown open |
| Recording-stop future Notes admission | Original134 RED4/24 → fixed135 PASS24; idle15 preserved | Physical capture is substituted in this fixture |
| Startup ASR/Pocket preparation | Original138 RED9/26 → fixed139 PASS26; exact Pocket repeat passes after invalid ENOSPC run | Some ASR drains took 41–48 seconds; fast quit unproven |
| Shared ASR queue | Original140 RED4/24 → fixed141 PASS24 | Direct dictation and remaining ASR owners open |
| Final transcript ownership | Original143 RED16/77 → fixed144 PASS77 | Fresh-process resume and non-cancellation fallback acceptance open |
| Diarization ownership | Original145 RED24/130 → fixed146 PASS130 | Active preparation and remaining callers open |
| Other llama owners | Corrected original149 RED22/49 → fixed150 PASS49; eleven related flags and selected native integration pass | S1 drain latency and full owner coverage open |
| Model-trial caller publication | Original151 RED4/40 → fixed152 PASS40; only ModelLibraryStore differs in 1,058 compiler inputs | Broader152 regression batch incomplete and has a timing failure |

Shutdown evidence: [VERIFICATION.md](../../../Tests/Reports/agent-overhaul-closure/native-termination-crash-review/2026-10-02-pid41058/VERIFICATION.md).

## Parallel: finish the delegated reliability work

| Item | Exactly what remains | Required proof |
|---|---|---|
| Model-trial integration | Investigate152 `MODEL_UNOPENABLE_FAILED`: inner S1 trial5.8s against unchanged5s budget; finish remaining embed/isolation/worker regressions | Attribute the actual fresh NotesModelRuntime.trial path; keep the failure, do not extend the budget. Roles/library exit successfully; the batch stopped at the failed trial |
| S1 cleanup cancellation | Investigate the separate synchronous S1MiniRuntime normalization loop that does not check cancellation between tokens | Original cancellation/quit producer and real formatter/fallback consumer proof; preserve already-entered native calls and prevent stale text delivery. This is **not** an established cause of the model-trial timing failure |
| Pocket active playback | Apply/rebase reviewed57-check candidate through an isolated observed dependency; retain/join the actual PocketTtsSession generator rather than consumer EOF | Same-input original/fixed native pair, successor playback without waiting for retired work, ordinary upstream-package compile and required regressions |
| Direct dictation finish/cancel | Implement and verify the reviewed33-check actual retired-tail ownership candidate | Real partial/native return, same retained finish chain, stale-publication/injection refusal and unchanged foreground responsiveness |
| Late input after finish | Then verify the separate19-check input-admission candidate | Actual uncancelled late feed cannot create an orphan partial after finish has closed input; successful new start reopens admission |
| Kokoro active playback | Complete public-model digest guards, package observation, rebase and actual49-check candidate verification | Original/fixed real prediction/backing Task ownership and successor PCM; API-return proof must not be relabeled device/kernel cessation |
| Remaining shutdown owners | Audit and cover active diarizer preparation; Apple speech callbacks/loaded stop; opt-in source renderer; long-form synthesis and scheduler work; independent preparation callers; capture/EOU/wake and pending starts | Actual production-owner reproduction and return/admission/consumer checks. Wrapper cancellation, stopped tokens and stream EOF alone are insufficient |
| Whole-app quit | Integrate the accepted owners, preserve interrupted work, measure quit time and exercise the original quitting scenario | Repeatable full-process exit without native work admitted into global teardown; retained resumability and original crash verification. Fast-quit acceptance remains separate |
| Delivery of the changes | Review coherent owned hunks, dependencies, clean-checkout build and relevant regressions before releasing installation | No broad staging, no unrelated UI overwrites, no installed-app quit or installation implied by staged tests |

## Durable work and remote-host prerequisites

| Task | Exactly what remains |
|---|---|
| P6-02b / P6-02b-3 | Finish installed/native approval and result-card source display, real rendering/actions/privacy/accessibility and unloaded-restart behavior. Preserve edited payload, exact source/task/receipt links and honest unknown outcomes. Transparent captures127/128 were UNAVAILABLE, not UI passes |
| P6-04a / P6-04a-3 | Finish real restored permission/input cards and picker; broaden missing-input handling beyond verified file/path, explicit-folder text/query46 and typed tree/folder60 (staged223 fullrestoration188); finish general worker questions; validate retained-history repair routing, interrupted workers and required compatibility/large-history behavior. Fresh-object holds are not process-crash recovery |
| P6-05 | Actual214→215 reaches94.840ms from1330.809ms, worker2161/14 related+reader40 PASS, but integrated217 repeat318.892ms FAIL1 reopens unchanged100ms responsiveness acceptance; qualified cost224/225 now passes2206/13 related and three100ms runs (history65.259/61.994/70.935ms) after confirmed history-cost repair; earlier223small1.8sec spike remains unattributed and large-journal/full latency stays open. Supported periodic/cadence is bounded-verified:227 RED19→229 worker2366/13 related PASS, same retained long-routine/stop/foreground owners and eligible225-second heartbeat-only commit. Local named invocation and scheduled primary admission now pass238 RED21→239 worker2524/17 related; rejected scheduling makes zero model.complete/tool/read/receipt/audit calls. Provider resolution still precedes admission. Scheduled ownership now has241 RED34/154→242 same154 PASS and integrated repeat2678/17 related PASS; the exact per-run Task/attempt/context and cancellation-save-refusal fences are verified. First242 small-history1830.389ms FAIL1 remains unattributed, despite unchanged repeat44.657/57.725ms. Original237 history118.263ms and its passing64.845ms repeat remain retained; timing attribution stays open. Finish actual normal-wallclock cadence, scheduled quarter-window beats/model runtime progress and complete session/tool/receipt/person-wait coverage; this workload is not a universal latency/health bound. Query216/217 now passes the actual128-case restoration flow after COMMON-only canonical timestamp correction; native input card/picker and broader input recovery remain open. Age or a live PID alone cannot decide health or no effect |
| P6-06q, bounded prerequisite verified | Actual153 RED40/151 →154 PASS151,10 launch controls and19 related flags; selected CORE1/1. No remaining bounded offered-option implementation. Keep broader native-tools FAILED1 and parent authority/retry/IM-16 gates open. See [proof](../../../Tests/Reports/agent-overhaul-closure/stale-observation-frontier/acp-offered-option-review/verification.md); guard hashing is not zero-I/O |
| P6-06 | Calendar duplicate verification420 RED38/114 →421 PASS114/worker2933 is bounded-verified through actual CLI process/readback; related42120/21 PASS with inherited receipt5ms failed. Finish current-client/standing-grant/edited-payload and actor-handoff authority; receipt/outcome reconciliation and safe risk-based explicit retry. Cover combined cancellation/throw/save failures and real crash/restart boundaries. Unknown consequential effects never auto-fire; add and dispatch actual task-retry acceptance |
| P6-04b | Join voice work to recovery only after the one ledger, live reducer and output scheduler prerequisites; recover deliveries without recreating approval or repeating effects |
| P6-07 | Task attribution passes36 (175 RED8→176 PASS) through actual local/ACP scopes; read-only reporting now passes20 (182 RED5→183 PASS) and usage/Activity/worker1908/isolation regressions pass. Finish ordinary owner CLI acceptance, live task-detail presentation, complete historical coverage and full dependency acceptance. Preserve nil unknown cost and existing shared-file owners |
| P6-09 | Typed instruction journalling388 RED5/64 →389 PASS64, voice revision journalling392 RED4/138 →394 PASS138 and exact question-answer persistence403 RED8/163 →404 PASS163 are bounded-verified. Same-worker activity411 RED4/69 →412 SAME69 PASS now stamps exact revision/heartbeat/lastProgress through the existing transaction and binding; related41212/14PASS, receipt5ms and ACP history138.97375ms>100 remain failed. Finish explicit recovery re-read/continuation, stale proposal/output separation and actual new-attempt admission. Full task/core/owner/latency gates remain open |
| P6-08 | Same-ledger jobs projection passes23; saved Timeline now passes37 (201 RED6→202 PASS),3tasks/14events through actual row bodies, with five related flags PASS. Finish ordinary owner-positive entry, displayed Activity/Timeline/Needs-you interaction/accessibility and declared output/revision/retry dependencies |
| P6-10 | Implement depth-one fan-out/join and cancellation propagation after retry/revisions/capacity prerequisites; verify actual children and result order |
| IM-16, external dependency | Only then admit the production iMessage host with remote attempt/origin authority, durable reply delivery and crash/sleep/restart acceptance. Current typed-task receipt fixes do not unblock hosting |

Detailed stale/retry obligations: [P6-05 remaining contract](../../../Tests/Reports/agent-overhaul-closure/next-implementation-review/p6-05-closure-contract/README.md).

## Latency and full duplex

| Task | Exactly what remains |
|---|---|
| P0-10 | Immediate EOU-to-tick logic is already implemented; finish actual native endpoint/fallback/late-EOU race acceptance and repair any reproduced producer failure |
| P2-01 | **2026-10-08:** Matched voice-preparation pair ([5bbdf53](../../../Tests/Reports/agent-overhaul-progress/voice-preparation/verification.md)): L1 1.778 -> 0.671 s, L2 3.322 -> 2.448 s, L3 3.777 -> 2.649 s medians; original stall 122 ms -> 36 ms p90. Split-prewarm run ([32209bc](../../../Tests/Reports/agent-overhaul-progress/p2-split-prewarm/verification.md)) is UNQUALIFIED at 4.139 s median audio. Still open: cold duplicate-commit acceptance and the missing original WAV (replacement is a new baseline). **Historical 2026-10-04:** Finish original file-fed latency/cold duplicate-commit acceptance and original stall attribution. Later warm measured stall35ms passes100ms but does not explain the original156ms result. Recover the exact missing original WAV or explicitly record that its repeat is unavailable; a replacement fixture is a new baseline |
| P2-02 | **2026-10-08:** Split-session prewarm verified ([32209bc](../../../Tests/Reports/agent-overhaul-progress/p2-split-prewarm/verification.md)); single streamed decision REJECTED, 12/15 vs split 13/15 ([f6a1fd2](../../../Tests/Reports/agent-overhaul-progress/p2-single-decision-rejected/verification.md)). Remaining: production mode selection, 0.6 s first-token and 0.9 s first-audio gates, two calendar routing failures, native cancellation. **Historical 2026-10-04:** Implement/verify prewarmed frontend sessions and one streamed decision, preserving prompt/cache/route identity |
| P2-04 | **2026-10-08:** No reconciled evidence; the audit lists Smart Turn as unclosed. State stays `todo`. **Historical 2026-10-04:** Implement/verify the Smart Turn arbiter, endpoint debounce/fallbacks after P0-10 |
| P2-03 | **2026-10-08:** Bounded children verified: frozen playback context ([d209b29](../../../Tests/Reports/agent-overhaul-progress/p2-frozen-playback-context/verification.md)), courtesy reuse ([61fadf0](../../../Tests/Reports/agent-overhaul-progress/p2-speculation-courtesy/verification.md)), dictionary-corrected reuse ([22675db](../../../Tests/Reports/agent-overhaul-progress/p2-dictionary-preparation/verification.md)), early lexical preparation ([bfee5fe](../../../Tests/Reports/agent-overhaul-progress/early-lexical-preparation/verification.md)). Remaining: partial->partial cancellation, route-only reuse, native hit rate/speed, dependency on P2-04. **Historical 2026-10-04:** Implement/verify append-tolerant speculation from quiet/early EOU after frontend and arbiter prerequisites |
| P2-05 | **2026-10-08:** Bounded native Silero ducking verified ([5a8a363](../../../Tests/Reports/agent-overhaul-progress/p2-vad-duck/verification.md)): cold duck 0.593321 s still FAILS the 200 ms gate; warm replay 0.1459375 s sample-time is not wall-time. Remaining: <= 200 ms live, physical echo, stable latency. **Historical 2026-10-04:** Implement/verify VAD-driven provisional ducking and resume with real overlapping speech |
| P2-06 | **2026-10-08:** Reply-scoped Pocket session verified ([4c96d09](../../../Tests/Reports/agent-overhaul-progress/p2-pocket-reply/verification.md)): one engine start, first callback 34.032 ms, software gap estimates -9.989 / +9.720 ms; first-clause-early ([33b5baa](../../../Tests/Reports/agent-overhaul-progress/p2-first-speech-chunk/verification.md)) and gap spans ([961d6d8](../../../Tests/Reports/agent-overhaul-progress/p2-pocket-gap-spans/verification.md)) also verified. Remaining: physical gap/prosody, prescribed latency/barge runs, live full duplex. **Historical 2026-10-04:** Finish one PocketTtsSession per reply, synth-ahead, retained engine, clause chunking and actual first-audible acknowledgement. Active-playback shutdown work is a prerequisite, not this task's completion |
| P2-07 | **2026-10-08:** Bounded EOU/Silero/Pocket residency children verified ([ee4b59b](../../../Tests/Reports/agent-overhaul-progress/p2-resident-eou/verification.md), [1952172](../../../Tests/Reports/agent-overhaul-progress/eou-session-reuse/verification.md), [120b72d](../../../Tests/Reports/agent-overhaul-progress/p2-resident-silero/verification.md), [800d6f9](../../../Tests/Reports/agent-overhaul-progress/p2-pocket-prepare-voice/verification.md)). Remaining: live pressure behaviour, quit with active audio, the endSession reopen race, role independence. **Historical 2026-10-04:** Verify safe EOU/Pocket residency and launch/arm prewarm without blocking the user's turn or overriding independent model roles |
| P2-08 | **2026-10-08:** No reconciled evidence; stays `todo`, to be done last. **Historical 2026-10-04:** Measure and tune capture/output buffers after the other hops, preserving acoustic behavior |
| P3-06a / P3-06a-2 | Explicit-cancel event coverage now passes14 (197 RED2→198 PASS) through actual deterministic/parsed cancellation with six related flags. Same-work revision coverage now passes12 (206 RED3→207 PASS), ordered events1/2/3 and six related flags. Finish remaining shadow event coverage, original full native traces, other backend pause/resume receipt ownership, engine-loss/short-tail cases and actual Gate/Island acceptance. Apple positive publication is already verified by -6; do not redo it as missing work |
| P3-03a / P3-03b | Bounded admission/status passes47 (219 RED14→220 PASS) with12 related flags. Metadata/status/task-start original235 RED33/85→fixed236 PASS200 and15 related flags, including unchanged authority58/worker2366; origin/session/userWords, preserved first-start/genuine terminal time and indexed session/status budgeting are verified. The rejected234 legacy/clock failures are preserved and repaired. Typed failure and same-job needsInput continuation now have corrected original244 RED17/52 →246/248 PASS68, prior200/shadow0, plus six same-job routing cases247 RED30 →248 PASS. Public duplicate/pending-approval admission and current-session answer authority now have corrected264 RED26/92/control0→265 same92 PASS and28 related flags. Canonical revision is now bounded-verified: corrected273 RED8/115/control0→274 PASS125 and28 related flags; all76 codec controls, same-worker rejected-effect hold and legitimate retry pass. Historical271/272 authored naming expectation mismatch is measured and corrected beforeboth. Raw invalid-origin/current-session admission now passes275 RED26/89→276 same89/all28; row-only raw admission still needs actual Manager-owned worker dispatch. Public cancel now passes279 RED2/276→280 same276/39 ownership controls and all28 related after repairing introduced278 saved-question routing. Canonical ordered public progress is now bounded-verified299 RED11/46→300 same46 PASS and all29 related flags. Same-Manager worker ownership57, cancellation14 and delivery284 pass; Coordinator.jobs has been removed from the integrated source. Finish complete changed-primary/current-question fencing, waiting-permission/all cancellation states, full status API and actual legal-transition producers; one receipt4.732959ms does not establish stable5ms latency. Status/cancel corpus and voice ACP have the bounded evidence above; terminal absorbing-state33 passes fixed330 with worker2702, all28 other flags PASS and unchanged lifecycle5ms FAILED. Scheduled nonterminal completion refusal is bounded-verified in332/333; finish complete nonterminal legality and broader ACP/session/activity coverage. Actual bound-context ACP activity56 and model approval53 now pass355; prepared follow-up packets are not native acceptance. ACP ownership and broader delivery/live contracts remain open. [Current evidence](../../../Tests/Reports/agent-overhaul-closure/p3-task-bridge-production/canonical-metadata-production/verification.md) |
| P3-04a / P3-04b | Bounded completion delivery is verified250 RED38/123/control0 →253 same123 PASS and all26 related flags. Introduced251 legacy-selection regression is measured252 and repaired253 with retained canonical rows; original249 INVALID stays retained. Status/order/carryover168 is now bounded-verified: corrected original257 RED8/168/control0 →fixed258 PASS168 and all26 related flags. Invalid254–256 expiry inputs remain retained; real terminal row-relative clock qualifies257. Exact pending-question priority/withdrawal now passes corrected260 RED20/276/control0 →261 same276 PASS and all26 related flags. Finish actual approval priority, bounded phrasing, sessionless heads-up and all current output tokens. Finish physical onset/interruption/stale-output acceptance; bounded276 question software callbacks are not physical or full-parent passes |
| P3-05 | Typed84/unchanged legacy D8 now pass327 and integration330 after the Work original/prompt repair. Four canonical schemas are bounded-verified354 RED22/98 →355 PASS98; finish the one concrete frontend owner/decision adapter and D3 phrasing; ordered revised objective/exact raw words are bounded-verified348 RED6/81 →349 PASS; finish wider actual-model/permission cases; verify ordinary no-filler answers, selected real-model/cloud behavior, 100ms route overhead and P2-02 dependency. Current model routing still fails two calendar inputs. |
| P3-07a / P3-07b / P3-07c | Measure capacity and Foundation Models overlap; admit the second local context only under the measured capacity contract, then migrate the local tool worker. Preserve shared artifacts and independent model choices |
| P3-08 | Fixed345 delivery505 passes after qualified original344 C05 failure. Qualified347 resolves C06 and both original/partial-model duplex contracts; finish stable5ms receipt timing and current integrated regressions. The221 actual approval cases have run; they are not an unrun forecast. Finish real playback/permission/native-grant acceptance and the task’s full exit requirements. |
| P3-09 | Current-session Island ownership is bounded-verified409 RED12/32 →410 SAME32 PASS in three consecutive runs through actual local/ACP/typed/scheduled publishers and current playback onset. Fifteen of16 related flags pass; unchanged C03/F09 receipt5ms targets fail. Explicit duplex A7 is now bounded-verified418 RED2 →419 PASS69 with actual worker steps and27/28 related flags. Finish actual Capture endpoint→panel consumer proof, full CORE, physical presentation/interaction and broader dependency acceptance |
| P3-10 | Bounded actual routing/history/memory/close/held-worker carryover now passes350 RED24/52 →352 PASS52. Integration352 is complete28/29 PASS (inherited5ms fails). Finish selected-model10side/10positive×3 after constructor read-isolation repair; then physical/native/D13 acceptance; preserve existing 25s silence behavior |
| P3-11 | Bounded joint producer verified: original376 RED15/29 →377 PASS31, then strict race382 RED1/40 →383 same40 PASS, with repeat and29/30 integration flags PASS. No introduced failure; inherited receipt5ms stays open. Finish installed/displayed Agent pane, current CORE, real-model/account/permission and full ledger/frontend dependency acceptance; typed exact-signature cancellation semantics pass, while the proposed symbolic CancelReason API is not yet implemented |
| P3-06b | **2026-10-08:** Unchanged: `VoiceSession.swift` line 6 still `enum Mode { case shadow }` (checked 2026-10-08). **Historical 2026-10-04:** Switch the reducer from shadow to live ownership only after ledger/output/frontend/approvals/Island routes and divergence gates pass |

Optional, not mandatory closure work: P2-03b upstream EOU callback PR; P3-07d fallback
conversational lane. Preserve the phase files' conditions rather than treating either
as a necessary new implementation.

## Agent answers, memory and proactive behavior

| Task or acceptance gap | Exactly what remains |
|---|---|
| Phase0/1 quality and P1-31 | **2026-10-08:** Mini quick 10/10 x3 ([52c7e4d](../../../Tests/Reports/agent-overhaul-progress/native-quick-d32b123/verification.md)) then 9/10 x3 with A02 ungrounded ([daf325e](../../../Tests/Reports/agent-overhaul-progress/a02-page-inspection/verification.md)); full 25/30 and 23/30, owner 9/10, required 8/9 ([da6e668](../../../Tests/Reports/agent-overhaul-progress/r01-write-after-read/verification.md)). Remaining: repair K03/R01/R03/F02/A02/O08 (and R02/N03 in run 2) at their producers, qualify one coherent artifact, repeat full/owner; thinking/vendor-sampler candidates were withheld ([703e498](../../../Tests/Reports/agent-overhaul-progress/mini-thinking-qualification/verification.md)); required-flag accounting is 16 PASS / 4 FAIL ([09a7eec](../../../Tests/Reports/agent-overhaul-progress/acceptance-accounting/verification.md)). **Historical 2026-10-04:** Complete paired real-model ordinary/Needle-first evaluation, remaining candidates and live negatives; investigate missed/wrong tools and grounding at their producers; run repeated full/owner gates before any model/default promotion |
| P1-05 acceptance | Native/constrained tooling remains opt-in pending its prescribed repeated full evaluations; helper grammar success does not promote the default |
| P1-10b streamed completion gap | Carry streamed finish/cutoff information through the real provider/planner contract; the existing final-answer complete path does not establish streamed planner completion |
| P1-23 live acceptance | Run physical user-takeover/yield cases and measure latency with the real permitted foreground event path |
| P1-28 remaining implementation/acceptance | Context was not resized. Measure capacity and implement the justified context-sizing change, then run prefix-cache R1/R3 on the actual Agent model; pure90% stable-prefix evidence is not those measurements |
| P4-03 | Finish shared identity/persona/depth prompts and useful action-oriented typed/voice behavior, without prompt changes hiding faulty tool producers |
| P4-02 | Previous completed exchange now passes20 actual composer/route/SDK checks (211 RED8→212 PASS) and eight related flags. Finish native classifier/semantic deflection re-route-once, P2-02/P4-03 dependencies and latency/full acceptance; no extra inference pass is proven |
| P4-04 | Complete hosted meeting-start trigger → brief → card/notification → consent → delivery. Reader-aware brief prerequisite is already verified |
| P4-05 | Produce grounded post-meeting owed items and suggestions, fitting the reader and preserving source/consent |
| P4-06 | Host morning digest, owed-item nudges and next-step pending intents; verify relevance, quiet hours, once-only offers and approval |
| P4-07 | The actual committed typed/voice hooks and negative cases now pass70 with six related flags. Finish visible native Remembered caption/interaction, prescribed live statement/full/CORE and latency acceptance. Quick156 is3/10 FAILED; retained background short-fact skips belong to P4-11. [Functional proof](../../../Tests/Reports/agent-overhaul-closure/explicit-memory-production/verification.md) |
| P4-08 | Typed route now passes unchanged59 checks (161 RED18 →162 PASS); finish native citation interaction. Reader-scaled cache/prompt budgets and Assembler output now pass51 (163 RED17 →164 PASS); unique file-source producer passes5 (190 RED2→191 PASS) with four related flags PASS; finish scheduled forwarding after MemoryReview metadata and explicit capacity forwarding now passes31 (171 RED4→172 PASS); prove the genuinely loaded provider-window contract. Initial planner timing failure retained despite passing original/recheck. Verify loaded provider capacity and full parent cases beyond accepted KnowledgeAsker fitting children |
| P4-09 | Verify capable typed/background model routing with separate opt-in consent and usage provenance; reuse exact shared files without changing other module choices |
| P4-10 | Same-reader fitting and earlier asks now pass31 (184 RED9→185 PASS), with five related flags PASS. Transcript-owned evidence now passes89 (187 RED11→189 PASS) with five related flags PASS. Finish compact small-reader prompt/tool selection/rounds, persisted failures/UI, actual loaded/Apple and six owner-meeting/full acceptance. Selected-role answer acceptance is unavailable at existing Keychain lookup |
| P4-11 | Relevant-fact prompt and short-fact harvest now pass71 with unchanged explicit70. Skip/update/totals now pass63 (169 RED28→170 PASS), preserving reader71/explicit70. Provider snapshot capacity now passes28 (173 RED7→174 PASS). Past/modal environment repair now passes60 through the actual writer (180 RED30→181 PASS), retains six durable controls and prior232 checks; five related flags pass. Preference-subject repair is now bounded-verified:204 RED4/189→205 PASS189/prior292 and six related flags PASS, including both unchanged MEMORY merge/correction flows. Scripted precision19/19 and original recall25/27 preserved; historical failed and invalid controls retained. No further bounded subject repair is currently required. Then finish genuinely loaded factory capacity, real local/cloud review quality, native Settings interaction and prescribed full/CORE acceptance. Settings diagnostic process-exit crash is verified resolved in179; live pane interaction and the original owner quit crash remain open. [Proof](../../../Tests/Reports/agent-overhaul-closure/memory-review-production/reader-harvest/verification.md) |
| P4-12 remaining acceptance | Exercise attended/native Apple routine inference and real digest/long-form output; the committed16-case producer slice does not prove these |
| P4-13 | Complete attended first-use consent and granted/denied/offline defaults for proactive meeting features |

## Computer, product journeys and optional cloud

| ID | Exact remaining exit |
|---|---|
| CU-01 | Existing CDP original/fixed baseline and latency are recorded; finish adversarial native AX/coordinate baseline and environment-qualified evidence |
| CU-02 | Single-action/no-uncertain-replay repair is committed; finish actual AX/uncertain-delivery and full task regressions. Retained first fixed report has one yield failure; later installed CDP asserts all11 checks pass, not full CU acceptance |
| CU-03 | Atomic same-control CDP action is implemented using observed backendNodeID and consumed snapshot; finish current full reorder/duplicate/tab/stable/consent acceptance, preserving that producer |
| CU-04 | Bind coordinate actions to captured target, geometry, focus, tab, resize and age; preserve consent |
| CU-05 | Run live granted AX/yield/coordinate/vision behavior, safety regressions and same-pair p50/p95 guard-overhead acceptance; recorded CDP speed alone is insufficient |
| X01 | Same identity across home, office, meetings and voice |
| X02 | Remove the current AgentView messages.suffix(40) display limit through the existing history seam; verify correctable linked history survives relaunch/search with >40 messages and stable scroll |
| X03 | Honest progress, approval, cancel/unknown outcomes and restart states |
| X04 | Two consecutive home/dictation/Mac-app journeys with verified or honestly stopped outcomes |
| X05 | Meeting owed item → one review → confirmed follow-through, no stale nudge |
| X06 | Seven-day proactive fixture plus attended trial without duplicates, irrelevance or quiet-hours violations |
| X07 | Journey feedback and interruptions meet the Phase2/3 latency/full-duplex exits |
| X08 | Paired-device message authority and truthful offline state; call claims only after live call suite |
| X09 | Fresh-profile granted/denied/offline first-use paths reach a useful action or one clear next click |
| X10 | Source/outgoing content, consent/privacy and negative safety journeys proved |
| X11 | Dated website claim ledger and three outside users completing guided jobs |
| P5-01 | Optional cloud FrontendResponder seam after the required Phase3/consent contracts |
| P5-04 | Actual registered loopback cloud acceptance server before provider integration |
| P5-02 | Opt-in OpenAI realtime frontend with Keychain and explicit consent; functional/privacy/latency proof |
| P5-03 | Gemini Live only if the declared non-blocking contract is supported and verified; otherwise record the required gated verdict |

Phase5 is optional product scope; if it remains in the roadmap, report it as deferred
or unfinished, never silently complete it.

## Final acceptance and integration

1. Investigate introduced failures and run the required functional/privacy/permission
   regressions on the coherent final sources, with real process exit and final markers.
   Then review owned commits and prove the clean checkout builds. No current whole-tree
   clean-checkout/installed152 acceptance is claimed.
2. Keep the quick bar at9/10. Latest completed aggregate quick156 is3/10; later quick162 timed out without a score. Run two full passes ≥25/30 with every required owner case, zero
   LEAK/ERROR, and the prescribed Apple no-fabrication evaluation.
3. Resolve/recheck the known wake failure. CORE126 is21/22, with wake17/24 hits and
   3/32 false positives; it is not a current152 core run. Preserve historical
   intermittent dictation/computer failures until their original flows are verified.
4. Meet actual warm first-audio ≤0.9s over five measured turns, main-actor stall
   ≤100ms, duck ≤200ms and inter-clause gap ≤50ms. Last completed warm median2.894s
   remains a failure. Static/presented-window timestamps are not displayed-frame or
   audible-onset proof.
5. Implement/register any still-missing prescribed acceptance entry points before
   counting them: tts-pipeline, voice-duck, smart-turn, voice-overlap, proactive,
   realtime-cloud, task-retry and task-graph currently have no matching Swift
   implementation/dispatch references in this source audit. Similar helper flags
   do not substitute for their contracts.
6. Run real voice/acoustic/microphone/speaker, approvals, interruption, takeover,
   scrolling/selection/focus/VoiceOver and restart checks in a supported permitted
   environment. Transparent offscreen capture and denied Computer Use are unavailable
   evidence, not success. Coordinate UI owner slots; do not overwrite parallel work.
7. Verify durable crash/sleep/restart/effect/delivery cases before enabling IM-16 or
   promoting recovery/retry. Finish X01–X11 and the claims/user proof before claiming
   the full product promise.

## Execution order and outside prerequisites

The active main sequence is P3-03/P3-05/P3-08. Root has qualified ACP78 and closed-terminal retirement321→322; typed84 and unchanged D8 pass326→327; terminal33 passes329→330 with worker2702 and all28 other integration flags. Whole330 lifecycle still fails unchanged receipt5ms. Model routing324/327 still fails the same two calendar cases; isolated100ms overhead is unmeasured. These remain open acceptance, not reasons to halt independently testable work.

Scheduled completion refusal now has original332 RED4 →fixed333 same8 PASS, worker2710/durability37 and all28 other integration flags PASS (unchanged lifecycle5ms FAILED); compile331 is INVALID and the identical typed correction precedes both versions. Next verify spoken approvals221, revised objective81, actual ACP activity56, four frontend schemas and complete nonterminal legal-transition production. Three isolated parallel agents prepare those exact producers and same-input regressions. Root alone applies reviewed relative hunks and runs staged compilation/native/model checks. No installed-app quit, installation, whole-file staging or phase promotion is implied.

The current P3 work is a bounded foundation over the already verified primary-store/restoration contracts, with root serial ownership of AgentTaskManager. It does not complete P6-04a or permit the full P3-03b ownership migration. Complete the named restoration/recovery and P6-05/06 outcome/retry contracts before their dependent live ownership and remote-host switches. Keep the README §4.1 file-ownership rule and every task's behavioral prerequisites. Reliability/quit work is delegated separately and retains its mandatory release gates; it does not replace roadmap execution. Quality investigations proceed independently under the approved9/10 entry exception.

No user decision is needed for this internal implementation/documentation work.
Later live acceptance requires an unlocked supported machine, appropriate OS grants,
attended one-time consequential approval where a test actually performs a write,
and chosen-provider credentials/consent for optional cloud. The missing original
latency WAV and denied native UI access are evidence limitations to resolve; they
do not block independently testable implementation. Do not ask the user to relay
peer coordination or treat unavailable acceptance as a pass.

**2026-10-03 — bounded public voice admission accepted.** Corrected264 RED26/92/control0→265 same92 PASS, prior200/outcome68 and28 related flags PASS. Duplicate held/terminal intake retains one task, same-session approval blocks new intake, omitted/wrong/closed/replaced-session answer starts no backing, and exact current answer continues once. Historical262/263 cache-vs-primary timestamp controls remain invalid; same stored-clock control qualifies264/265. Raw origin/full API, canonical revisions, ACP/jobs migration, physical/5ms, quality/latency and phase gates remain open. [Evidence](../../../Tests/Reports/agent-overhaul-closure/p3-task-bridge-production/public-spawn-resume-production/verification.md).
