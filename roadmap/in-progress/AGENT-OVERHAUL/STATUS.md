# AGENT-OVERHAUL status ledger

> ## Reconciled 2026-10-08
>
> Documentation-only pass from the [status audit](../../../Tests/Reports/agent-overhaul-progress/2026-10-08-status-audit.md) and the compact reports it links (each
> `verification.md` below is a committed report; the SHA shown is the **report's** commit, not a
> product-source commit). No build, model run, install or source edit was made. **No overall
> completion percentage is asserted** and the number of child rows says nothing about parent
> progress.
>
> **What changed in this file:** (1) this block; (2) P2-03, P2-05, P2-06 and P2-07 moved
> `todo` -> `in progress (bounded children verified)` because bounded producer fixes with
> original-red/fixed-green evidence exist; their parent exits are open; (3) P2-01 and P2-02 gained
> dated evidence, state unchanged; (4) P3-06b, P4-06 and P6-04a gained dated notes, state
> unchanged; (5) the Phase 1 gate row is labelled Historical and the current readings are below;
> (6) the 2026-10-04 blocks further down are labelled Historical. Nothing was deleted.
>
> | Reading (2026-10-06 unless stated) | Value | Artifact | Report |
> |---|---|---|---|
> | Mini quick, native planner, baseline sampler | **10/10, 10/10, 10/10**; 106.9 / 107.7 / 107.7 s | installed `d32b123`, binary `6d05b824...` | [52c7e4d](../../../Tests/Reports/agent-overhaul-progress/native-quick-d32b123/verification.md) |
> | Mini quick, later install | **9/10, 9/10, 9/10**; 93.0 / 95.3 / 103.4 s (min/median/max); A02 UNGROUNDED in all three | installed `c2b11e7` (binary `0990a31e...`) | [daf325e](../../../Tests/Reports/agent-overhaul-progress/a02-page-inspection/verification.md) |
> | Mini full + owner, latest retained pair | **25/30 and 23/30**; owner **9/10 both**; required O01-O09 **8/9**, O08 REFUSAL both; run 1 fails K03/R01/R03/F02/A02/O08, run 2 adds R02/N03; zero ERROR/TIMEOUT/LEAK/FABRICATED | installed `2afe575` (staged `d3e48ca5`) | [da6e668](../../../Tests/Reports/agent-overhaul-progress/r01-write-after-read/verification.md) |
> | Mini full + owner, earlier pairs (kept, not erased) | `a5b443c`: 25/30, 24/30, owner 9/10 both, required 8/9, O08 REFUSAL ([b015676](../../../Tests/Reports/agent-overhaul-progress/mini-full-a5b443c/verification.md)); `ae5af51`: 25/30, 26/30, owner 8/10 both, O1-O9 7/9 both ([e65fee7](../../../Tests/Reports/agent-overhaul-progress/native-full-ae5af51/verification.md)); `e118639` (sources `2ec0efd` + grader `4683f7f`): 25/30, 26/30, O01-O09 and O10 pass both ([fa92b3a](../../../Tests/Reports/agent-overhaul-progress/current-quality/verification.md)) | see links | see links |
> | Required-flag accounting | **16 PASS / 4 FAIL** on 20 retained logs (native Mini optional-tool calls 0/4, voice grounding, Needle function calls, unsigned-in Composio open); historical, not a fresh run | `69115eb` | [09a7eec](../../../Tests/Reports/agent-overhaul-progress/acceptance-accounting/verification.md) |
> | Voice preparation, matched pair (1 warm-up + 5 turns) | median L1 onset->preparation **1.778 -> 0.671 s**; L2 endpoint->first token **3.322 -> 2.448 s**; L3 endpoint->first audio **3.777 -> 2.649 s**; main stall 122 ms (fails the 100 ms limit) -> 36 ms p90 | original vs fixed, same authored WAV | [5bbdf53](../../../Tests/Reports/agent-overhaul-progress/voice-preparation/verification.md) |
> | Split-prewarm, Apple answer + Pocket, 5 counted turns | speech-end->audio min/median/max **3.788 / 4.139 / 4.241 s**; diagnostic **UNQUALIFIED** (warm-up counted two commits); exit 1 on the 0.9 s gate | installed `eac522c` | [32209bc](../../../Tests/Reports/agent-overhaul-progress/p2-split-prewarm/verification.md) |
> | Pocket reply session | first played callback **34.032 ms** (240-sample head), software gap estimates **-9.989 / +9.720 ms**, one engine start, ordered receipts; not acoustic silence | staged binary `2c47f999...` | [4c96d09](../../../Tests/Reports/agent-overhaul-progress/p2-pocket-reply/verification.md) |
> | VAD ducking | cold duck **0.593321 s vs 200 ms: still FAILS** (sole VOICE_BARGE failure); warm replay duck 0.1459375 s sample-time (not wall-time) | binary `8108942b...` | [5a8a363](../../../Tests/Reports/agent-overhaul-progress/p2-vad-duck/verification.md) |
> | Single streamed decision | **rejected**: single 12/15 vs split 13/15 on the same 15 authored cases | split path kept at `800d6f9` | [f6a1fd2](../../../Tests/Reports/agent-overhaul-progress/p2-single-decision-rejected/verification.md) |
> | Mini C1 decode with ASR on M3/16 GB | 604.28 s, 96 rounds, median **42.20 tok/s**, p10 **36.14**; peak RSS 1,965,965,312 B; C1 decode only | installed `22675db` | [dfdc40c](../../../Tests/Reports/agent-overhaul-progress/c1-mini-decode/verification.md) |
> | Catch-up core | scheduler integration + decoded 19.36 s sample; Catch-up regression original 8 failures -> pass | see report | [5c7df10](../../../Tests/Reports/agent-overhaul-progress/catch-up-core/verification.md) |
> | Thinking / vendor-sampler candidates on Mini | **withheld**: baseline 9/9/9 vs vendor-only 5/5/5 vs thinking candidate TIMEOUT ([703e498](../../../Tests/Reports/agent-overhaul-progress/mini-thinking-qualification/verification.md)); combined candidate 5/10 ([cfbceeb](../../../Tests/Reports/agent-overhaul-progress/thinking-native-qualification/verification.md)); vendor-only 3/10, baseline-sampler thinking 9/10 once ([fe89d0b](../../../Tests/Reports/agent-overhaul-progress/thinking-sampler-arms/verification.md)); baseline 9,10,10 vs vendor 5,5,4 ([602f60e](../../../Tests/Reports/agent-overhaul-progress/sampler-comparison/verification.md)) | no default or setting changed | see links |
>
> **Gate readings that stay OPEN, and why**
> - **Phase 1:** quick is 9/10-10/10 on the Mini artifacts above, but the full gate (two consecutive full runs >= 25/30, all mandatory owner cases O01-O09, zero refusal) is **not met on the latest retained pair** (25/30 then 23/30; O08 refuses). An earlier artifact's passing pair does not erase later failures. The Apple FM full run (0 FABRICATED) and refusal=2 checks are not recorded in the reports read here.
> - **Phase 2:** L1/L2 are 0.671 s / 2.448 s against the owner's 200 ms; first audio 2.649 s (matched pair) and 4.139 s median (split-prewarm run) against 0.9 s; cold duck 593 ms against 200 ms; Smart Turn (P2-04) and audio buffers (P2-08) have no reconciled evidence and stay `todo`.
> - **Phase 3:** `VoiceSession` still declares `enum Mode { case shadow }` (checked in source 2026-10-08, `Sources/NextNotes/Agent/Duplex/VoiceSession.swift` line 6); P3-06b stays `todo`. `UI/Agent/AgentView.swift` still shows `messages.suffix(40)` (line 97), so X02 is untouched.
> - **Phase 4:** a scheduled text-first Catch-up with saved speech rendering exists; hosted meeting briefs, owed items/nudges (P4-05/06), attended first-use journeys and factual meeting quality are open.
> - **Phase 5:** unchanged, planned. **Phase 6:** SQL authority/journal/held restart/bounded explicit recovered-read continuation exist; broader crash recovery, safe retry/reconciliation, restored UI and remote iMessage hosting (IM-16) remain unqualified.
>
> **Unverified by this pass:** every number above is copied from the cited report; none was re-run. The 2026-10-06 live-freeze incident fixes ([811f3bb](../../../Tests/Reports/live-freeze-2026-10-06/task-remount/verification.md), [0cd52da](../../../Tests/Reports/live-freeze-2026-10-06/voice-readiness/verification.md), [cb6a40f](../../../Tests/Reports/live-freeze-2026-10-06/message-send/verification.md), [6db5693](../../../Tests/Reports/live-freeze-2026-10-06/message-store/verification.md), [8f7c029](../../../Tests/Reports/live-freeze-2026-10-06/native-controls/verification.md), [dfd2651](../../../Tests/Reports/live-freeze-2026-10-06/meeting-diagnostic/verification.md), [97b4187](../../../Tests/Reports/live-freeze-2026-10-06/calendar-errors/verification.md), [31d12ee](../../../Tests/Reports/live-freeze-2026-10-06/wispr/verification.md)) are bounded producer repairs; the roughly 44.5 GB incident spike was **not reproduced** and is not declared fixed. Meeting, calendar and Wispr items belong to other roadmaps and are only cross-referenced.

**Historical (2026-10-04 working notes, superseded where they conflict with the Reconciled 2026-10-08 block above; kept verbatim below):**

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


> **OWNER DIRECTION, 2026-10-04 — read before your next step.** Priorities changed: stop new
> P6/ACP/receipt/lease slices; commit verified work today; then the five quick-gate producer
> fixes, the Claude packets (PL-11, PL-08/09) and the PL-01/02 floor bake-off. Full brief:
> [`../POSITIONING-AND-LOCAL-MODEL/research/CODEX-STEERING-2026-10-04.md`](../POSITIONING-AND-LOCAL-MODEL/research/CODEX-STEERING-2026-10-04.md).
> Audit: [`CODEX-AUDIT-2026-10-04.md`](../POSITIONING-AND-LOCAL-MODEL/research/CODEX-AUDIT-2026-10-04.md).

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

## Historical: Current position — reconciled 2026-10-04 (superseded where it conflicts with the 2026-10-08 block at the top)

**Not finished.** [Exact remaining work](REMAINING-WORK.md) lists all open P tasks,
CU/X exits, acceptance gaps in bounded/done rows and the additional quit-crash work.
It is a derived checklist; this file retains the states and evidence. No completion
percentage is inferred from the number of split child tasks.

| Area | Actual progress | Still open |
|---|---|---|
| Agent answers/tools | Phase0/1 plumbing and bounded grounding/context fixes committed | Quick9/10 and repeated full/owner gates; P1-31; live native-tools/cache/takeover acceptance |
| Latency | Production spans, usage joins and actual native measurements | Warm median2.894s vs0.9s; original/cold duplicate flow, remaining P2 work and endpoint/duck/gap/stall acceptance |
| Full duplex | P3-01/02 actual route/effect barrier; bounded shadow/Apple playback repairs | Complete shadow coverage, shared ledger, output scheduler, receipt-first decisions, approvals/Island and live reducer migration |
| Durable jobs | SQL authority/journal, held restart, local/ACP primary/attempt/receipt and nested admission children verified | Artifact/UI restart acceptance, broader pending cards, true progress/stale coverage, outcome reconciliation, retry, revisions/deliveries/graphs and IM-16 |
| Memory/proactivity | Memory lineage, routine/Knowledge fitting and actual committed typed/voice memory hooks verified | Native remembered feedback, scheduled forwarding/loaded capacity, native caption/source-chip interaction, hosted journeys and quality |
| Cloud/computer/product exits | Existing seams and task briefs | P5 optional implementation, CU-01…05 and X01…11 exits; no blanket completion |
| Quit reliability | Notes7, recording24+idle15, startup26, ASR24, final77, diarization130, other-llama49 and parent-caller40 bounded proof | Playback/direct capture/remaining owners; original crash, full safe/fast quit and installation release |

Latest aggregate quick156 is3/10 against9/10, exit1 with Source/bundle invariant.
Historical CORE126 is21/22 with the known wake failure; no current full CORE pass is claimed. Latest
parent original151 fails four target assertions across40 qualified checks;
fixed152 passes the same40, with only ModelLibraryStore changed across1,058 compiler
inputs. Its related roles/library invocations exit successfully, but
`MODEL_UNOPENABLE_FAILED` reports an inner trial5.8s against5s. The batch stops there;
embed/isolation/worker have not run in this152 batch. Integration is not green.

The timing failure uses a fresh NotesModelRuntime.trial capped at8 tokens, not
S1MiniRuntime.normalize's separate1200-token cleanup loop. No recorded per-stage
trace attributes the5.8s cause. Keep both investigations separate and the budget
unchanged. Parent proof links: [original151](../../../Tests/Reports/agent-overhaul-closure/native-termination-crash-review/2026-10-02-pid41058/native-verification/original151-trial-parent-qualified-results.json),
[fixed152](../../../Tests/Reports/agent-overhaul-closure/native-termination-crash-review/2026-10-02-pid41058/native-verification/fixed152-trial-parent-qualified-results.json),
[actual failing integration](../../../Tests/Reports/agent-overhaul-closure/native-termination-crash-review/2026-10-02-pid41058/native-verification/regression152-model-unopenable/run.json).

P6-05/P6-06 and P3-06 parent states now say **in progress** because their verified
children already exist; parent exits remain open. P6-06q is now bounded-verified:
staged original153 RED40/151 → fixed154 PASS151 with identical actual requests,
approvals and fixture; 10 strict launch negatives and 19 related flags pass.
The broader native-tools grammar gate remains FAILED1, reproduced in original153
under the same300s budget. CORE selected only this new flag: 1/1 PASS. No install
or full CORE/model/phase promotion. [Actual proof](../../../Tests/Reports/agent-overhaul-closure/stale-observation-frontier/acp-offered-option-review/verification.md).
The ordinary Gate diagnostic path retains its existing startup read limits. Pocket57, direct33/
late-input19 and Kokoro49 are prepared counts, not passing product results.

Current internal implementation needs no owner decision. Native interaction/grants,
the missing original latency WAV, outside-user journeys and optional chosen-provider
access remain explicit acceptance prerequisites, not reasons to halt independent work.

**2026-09-30 owner decision:** independent models for Agent, meetingNotes and cleanup;
verified artifacts shared through the existing library. SHARED-BRAIN/SB tasks now
preserve separate role choices/cloud IDs/consent and own request/model binding.
MiniCPM cleanup + Apple guard/fallback is concurrent OpenCode work. Read the revised
[contract](../SHARED-BRAIN/00-README.md) and
[BUILD-ORDER](../../BUILD-ORDER.md). That architecture amendment changed no task state; the dated P1-31 investigation below records subsequent implementation evidence.

This is the only progress record. Update it after every task, following step 12 in
`00-README.md` §5.

Spoken approval update, 2026-10-04: qualified original344 fails only the session-close playback-scope assertion across505 delivery checks, including221 actual approval checks. Fixed345 passes505 after the existing Scheduler/Gate resets the exact retained weak voice owner; strict validation, exact pending payload and the existing0.350s quiet window remain unchanged. Related345 passed27/29 flags, including worker2710, restoration188 and owner isolation21files32defaults. Actual346 traced the two additional fixture failures: the original amendment now takes the deterministic approval route, commits revision1 and replaces the old card before a model stream. SAME COMMON347 preserves the original words and verifies that route, plus a separate real partial-model correction exercising the effect barrier. Native347 passes505 delivery checks, both duplex correction paths and C06; only the inherited5ms receipt target remains failed. This is a bounded software foundation, not full P3-08 acceptance. Actual348 reproduces six ordered-revision failures across81 checks with existing84 receipt/context20/routing controls green. Its receipt attribution qualifies all eight existing authority landmarks for both C03/F09; both unchanged5ms assertions fail. Fixed349 passes the same81 revision checks and whole routing, with only Coordinator/Manager changed across1124 compiler inputs. Current349 integration finishes28/29 PASS, including worker2710/restoration188/isolation21files32defaults; only inherited5ms fails. No full phase acceptance. Historical334–343 fixture, admission and packaging failures are retained. Physical/account/live, stable latency, full dependencies and full phase gates remain open. Actual side-talk350 reproduces24 failures across52 checks, with81/84/context20 controls green; fixed352 passes the same52/whole routing. The existing current-decision producer now withholds history/review/memory admission for side-talk, finishes silently, and closes through existing Capture tick policy; the held actual worker survives and delivers next session. Only five responsible producers differ across1125 compiler inputs. Packaging351 ENOSPC is INVALID (identical compiler sources to352), not a product pass. Related352 integration completes28/29 PASS; only inherited5ms fails. Live10side/10positive×3 and physical gates remain open. [Actual approval qualification](../../../Tests/Reports/agent-overhaul-closure/p3-task-bridge-production/manager-voice-worker-ownership-production/approval-qualified347-results.json). [Revision original](../../../Tests/Reports/agent-overhaul-closure/p3-task-bridge-production/manager-voice-worker-ownership-production/ordered-revision-original348-qualified.json).

Frontend controls and ACP activity update, 2026-10-04: actual original354 qualifies22 failures in98 frontend schema checks,11 in53 offered model-approval checks, and3 in56 voice ACP activity checks. Fixed355 passes the same three sections and whole routing/delivery558; prior84 typed receipts,81 ordered revisions,52 side-talk and context20 remain green. Only five responsible producers differ across1128 compiler inputs. Related29 finishes28 PASS, including worker2710/restoration188/durability37/authority58/ACP/MCP/confirmation and owner isolation21files32defaults. The unchanged C03/F09 receipt5ms failure remains open. This verifies actual available schemas, captured offered request/edited-payload/revision refusal and the same Manager-bound ACP activity consumer using controlled external frontends/temporary peer. It does not establish real-model quality, physical grants/effects, full client health, FrontendResponder/D3, P2-02 or full parent readiness. [Qualified original/fixed and integration](../../../Tests/Reports/agent-overhaul-closure/p3-task-bridge-production/manager-voice-worker-ownership-production/schema-acp-fixed355-qualified-results.json).

**2026-10-04 — Current-schema save work verified, latency remains open.** Actual356 confirms the existing full-save writer reads schema5 four times and executes one redundant version assignment on both C03/F09. Same COMMON357 records the same four reads and zero assignments after a one-condition change in TaskStoreSchema; COMMIT/CLOSE/authority controls and all other compiler inputs remain unchanged. Ten relevant flags pass, including worker2710, restoration188, authority58, durability37, task-reader40 and write isolation21files32defaults. Whole lifecycle still fails only the unchanged two5ms receipt assertions: this is removal of confirmed unnecessary producer work, **not a latency repair or parent completion**. Two wrapper output-path refusals are retained INVALID; the unchanged early-entry reader40 passes with its established temporary-output runner. [Actual pair and regressions](../../../Tests/Reports/agent-overhaul-closure/p3-task-bridge-production/manager-voice-worker-ownership-production/schema-assignment-fixed357-results.json).

Scoped Dictionary/capability/grounding/Now confinement is applied for the first-entry nonterminal conductor. Native366 stopped before all38 cases: its nonexistent temporary-directory URL guard rejected identical canonical paths because directory hints differ before creation. The Foundation replay confirms that representation defect; after directory creation, the existing shared admission check passes unchanged. This run is **INPUT_INVALID**, not a reproduced product failure. A guard-only correction must precede both qualified original/fixed runs. Typed activity and live corpus successors remain queued; historical write invariance does not prove whole mounted-App read isolation, and source-only reviews are not acceptance.


Scheduled completion update, 2026-10-04: original332 reproduces four actual admission/history failures; fixed333 passes the same eight added checks, worker2710 and durability37. Both public and admitted callbacks refuse nonterminal outcomes before cache/SQL/journal/export mutation, preserving the same retained operation and clean return. Only Manager and persistence-result producers differ across1118 compiler inputs; Source/bundle invariance holds. Compile331 is INVALID and preserved; the exact UUID comparison correction precedes both versions. Whole333 lifecycle still fails unchanged C03 receipt5ms; all28 other integration flags PASS, including current typed routing, restoration188 and isolation21files32defaults. Full nonterminal legality, spoken approvals, recovery, effect/health and parent exits remain open.

Terminal continuation update, 2026-10-04: compile328 is INVALID (optional diagnostic access), corrected identically before both versions. Serial original329 confirms13 target failures across33 added checks: voice3, scheduled4 and late-unbound6; durability37 passes. Earlier overlapping329 invocations are preserved as UNQUALIFIED. Serial329 additionally fails unchanged receipt5ms and ACP burst-history134.142916ms against100ms; latency remains open. Same33 fixed330 checks pass through actual consumers: worker2702 and durability37 PASS, no DEBUG trap. Only Manager/TaskStatus/persistence-result producer changes across1118 compiler inputs; source/bundle invariance holds. Whole lifecycle still FAILS unchanged C03 receipt5ms. All28 other integration flags PASS (including unchanged typed84/D8, restoration188 and owner isolation21files32defaults); complete legal transitions, latency, phase/recovery/live ownership and coherent delivery remain open.

## Implementation eligibility — owner revision 2026-10-01

[README §4.1](00-README.md#41-implementation-eligibility-and-quality-gates--owner-decision-2026-10-01)
supersedes blanket phase-entry gating. P2-01, P3-01 and P6-01 now list their actual
contracts; P4-07a may also start from P0-11 and the existing guarded memory seam.
Task states follow the current ledger: P3-01/P6-01 are done and P2-01/P4-07a have
implementation evidence below. This amendment is not a current todo list. The fixed 9/10 quick bar and
all full/owner/latency/safety/product exit requirements remain unchanged and open.
P2 measurements, production-route tests and typed restart fixtures can proceed
without claiming that the Agent is ready. Downstream migration and ownership
switches still require their declared task prerequisites and proof.

## Computer and browser action validity — planned 2026-09-30

[`09-CELL-USE-COMPUTER-BROWSER.md`](09-CELL-USE-COMPUTER-BROWSER.md) is the
implementation brief. These CU tasks borrow cell-use's observation/action
validity rules within the existing Agent tools. They do not change any P task's
state or the Phase 1 exit gate. Source inspection and the upstream root test run
are evidence for the plan only, not a green app result.

| ID | Task | Depends on | State | Evidence needed |
|---|---|---|---|---|
| CU-01 | Reproduce stale/repeated action cases and measure the current path | none | in progress | Partial actual CDP original/fixed baseline and latency recorded; native AX/coordinate baseline and environment-qualified full exit remain open |
| CU-02 | Stop automatic click replay on uncertain outcomes | CU-01 | in progress | Committed8888474 one-action VerifyRetry/CDP repair; baseline10 failures, first fixed1 yield failure retained; later installed CDP_OK plus11 assertions. Full live AX/uncertain-delivery/consent regressions remain open |
| CU-03 | Check the same DOM control at action time | CU-02 | in progress | Committed8888474 observed backendNodeID, atomic validation/action and consumed snapshot. Later installed CDP evidence exists; full current reorder/tab/stable/approval acceptance remains open |
| CU-04 | Bind screenshot coordinates to captured target and geometry | CU-01 | todo | Focus/window/tab/resize/age cases refuse; unchanged target succeeds; consent unchanged |
| CU-05 | Verify live behavior, tool-loop safety and latency | CU-02…CU-04 | todo | Named self-test markers, unlocked live checks, before/after p50/p95 and report path |

## Product promise exits — added 2026-09-30

`08-PRODUCT-PROMISE-GAPS.md` maps the current website to end-to-end evidence. These
X tasks are additive cross-phase acceptance work, not a declaration that Phase 1,
proactivity or durable jobs are complete. Recheck active iMessage work before X08.

| ID | Exit | Depends on | State | Evidence required |
|---|---|---|---|---|
| X01 | One identity across home, office, meeting and voice surfaces | P4-03, P3-09 for final ownership | todo | Same name/avatar/session identity in a cross-context fixture and visual sheet |
| X02 | Visible, correctable history | P1-18/26/30, P4-07/11, P6-02/08 | todo | >40 messages and linked work survive relaunch; no scroll jump; later answer reflects correction |
| X03 | Real progress, approval and honest outcomes | P1-19–23, P3-03/08/11, P6-04/06/08 | todo | Approved/declined/cancelled/unknown and restart cases show true state and result |
| X04 | Home, dictation and Mac-app jobs complete end to end | Phase 1 gate, P3-11, P6-06; dictation leg early | todo | Two consecutive journey runs with verified or honestly stopped outcomes |
| X05 | Meeting promise becomes resolved follow-through | P4-04–06/10/13, P6-06/08, X02–X03 | todo | Source-grounded owed item, one review, confirmed outcome, no stale nudge |
| X06 | Useful proactive prompts, quiet when irrelevant | Phase 4, X05 | todo | Seven-day fixture schedule with no duplicate/stale/quiet-hours prompt; attended trial |
| X07 | Perceived speed and full duplex | Phases 2–3, X03 | todo | Phase latency gates and journey first-feedback/interrupt evidence |
| X08 | Reach beyond an open Mac | iMessage/call work, X01–X03 | todo | Paired-device message authority and offline truth; calls only after live placed/declined/missed suite |
| X09 | First useful moment without setup homework | P1-16, P4-13, onboarding/guided paths, X03 | todo | Fresh-profile granted/denied/offline paths end with a useful action or one clear next click |
| X10 | Source, consent and safety proof | P1-19/21/30, P4-07/10/13, P6-06, SHARED-BRAIN | todo | Negative journey cases, source/outgoing content visible, no private content in logs |
| X11 | Website claims and real-user proof | X01–X10 | todo | Dated claim ledger, no false completion claim, three outside users finish guided jobs |

**Current evidence:** Phase 1's recorded two-run gate remains 17/30 versus 25/30;
the full product-promise exit is **NOT MET**. The Mac dictation/meeting foothold is
real, but the site animations alone are not X04/X05 evidence. Update this table as
each X task lands, using the same final-marker and measured-evidence discipline as
the P ledger below.

States:

| State | Meaning |
|---|---|
| `todo` | Not started. |
| `in progress` | Started or partially verified; the task's full exit remains open. Prepared work has no native verdict. |
| `red` | The self-test is written and confirmed failing on the old code. |
| `green` | The gate passed and the regressions are unchanged. |
| `done` | Committed. |
| `blocked` | See the notes below the table. |

Dates are `YYYY-MM-DD`. Evidence is the final marker line plus any measured numbers with
units. The commit is a short hash.

## Baseline

Captured per `00-README.md` §7. Report: `Tests/Reports/AGENT-OVERHAUL-BASELINE-____-__-__.md`.

| Item | Value |
|---|---|
| Commit (`git rev-parse --short HEAD`) | `5b16b2c` (tree dirty: 74 modified files) |
| Date | 2026-09-23 |
| Free disk (`df -h /`) | 3.3 Gi avail (80% used) |
| `modelRoles.agent` / `modelRoles.meetingNotes` | `installed:unsloth/Qwen3-4B-Instruct-2507-GGUF/Qwen3-4B-Instruct-2507-Q4_K_M.gguf` / `builtin` |
| `modelLibrary.activeAgentModelID` / `postDownloadPolicy` | `unsloth/…/Qwen3-4B-Instruct-2507-Q4_K_M.gguf` / `switchDeleteOld` |
| Models folder contents | embeddinggemma-300M, needle3*, potion-retrieval-32M*, s1-mini, unsloth--Qwen3-4B (2.50 GB); no k2-horizon |
| `make test` | 30 tests in 2 suites passed (0.397 s) |
| `make acceptance TIER=core` summary | `CORE 12/14 PASS` — FAIL: `--selftest-wake-live` (known red), `--selftest-computer` (known red, locked screen) |
| `--selftest-model-roles` | `MODEL_ROLES_OK: fallback, routing, call paths, discovery and tool-call bridging verified` |
| `--selftest-model-fit` | `MODEL_FIT_OK` |
| `--selftest-llm-metal` | `LLM_METAL_OK: metal on, GPU runtime and CPU runtime both ran in one process, peak RSS 896 MB` (false green — ran on S1-mini, agent-role leg is P0-02) |
| `--selftest-hf-search` | `HF_SEARCH_OK` |
| `--selftest-toolloop` | `TOOLLOOP_OK` |
| `--selftest-toolloop-production` | `TOOLLOOP_PRODUCTION_FAILED` (the live bug; prompt 3924 chars, planner 1521 tok / 12 tools) |
| `--selftest-voice-scheduling` | `VOICE_SCHEDULING_OK` |
| `--selftest-concurrent-voice` | `CONCURRENT_VOICE_OK` |
| `--selftest-acp-confirm` | `ACP_CONFIRM_OK` |
| `--selftest-voice-delivery` | `VOICE_DELIVERY_OK` |
| `--selftest-voice-turn-routing` | `VOICE_TURN_ROUTING_OK` |
| `--selftest-voice-conversation` | `VOICE_CONVERSATION_OK` |
| `--selftest-persona` | `PERSONA_OK` |
| `--selftest-ui-strings` | `UI_STRINGS_OK` |
| `--selftest-tasks` | `TASKS_OK: submit, run and cancel hold` |
| `--selftest-scheduler` | `SCHEDULER_OK` |
| `--selftest-residency` | `RESIDENCY_OK` |
| `--selftest-memory` | `MEMORY_OK` |
| `--selftest-openrouter-contract` (P0-17's baseline) | `OPENROUTER_CONTRACT_OK` |
| `--selftest-metrics` (P0-20's baseline) | `METRICS_OK` |
| `--selftest-voice-pipeline` (haiku WAV): final line, `VOICE_MODEL_EOU_TO_ENDPOINT`, `VOICE_PIPELINE_ENDPOINT_TO_FIRST_AUDIO` | `VOICE_PIPELINE_FAILED`; 0.0644 s; 2.164 s |

Report: `Tests/Reports/AGENT-OVERHAUL-BASELINE-2026-09-23.md` (commit `c3df82a`).
Raw outputs: `~/Library/Caches/NextNotesBuild/agent-overhaul/baseline/`.

## Ledger

| ID | Title | Phase | Depends on | State | Date | Evidence | Commit |
|---|---|---|---|---|---|---|---|
| P0-01 | User actions: put the Agent on a model that answers, install one this llama.cpp can open, run the smoke check | 0 | none | done | 2026-09-23 | Agent role on `unsloth/Qwen3-4B-Instruct-2507-Q4_K_M.gguf` (2.50 GB), meetingNotes `apple`, computerUse `apple`, policy `downloadOnly`, K2 deleted. Report committed. `LLM_METAL_AGENT_ROLE` pending P0-02; `--selftest-agent-answers` pending P0-14b | `16fd462` |
| P0-02 | Download verification decodes one token before `switchDeleteOld` deletes anything, and never races the switch | 0 | P0-13 | done | 2026-09-24 | `MODEL_UNOPENABLE_OK: unsupported files refused before any weight load`; `LLM_METAL_AGENT_ROLE: Qwen3-4B-Instruct-2507 generated 1 token(s) in 1.50s`; `LLM_METAL_OK`. `trial(_:)` decodes ≥1 token in the background lane, records `lastTrial`, refuses a switch that did not answer; `recommendsDeletingOld` knows the other-answering-models rule. Regressions green | `894f9c1` |
| P0-03 | Roles resolve only answerable models; launch-time role repair with one notice; the pane names the answering model | 0 | P0-13, P0-14 | done | 2026-09-24 | `MODEL_ROLES_OK`; `repairUnanswerableRoles()` refreshes verdicts and repairs with one persisted notice per (role, file), `isAnswerable` backs `provider(for:)`, the Settings mirror is skipped when the store is not on the owner's defaults; the pane shows "Answered by <name>" | `8080a8f` |
| P0-04 | Per-family chat templates; special and control tokens preserved in planner output (includes the MiniCPM5 case, G N3) | 0 | P0-13, P0-02 | done | 2026-09-24 | `CHAT_TEMPLATE_OK: 6 families detected and rendered; control tokens survive planner decode`; seven families detected/rendered with per-family stops, `renderSpecial` threaded through the typed planner's `stream` route (this fixed P0-14b's lost `<tool_call>`). MiniCPM5 live half `MINICPM5_ABSENT` (file removed from this Mac); pure cases pass | `b56a37d` |
| P0-05 | Lift the typed first pass's 112-token cap to the persona budget | 0 | none | done | 2026-09-24 | Cases a–d green (500 / 128 / room-clamped / table 500·1024·768·64); `grep "maxTokens: 112"` → no match; the flag's marker stays `TOOLLOOP_PRODUCTION_FAILED` for the two baseline reds (conversation roster 3924 chars, planner 1521 tok/12 tools) that P1-03/P1-06 own | `6ad6ade` |
| P0-06 | Worker warmup off the voice lane; cancellable `ComputeScheduler.acquire`; a drain timeout detaches | 0 | none | done | 2026-09-24 | `VOICE_SCHEDULING_OK`, `CONCURRENT_VOICE_OK`; prewarm lane `.background`, `acquireCancellable` removes queued/parked waiters, drain timeout detaches. Cross-task hook for P0-13 at `NotesModelRuntime.swift:218` | `fe3747a` |
| P0-07 | A frontend failure resolves its own epoch; write-time effect gate `mayCommitEffect` | 0 | none | done | 2026-09-24 | `CONCURRENT_VOICE_OK`, `VOICE_CAPABILITY_OK`; `finishFailure` resolves its epoch and sets `effectHoldEpoch`; the hold clears on a later classified turn, `discardInput()` or `closeSession()`; `isStillValid` gates `risk > .read` through `mayCommitEffect`. Two contract assertions in `VoiceCapabilityConversationSelfTest` updated (old contract asserted the bug) | `cb1ed83` |
| P0-08 | "Run locally once" never submits a task without a tool | 0 | none | done | 2026-09-24 | `ACP_CONFIRM_OK`; `localOnceRoute` is pure, the tool-less `AgentTaskManager.submit(backend: .local)` path is deleted, `.submitWithoutTool` is never produced and the exhaustive switch answers on-device if it ever were | `b817f49` |
| P0-09 | The 280-character speech cap applies per clause | 0 | none | done | 2026-09-24 | `VOICE_DELIVERY_OK`, `TTS_OK`; per-clause cap, id-shaped silencers, a playing clause is never stopped on length | `05401af` |
| P0-10 | `tick` runs immediately from `noteModelEOU` | 0 | none | blocked | 2026-09-24 | Implementation in place: `VOICE_ENDPOINT_TRIGGER=eou` and `VOICE_MODEL_EOU_TO_ENDPOINT` 3.9–4.0 ms when the EOU reaches the app. 2 of 3 runs met the trigger criterion; run 3's EOU arrived 4.3 s after voice end, after the 2.5 s VAD fallback had already committed (`.vad`, no trigger). See BLOCKED note  Reconciled2026-10-03: immediate tick logic implemented; native endpoint/fallback/late-EOU acceptance remains open. | `d4f89a7` |
| P0-11 | Self-tests never write the user's real stores: seams, an isolation self-test, and a one-off cleanup script | 0 | none | done | 2026-09-24 | `STORE_ISOLATION_OK: 13 files and 23 defaults unchanged`; harness `.shared` stores use a per-process `UserDefaults(suiteName:)`, the owner's selection is copied read-only for the two allow flags and the domain is removed at exit; cleanup script defaults to dry run (9 tasks / 17 audit rows / 0 memory rows) | `2e48160` |
| P0-12 | Correct the stale facts in AGENTS.md and add the new traps | 0 | P0-13, P0-14, P0-17, P0-18, P0-19, P0-20 (do last in Phase 0) | done | 2026-09-24 | Four stale facts corrected (the realtime tool-loop alias order; the claim that every notes and agent run went through Apple's model; the Workspace-write entry — gws is signed in with 21 scopes, only writes unproven; the warmup-priority sentence now names `prewarmWorkClass(voice:)`) and eight traps added (valid-but-unopenable GGUF, read-only provider resolution, the `--selftest-llm-metal` lie, trial-before-switch, reasoning models spending the allowance, prefix reuse and `kvTokens`, `PrivateURLSession`, MiniCPM5 control tokens). Every claim re-checked in the tree | `c0c5c41` |
| P0-13 | Architecture support guard (before download, on install, before a role is assigned) | 0 | none | done | 2026-09-24 | `MODEL_UNOPENABLE_OK: unsupported files refused before any weight load`; `Scripts/gen-llama-architectures.sh --check` reports no drift (146 names, b10621) | `546eb99` |
| P0-14 | One provider per turn, no stale fallback, failed loads remembered | 0 | P0-13 | done | 2026-09-24 | `MODEL_UNOPENABLE_OK` (case H: `.modelUnopenable` thrown, notes runtime not wedged, 0 selection writes, failed file never re-selected, fallback answers without "tool planner failed", notice truthful); `LLM_METAL_OK` peak RSS 3647 MB. Provider resolved once per turn into `runPlannedToolLoop`; `ModelOpenFailureStore` remembers failed opens; `select(_:)` awaited. Registry edits landed in the parallel workstream's `2edc55f` |  |
| P0-14b | ↳ `--selftest-agent-answers` (Phase 0 exit harness, P0-14 step 8) | 0 | P0-14, P0-11; green only after P0-01; **also needs P0-04** (found in execution) | done | 2026-09-24 | `AGENT_ANSWERS_OK: 3/3 answered by Qwen3-4B-Instruct-2507` (output `P0-14b-attempt3.txt`). Two causes fixed on the way: P0-04's `renderSpecial` (the opening `<tool_call>` was dropped) and P0-18's prefix reuse (the 18 s warm budget on a three-round tool turn). Turns print `AGENT_ANSWER n: appLLM · Qwen3-4B-Instruct-2507 · model-answer/model-tools · …`; turn 3 returns the real calendar | `1c609ca` (harness itself in `f262162`) |
| P0-15 | The input placeholder uses the Agent's name | 0 | none | done | 2026-09-24 | `UI_STRINGS_OK`; composer placeholder interpolates `identity.name`; no `Ask Next…` literal remains under `UI/` | `dc2cc08` |
| P0-16 | (Decide by evidence) Support `k2-horizon` — default decision: won't do unless upstream adds it | 0 | P0-13 | done (won't do) | 2026-09-24 | Upstream `src/llama-arch.cpp` (master) still has no `horizon` entry; ggml-org/llama.cpp issue #28361 ("Eval bug: K2-Horizon models fail to load") is open. `--selftest-model-unopenable` case F pins that `k2-horizon` is not supported by b10621; update, do not delete, that assertion if the dependency is ever bumped | n/a (decision) |
| P0-17 | OpenRouter: cap reasoning, read `finish_reason`, and never end a cut-off reply as "incomplete response" (G N1) | 0 | none (land in the same session as P0-05) | done | 2026-09-24 | `OPENROUTER_CONTRACT_OK`; live run `OPENROUTER_OK: inclusionai/ling-3.0-flash-sante:free · catalog, key, completion and stream verified`. `.capped(1_024)`, `reasoning {effort low, exclude true}`, `finish_reason` read, one retry, `cutOff(visibleText:)`; `--selftest-toolloop-production` back to its 2 known baseline lines | `2b28c5a` |
| P0-18 | llama prefix reuse: keep the KV cache across calls and decode only the tokens that changed (G N2) | 0 | P0-04, P0-14, P0-06 | done | 2026-09-24 | `LLM_PREFIX_CACHE_OK: reused 646/666 tokens, prefill 2.10s → 0.33s`; partial removal falls back to a full clear, every error/cancel/rebuild/swap/shutdown resets the ledger. Equality probe adapted per REVIEW-LOG §4.4 item 4 (measured 3 of 4 pieces, identical in both) | `1c609ca` |
| P0-19 | Keep model replies and account data out of the on-disk URL cache, and purge what is there (G N4) | 0 | none | done | 2026-09-24 | `PRIVATE_NETWORK_OK`; ephemeral `PrivateURLSession` (urlCache nil, reloadIgnoringLocalCacheData), 11 private call sites swapped, one-time purge recorded. First run `PRIVATE_NETWORK_FAILED: 1 problem(s)` was the purge fixture (zero-capacity URLCache); fixed in the fixture, not weakened | `038c975` |
| P0-20 | One provenance record per model pass: provider, model, path, pass, tokens and timing in `metrics.jsonl` | 0 | none (soft: P0-14) | done | 2026-09-24 | Widened in place to `usage.jsonl` (P0-20a–e, all landed). One persistent sink: 8 MB rotation to `usage.1.jsonl`, 90-day compaction, `UsageLog.sanitise`, harness temp isolation; Agent, Meetings, Dictation and the report/Settings view all read it; `metrics.jsonl` stays the short stage ring | `78cebc9` |
| P0-20a | ↳ Usage log core, and the Agent, memory-review and Knowledge Ask passes (H-audit 2026-09-24: P0-20 widened to a unified `usage.jsonl`) | 0 | none (soft: P0-14) | done | 2026-09-24 | `USAGE_LOG_OK: 7 cases`; `usage.jsonl` with 8 MB rotation, 90-day compaction, load/clear/sanitise and harness temp isolation; `ModelPassRecorder` wraps every pass the task lists, plus ACP/Codex `agent.handoff` rows; write-path `ms` is post-approval only (`ToolExecutionTimer` inside the `fire` closure). Regressions green | `20c0145` |
| P0-20b | ↳ Usage rows for Meetings: transcription, speaker separation, notes, proposals, live proposals, Needle | 0 | P0-20a | done | 2026-09-24 | `USAGE_LOG_OK: 12 cases` (M1–M5 from this task); tally actor per (meeting, source) with transcribed-only audio/compute/laneWait, `meeting.diarize` on every exit, notes single/map/reduce recorders, proposals rounds with toolsProposed/reserved/budget, `contextTooSmall`, reconciledOut, one `meeting.needle` row per propose | `22a6a5a` |
| P0-20c | ↳ Usage rows for Dictation: the speech engine, the cleanup pass, and the tail split, joined to `runs.jsonl` | 0 | P0-20a | done | 2026-09-24 | `USAGE_LOG_OK: 23 cases` (D2 red first: "expected exactly 1 dictation.asr row, wrote 0"); `runID` minted before the drain and passed into `recordRun`, one `dictation.asr` and one `dictation.cleanup` row carrying `dictationRunID`, injectable `usage:` seam beside `record:`. Deviations: D2 rides `--selftest-usage-log`; a test-only `requestMicrophone` seam; Command Mode writes no rows; builder warm/loadMs and a compare-mode pass stay unplumbed. Regressions: `DICTATION_OK` (via-open), `CLEANUP_ROUTER_OK`, `make test` 30 tests | `effd5c4` |

- 2026-09-26 DICTATION-MEETINGS-RATES-AND-GATES F-01 (commit `99d4a46`) added a defaulted `laneWait` parameter to `UsageRecord.dictationRows` and wrote `stages["laneWait"]` on the `dictation.asr` row, so D-14's second gate condition is readable from a real hold. **P0-20c's own call sites were not changed** — the default is 0 — and the field is additive. It also added `TranscriptionEngine.startLaneWait` (default 0) and the measurement in `ParakeetEngine.start()`. No hold or release point moved: that is F-03, and it is evidence-gated. Nothing in P0-20c's scope was rewritten; if P0-20c later needs a different name or shape here, it wins and F-03 follows.
| P0-20d | ↳ `--usage-report` and a Usage section in Settings ▸ Models | 0 | P0-20a (P0-20b, P0-20c for completeness) | done | 2026-09-24 | `USAGE_LOG_OK: 12 cases` (R1–R3); `--usage-report` printed `USAGE_REPORT_EMPTY` (honest empty state on this Mac); the Settings section groups Agent/Meetings/Dictation/Other over 7 days with a confirmation-gated clear | `8eacdbd` |
| P0-20e | ↳ `--selftest-usage-log` exit cases: end to end, privacy, isolation, registration | 0 | P0-20a–d | done | 2026-09-24 | `USAGE_LOG_OK: 20 cases` (E1/D1/E3/E4 red first); `SelfTestStoreGuard.fileNames` watches `usage.jsonl` so `STORE_ISOLATION_OK: 14 files and 23 defaults unchanged`; `make acceptance TIER=core` 14/15 with only the known-red wake-live | `78cebc9` |
| P0-21 | One default for the knowledge index, and the Agent's knowledge tools on by default (H1 #11–12, H3 #1–2) | 0 | none | done | 2026-09-24 | `INDEX_OK`; both `defaultEnabled` constants true and the two `Settings.initialKnowledge…Enabled` bodies read them, stored keys still win; dictation/routines/graph/embedder untouched | `d237cc7` |
| P0-22 | Multi-step notices name the model that actually answers and promise no durations (H1 #13) | 0 | none (soft: P0-14) | done | 2026-09-24 | `MODEL_ROLES_OK`; the notice is computed after the provider is resolved, names the answerer's display name, promises no duration, once per session; voice and single-step local stay silent | `b5912ef` |
| P0-23 | "That wasn't for you" ends the session and drops its turn (H2 V2) | 0 | none | done | 2026-09-24 | `VOICE_TURNS_OK`; `disown()` exact-signature, once per utterance, ends via `endSession(source: .disowned)` which discards the in-flight turn and says "Okay, I'll ignore that."; island button wired through `IslandState.disownAgentListen()` | `ea2ce7c` |
| P1-01 | Live real-model eval `--selftest-toolloop-live` (~30 canonical requests) | 1 | none to write; baseline after P0-01, P0-03, P0-04, P0-05, P0-11 (Phase 0 gate) | done `de07497` | | |  |
| P1-02 | Remove the typed tool-less first pass; typed pending action ("yes" carries the action) | 1 | P1-01, P0-05 | done `7bc440a` — first pass removed, typed pending action; eval 5/30 -> 10/30, quick 1/10 -> 2/10 | | |  |
| P1-03 | `AgentCapabilityManifest`: one per-turn source of truth; namespace selection; MCP/Composio by risk class | 1 | P1-01 | done `0a7281a` — one source of truth; CAPABILITY_MANIFEST_OK; quick 2/10 -> 5/10, leaks 3 -> 1 | | |  |
| P1-04 | Tolerant parser, error split, repair loop | 1 | P1-01, P0-04 (soft: P1-03) | done `bb3a326` — tolerant parser with two recovery ceilings; leaks 1 -> 0; production reds 3 -> 1 | | |  |
| P1-04 addendum | **A reply may not claim a write it did not perform** (`43df281`) | — | — | done | 2026-09-28 | The live eval caught the app saying two things that never happened on Qwen3-4B: "Sending… ✅ Done: Email sent to Marcus" after a `filesystem.search`, and "I’ve set a nightly reminder… It’s now active" after a `schedule.list`. `ToolClaimGuard`’s phrase list was **entirely read verbs**, and the rule under it — a claim naming no tool is backed by *any* completed call — was built for them, so a file search backed a send. Added `writeClaimPhrases`, `writeClaimShapes` for the status lines a model writes instead of a sentence, and one rule: a claim that something **changed** is backed only by a call that changed something, via a new `AgentRisk.changesSomething` kept deliberately apart from `mayAutoRun`. Narrower than the rejected P1-14 leg — one question, on the existing re-plan. **Fixing the grammar then exposed a bug in it**: every *contracted* claim had been invisible since P1-11, because the lists are written with `'` and dictation returns `’`. `TOOLLOOP_OK`, `TOOL_REVIEW_OK`, `TOOLLOOP_PRODUCTION_OK`, `CAPABILITY_MANIFEST_OK`, `NATIVE_TOOLS_OK` | `43df281` |
| P1-04 addendum notes | (a) Measured on the local Agent model, `--quick`, same 10 cases: **6/10 → 7/10** (M03 UNGROUNDED → PASS), and both fabrications are gone from the replies — the remaining R02/F03 verdicts are honest shortfalls rather than fabrications. (b) **The subset scored 6, 7, 6 on three consecutive runs**, so one quick run carries at least ±1 case of noise and is not a gate signal by itself. (c) The claim a person acts on is the worst class of failure this app has, which is why this was done before the score work: a wrong answer costs a retry, "Email sent" costs a false belief. (d) `--selftest-toolloop-production`’s first-pass budget case was failing on the same apostrophe | | | | | |
| P1-05 | Native / constrained tool calling: Apple FM `Tool`, GBNF over the manifest for llama, OpenAI `tools` for cloud | 1 | P1-03, P1-04, P1-06, P0-04, P0-07 | done `58d0b8c` — GBNF/Apple-Tool/OpenAI-tools backends; Apple FM 2/10 -> 6/10; default stays off pending 3 full evals | | |  |
| P1-04 addendum 2 | **Two sources for one fact — the prompt answered before the tool could** (`1427a7f`) | — | — | done, measured | 2026-09-28 | The full 30-case eval on Qwen3-4B is **15/30** and the dominant failure is not a missing or wrong tool: **8 of the 12 MISSED_TOOL cases ran no tool at all** (`tools=-`). Two prompt contradictions explain most of it. (a) The `.screen` rule says the frontmost app "come[s] from computer.active_app" and that without a call "you do not know" — and the "Right now" block was handing over `- Front app:` from a cache as old as the prompt, so A04 answered from it in one round. `frontApp` is now in **no shape a person talks to**; it stays in the facts and the cache. (b) **`.browser` was the one selected class with no rule line at all**, so a two-part browser request got tools and no guidance; A01/A02 navigated, stopped and were UNGROUNDED. The new line names the second call and the honest last sentence. **A02 now passes** (`navigate` → `fill(search, "Cortech latest")` → `click`) | `1427a7f` |
| P1-04 addendum 2 notes | (a) Measured full-30 before and after: **15/30 both times**, `missed_tool` 10 → 12, `ungrounded` 4 → 5, owner 8/10 → 7/10. **Flat, and said plainly rather than dressed up.** What changed is behaviour the aggregate cannot see: a stale confident answer became an honest one, a fabricated "Email sent" is gone, one browser case now completes. What did not change is the 8 cases where a 4B model answers a question about calendar, files, tasks or memory with no tool call at all. (b) **The Phase 1 exit bar is a model question, not a prompt question.** The built-in Gemma the Agent role is meant to use is not on this Mac, and its ~9 GB download does not fit in the 7.3 GB free after the rebuild. (c) The eval runs in ~5 minutes on Qwen3-4B, not the 3.5 h the brief assumed, so the gate is cheap to re-measure once a better model exists. (d) `--selftest-usage-log` E1 remains red at HEAD, unrelated to these | | | | | | |
| P1-06 | Per-round budget with a ceiling | 1 | P1-01, P1-02 | done `4047bd9` — per-round budget + always-affordable final round; TIMEOUT 3 -> 0; agent-answers 3/3 x3 | | |  |
| P0-16 addendum | **The built-in model is on this Mac, and the two seams it exposed are fixed** (`79d748d`) | — | P0-16 | done | 2026-09-28 | New `--download-notes-model` **modifier** (the `--fake-calendar` shape — it changes the machine, it does not answer a question about it), because the only other path is the Models tab and driving that needs the Accessibility grant an agent here is refused. It goes through the app's own `ModelDownloader`, so resume, size check and digest are that code's; the disk guard is `LocalModelStore`'s arithmetic copied, and it **refused correctly first time** (`NO_ROOM: 7.9 GB free, 9.27 GB needed`). **Gemma 4 E4B 4.64 GB landed**, and `expectedSHA256` is pinned to the digest the downloader computed — AGENTS.md's "next agent to get it pins it", so a truncated or substituted file now fails at the door. Two seams broke the moment it existed, both in gates that had been unrunnable: (a) `ModelRoleStore.builtInProvider` asked `LLMProviders.resolve`, which reads the **real disk**, so a store seeded `availability: .nothingInstalled` was contradicted by the machine — case H went red and now consults its own `builtInModelReady`; (b) **my own `.browser` rule** from `1427a7f` pushed the whole-class planner prompt to 2,046 tokens against a 2,000 ceiling, and two gates went red on it — trimmed to half the words rather than moving the ceiling | `79d748d` |
| P0-16 addendum notes | (a) **`--selftest-tool-awareness` is `TOOL_AWARENESS_OK` for the first time in this roadmap's life** — it was red from the first run because the model was absent. `MODEL_UNOPENABLE_OK`, `MODEL_ROLES_OK` also restored. (b) `--selftest-voice-grounding` prints `GROUNDING_OK` and still fails one case: asked who it is, the model **invents a persona header** — "Agent Name: Friend" — and answers "I am your friend on this Mac", ignoring the name it was grounded with. `agent-identity.json` holds only `displayName: "Will"`, so the header is the model's own. Recorded, not fixed: the name **is** in the prompt and a small model is choosing to ignore it, which is the same wall as the 15/30 score. (c) Disk after all of it: **2.6 GiB free** with the model on disk. Build scratch is reaped after each install; a tight disk is the `MPSGraphTensorData` SIGABRT. (d) The Phase 1 gate must now be re-measured **with the built-in model as the Agent role**, which is the measurement this whole session was for | | | | | | |
| P1-07 | Voice rebuttal, first-denial escalation, question-form gates, pending action from a worker question | 1 | P1-02, P1-03, P0-07 | done `de3763c` — question routes, denial escalation, one pending slot; VOICE_TURN_ROUTING_OK | | |  |
| P1-08 | Whole-sentence shortcuts; no "agent/app" answer-only prefixes | 1 | P1-01; P1-03 for the read-only path | done `1d1cb99` (ledger row was stale until 2026-09-27; the commit landed 09-26 16:24 and no file in this roadmap mentioned it) — a shortcut claims only a whole sentence, leftover nouns go to the planner; the on-device route is `maxRisk: .read` with `allowFallback: false`; production `_WRONG` 5 → 1, `--quick` ungrounded 4 → 3 | | |  |
| P1-09 | Gmail defaults, metadata batch, `read_email`, sender header fix | 1 | P1-01, P1-04 | done `cf99705` — recoverable bad Gmail query, read_email, sender bug fixed at its source; GWS_FIXTURES_OK | | |  |
| P1-10 | Capped tool results; one renderer; no internal ids to users | 1 | see subtasks | done `3aac1a4` — reader-scaled result cap + one renderer per outcome; production reds 63 -> 1 | | |  |
| P1-10a | ↳ Result cap and context budget | 1 | P1-01 | done `de07497` — grader green; baseline 5/30 (agent role) and 6/30 (Apple) | | **P1-10a step 0 landed in M-12**, commit `4fc61c3`, 2026-09-25: `FoundationModelLLMProvider.contextTokens` reads `SystemLanguageModel.default.contextSize` at runtime (8,192 measured here, floored to 4,096 when it reports ≤ 0), the type's doc comment fixed, and `--selftest-toolloop-production` gained the case printing `APPLE_FM_CONTEXT=8192` (`contextTokens == contextSize`, Apple FM only). M-12 also owns `countTokens` (exact on macOS 26.4+ via `tokenCount(for:)`, chars/3 estimate below). Steps 1–3 still todo and skip step 0. |  |
| P1-10a-1 | ↳ Retain admitted tool bodies before ordinary planner context measurement | 1 | Existing P1-10a fitter/guard branches; independent §4.1 proof | done (bounded) | 2026-10-02 | Corrected original105 RED4/84/all80controls → identical fixed106 PASS84. Exact1producer-body delta in1048manifest; explicit pressure8192→2000 preserves existing folding.14/15focused flags pass incl worker1352/isolation; unchanged direct voice identity model flag FAILED/open. Quick4/10 (C04/A02 PASS,84.7s), CORE21/22 wake17/24hits3/32false. Initial104 supporting/nonpaired/private grounding retained. Final-answer/defaultscheduled folding, historical103 native causality/prefill/parent gates open. [Proof](../../../Tests/Reports/agent-overhaul-closure/c04-result-context-review/native-verification/verification.md). | ec44025 |
| P1-10a-2 | ↳ Shared measured admission for the account-read final-answer caller | 1 | P1-10a-1; actual guard/final provider proof; §4.1 | done (bounded) | 2026-10-02 | Original109 RED7/122/all115controls -> identical fixed110 PASS122/prior84/all30focused flags incl worker1487/reader40/isolation21files32defaults. Exact2 producer/doc delta/full1050compilerSources; actual CRLF history/over-room refusal and real stream cancel. Quick4/10 (79.8s), CORE21/22 wake17/24hits3/32false; no model/latency promotion. Scheduled folding, final-await authority, owner-read isolation/directvoice/full/live/parent gates OPEN. [Proof](../../../Tests/Reports/agent-overhaul-closure/c04-final-result-context-review/native-verification/verification.md). | a3d4524 |
| P1-10b | ↳ One renderer; no ids, step counts or raw errors in replies | 1 | P1-04, P1-02 | done | 2026-09-27 | The renderer, the 10-case `AgentTurnOutcome` and the `voiceSafeReply` rewrite had already landed; **two live bugs did not**. (1) `markupRegex` was written with Swift's `\u{200B}` in an ICU pattern, so it never compiled — `try?` made it `nil` and the first step of the scrub had never run on any reply, which is J L9's raw `<tool_call>` Portrait draft. Now ICU's `\u200B`, closing form restored, `markupPatternCompiled` asserted; re-breaking it fails the run. (2) `finishedByLimit` was discarded: the final-answer round took `.text` off the completion. Now `.cutShort(partial)` ("…ask me to go on") via `render`. Five raw-error/two registry-id sites (routine read, draft, `draft.result`, island approval, Portrait pane) now go through the renderer. `TOOLLOOP_PRODUCTION_OK` (+5 markup forms, 3 cut-short sentences, 2 wiring scans), `SCHEDULE_OK`, `PORTRAIT_OK`, `MEMORY_OK`, `VOICE_CONVERSATION_OK`, `ASK_OK`, `INDEX_OK`, `ISLAND_OK`, `VOICE_TURNS_OK`, `SETTINGS_OK`, `make test` 30/30. Task's own greps clean | `0dc8ef2` |
| P1-10b gap | **`finishedByLimit` is unreachable on the planner's own rounds** and is left that way deliberately: those rounds *stream*, a stream yields `String`, and `LLMCompletion` is not in it. `LlamaGrammarPlanner` infers a cut-off from the grammar refusing to match; `PromptConventionPlanner` and `OpenAIToolsPlanner` cannot see it at all. The flag is honoured on the final-answer round, which asks through `complete`. Closing the streamed half means carrying the flag out of a stream — a change to every provider's signature, so it is a later task, not this one | | | | | |
| P1-11 | A reply may not claim a tool ran when none did; the history given to the planner carries no stale tool claims (G N5) | 1 | P1-01, P1-04 (soft: P1-10b) | done `fd8ebc3` — claim guard; Apple FM fabricated 2 -> 0, pass 1 -> 2 | | |  |
| P1-12 | "Controlling your Mac": remember when Codex is out of quota, fall back to the Agent's model, and say so in plain words (G N6) | 1 | P0-14 (soft: P1-10b) | done `078c51c` — one provider per turn now true; Codex quota remembered as a Date; MODEL_ROLES_OK | | |  |
| P1-13 | Direct intent: match two-word sites before one-word sites, and send leftover nouns to the planner (G N7) | 1 | P1-08 | done `44c176d` — two-word site phrases consumed by index; leftover nouns to the planner | | |  |
| P1-14 | The echo filter keeps short answers and restatements (H2 V1) | 1 | none (must be done before P1-07) | done `bf8fe44` — 1.5 s echo tail; DUPLEX_OK; unblocks P1-07 | | |  |
| P1-15 | Goodbye is recognised by exact signature, not by substring (H2 V16) | 1 | none | done | 2026-09-27 | `VOICE_TURNS_OK` with 10 closing and 8 non-closing fixtures (the non-closing rows red first); the list grades itself. `DUPLEX_OK`, `VOICE_CONVERSATION_OK`, `REALTIME_OK`, `CONCURRENT_VOICE_OK`, `make test` 30/30 | `791f28e` |
| P1-16 | Pending approvals stay visible until answered (H3 #5–6) | 1 | none (land beside P1-07) | done | 2026-09-27 | `ISLAND_OK`, including a case against the **real** gate: a real `ask()`, the badge appearing, and the asker cancelled (the watcher's 180 s expiry) proving the badge clears. Priority is a pure `liveWinner`; the notice and the live kind share `islandProposal`/`proposalBody`/`proposalActions`. `UI_STRINGS_OK`, `ACP_CONFIRM_OK`, `TASKS_OK`, `ACTIVITY_OK`, `make test` 30/30 | `df2e67b` |
| P1-17 | "Look things up without asking" is honoured by the realtime planner; knowledge visibility no longer depends on it (H1 #22) | 1 | P1-01 (soft: P0-21) | done | 2026-09-27 | `TOOLLOOP_PRODUCTION_OK` (3 recorded decisions, 1 setting check, 2 call sites scanned, 2-switch knowledge gate), `ASK_OK`, `INDEX_OK`, `TOOLS_OK`, `ISLAND_OK`, `VOICE_TURNS_OK`, `UI_STRINGS_OK`, `make test` 30/30. Reverting the three sites fails the run and **names all three** (`:423`, `:2134`, `ToolStepRunner.swift:275`) | `a2ccf86` |
| P1-18 | History budget scales with the reader's window; lift the 10,000-character session ceiling (H1 #9; takes over P4-08 steps 1–2) | 1 | P1-10a (soft: P1-02) | done | 2026-09-27 | `MEMORY_OK` (+13 cases: the 4-reader table, a 40-turn session at the 24,000 budget, per-message caps and the marker, and the voice frontend's 1,400 left alone), `TOOLLOOP_PRODUCTION_OK` (262,144 reader **18,513** chars, 4,096 reader **2,500**), `VOICE_CONVERSATION_OK`, `VOICE_TURNS_OK`, `ISLAND_OK`, `ASK_OK`, `INDEX_OK`, `SETTINGS_OK`, `make test` 30/30. Red first: 5,396 chars and no marker; the planner 6,000 | `cd60a8b` |
| P1-18 note | The `.localModel` site the task names (3,000 chars, `conversationGroundedPrompt`) **no longer exists** — P1-02 removed that path — so step 6 had nothing to change and no replacement was invented. Its fixture check `context.count <= 10_000` was **kept** rather than loosened to `maximumCharacters` as the task text says: the fixture now passes `workingBudget: 10_000` explicitly, so 10,000 is that fixture's own budget and the assertion is sharper than the task's version. The three typed sites are the first pass and the planner; the voice frontend is the fourth call site and is unchanged | | | | | |
| P1-19 | A leftover approval cannot fire against a different account or a time that has passed (OpenMuse O1) | 1 | none (soft: P1-16) | done | 2026-09-27 | New pure `Agent/ApprovalFreshness.swift` (`.fresh` / `.aged(days:)` / `.accountChanged` / `.timeHasPassed`; order = account, then time, then age). `AgentProposal` gains optional `accountTag` + `startsAt`; case E proves an old file still decodes. `GoogleWorkspaceCLI.accountTag()` — profile read, cached, `forgetAccountTag()` on auth change. `approve(_:)` is the only place the check runs; the refusal shows through the existing `ProblemBanner` and is recorded as a declined action. `TOOL_REVIEW_OK` (A–F plus the tag's own cases), `GUIDED_OK` unchanged, `UI_STRINGS_OK`, `STORE_ISOLATION_OK`, `MEETING_CONSOLE_OK`, `make test` 30/30 | `a67badd` |
| P1-19 measured | **Profile command verified before it was written**, as the task requires: `gws gmail users getProfile --params '{"userId":"me"}' --format json`. **0.40 s wall** on this Mac (0.13 s user). Output shape, redacted: `{"emailAddress": "<32 chars>", "historyId": "10632164", "messagesTotal": 62805, "threadsTotal": 55669}`. **Without `userId` it answers HTTP 400 `validationError`** — worth knowing, because it reads like a permissions problem. Compact JSON, no space around the colon, for the parser reason AGENTS.md records. **Tag rule:** the first 16 hex characters of SHA-256 over the lowercased address, lowercased *inside* `tag(for:)` so it does not depend on the caller. The address is never stored | | | | | |
| P1-19 note | The **four views needed no change**: all already call `agent.approve(proposal)`, so the check lives in `approve` and none of them decides anything — the task's own design. `bannerAgeLimit = 3` registered in 00-README §12 as a start value, with the reason it is deliberately *not* OpenMuse's 30 minutes: a short expiry would delete exactly the morning-after approvals AGENTS.md says this feature exists for. Nothing expires and nothing is deleted | | | | | |
| P1-20 | One Send/Stop control, a draft that survives, and no silent interrupt (OpenMuse O2) | 1 | none | done | 2026-09-27 | New pure `UI/Agent/ComposerControl.swift`: `ComposerControl.state(draftIsEmpty:isThinking:)` (4 states) and `ComposerNotice` with one case. One control, one `DS.Size.composerControl`, no layout shift. Draft moved `@State` → `@SceneStorage("agentDraft")`. `send()` clears only after reading the text; Stop never touches it. The interrupting-send notice is a `TimelineItem.notice` — a view row, so it cannot reach the model's history, the index or `usage.jsonl`. New `Support/SourceScan.swift` replaces three private copies. `AGENT_PANES_OK`, `UI_STRINGS_OK`, `SETTINGS_OK`, `SCHEDULE_OK`, `TOOLLOOP_PRODUCTION_OK`, `TOOL_REVIEW_OK`, `make test` 30/30 | `07cc535` |
| P1-20 note | **Step-1 finding (the task asks for it):** the draft *was* `@State private var draft = ""`, so it lived exactly as long as the view and was lost whenever the pane was rebuilt — which is what switching to Reminders and back does. Fixed with `@SceneStorage`, no new store and no new type. **Two of my own scans were wrong first** and are recorded because both would have shipped a false green: one bounded the Stop branch by `send()`, which is *supposed* to clear the draft, and the other read the Stop branch's own comment `no draft = "" here` as the bug. Hence `SourceScan.codeLines`, which strips comments — a scan that cannot tell code from prose fails on the documentation explaining what it looks for. Reverting `@SceneStorage`, or putting `draft = ""` back in the Stop branch, fails the run with all three | | | | | |
| P1-20 note 2 | Swift on this toolchain **cannot parse** `guard let x else { … } else { … }` — the second `else` reads as a new statement. Verified with a standalone `swiftc -typecheck`, not assumed; the self-test uses `if let` | | | | | |
| P1-21 | A write whose result never came back is "not sure", never "failed" (OpenMuse O4) | 1.5 | none | done | 2026-09-27 | `ActionReceiptStatus.outcomeUnknown` + hand-written `init(from:)` (unknown status → `couldNotVerify`, so a downgrade keeps its rows). `load()` decodes **element by element**; the unreadable count is logged, not swallowed. `WorkspaceCLIError.outcomeIsKnown` (4 known, 3 unknown) and one pure `ActionOrchestrator.status(forThrown:afterFiring:)`. New `Agent/WorkspaceToolRunner+UnknownOutcome.swift`: `resolveUnknown` reads Sent/drafts/events/Drive, `unknownOutcomeSentence`, `unknownOutcomeResult`. State on `WorkspaceToolResult.outcomeUnknown`, **not** in a sentence. `TOOL_REVIEW_OK`, `GUIDED_OK` **unchanged** (its fresh proposal still executes), `GWS_OK`, `UI_STRINGS_OK`, `STORE_ISOLATION_OK`, `SCHEDULE_OK`, `TOOLLOOP_PRODUCTION_OK`, `MEMORY_OK`, `ACTIVITY_OK`, `SETTINGS_OK`, `make test` 30/30. Reverting `load()` fails G2 with both messages | `3791e63` |
| P1-21 notes | **(a) G1 asserts 3 of 3 survive, not the task's 2.** With the tolerant `init(from:)` a row whose *status* this build has no word for is perfectly readable, so it is kept as `couldNotVerify`; a case written to the task's weaker number would have "fixed" the decode by dropping a readable row. G2 covers the row that genuinely cannot be read (a `String` field holding a number) and is the half the per-element decode exists for. **(b) `JSONSerialization.data(withJSONObject:)` raises an Objective-C exception on a Swift struct that Swift cannot catch.** The self-test task died there, the app fell through into the AppKit run loop, and the run reported a *hang* rather than a crash — the same class AGENTS.md records for `NSUnarchiver`. Found by `sample`ping a process whose main thread was idle in `-[NSApplication run]` with no other live thread. Pass dictionaries, never a `Codable` value. **(c) The per-element decode cannot use `Data`** — a JSON object does not decode into one, so `[Data].self` fails wholesale and the result is still an empty store, i.e. a failure identical to the bug it replaced. It uses a one-field `AnyReceiptRow` struct. **(d) A second file round-trip in G2 hung** before (b) was understood; G2 now uses one file, one store, and checks the unreadable row is still on disk after the record — which is the stronger form anyway | | | | | |
| P1-22 | Every Google write carries an identifier derived from its receipt (measure first) | 1 | P1-21 | done (calendar half) / **won't-do (Gmail half, on evidence)** | 2026-09-28 | `create_event` moved off the `+insert` helper onto the raw `calendar events insert`, with the id **derived from the proposal id** (a per-call UUID was the first version and defeats the feature — the mutation is what the fixture catches). A refused duplicate answers `completed` ("It was already on your calendar."). `GWS_FIXTURES_OK: 10 cases`, `GWS_OK`, `TOOL_REVIEW_OK`, `GUIDED_OK`, `make test` 30/30. **Live check:** one insert, one `409 duplicate`, a search returning **1 event**; probe deleted and the deletion verified | `c046785` |
| P1-22 step 1 **MEASURED 2026-09-28** — and the step ended one half of the task, as the task allows. Read-only half: `gws calendar events insert --help` and `gws gmail users messages send --help` both expose `--params` (URL/query) **and** `--json` (request body), and both bodies parse under `--dry-run` — an event body carrying `id`, and `{"raw": …}` for a message. **Calendar half: PROVED.** Inserted an event into one owned group calendar with a client-chosen id (`9f3a…7181`), then inserted the **same id** again: **exit 1, `{"error":{"code":409,"message":"The requested identifier already exists.","reason":"duplicate"}}`**. Google honoured the client id and refuses the repeat — **real idempotency, a no-op rather than a duplicate.** **Gmail half: WON'T-DO, on evidence.** Sent one message to the signed-in address with `Message-ID: <p122probe1@nextnotes.local>` (exit 0, `id=1a0e8445cc754579`, `labelIds=[UNREAD, SENT, INBOX]`); `rfc822msgid:p122probe1@nextnotes.local` found **0** messages, with and without angle brackets; fetching the message back with `format=raw` shows the header is now `<CABcArbVp…@mail.gmail.com>`. **Gmail rewrote the Message-ID**, so an exact read is impossible and P1-21's loose match stays. Both probes were deleted afterwards and both deletions verified (0 findable / 0 events) | | | | | |
| P1-22 note | **`message.raw` is `TYPE_BYTES`**: passing a literal RFC 2822 string answers `400 invalid — Base64 decoding failed`. It must be **base64url-encoded** (padding stripped). Worth recording because the error names the whole raw body, which puts a recipient address in a log line. **And a 409 duplicate arrives as exit 1**, which P1-21's `outcomeIsKnown` deliberately calls *unknown* — so `createEvent` must recognise the duplicate **itself** and answer `completed`, or the new idempotency would be reported as "I'm not sure" on the one call that is most certainly known | | | | | |
| P1-23 | The person's hand always wins: computer control yields the moment they touch the Mac (OpenMuse O5) | 2 | none (soft: P1-16) | done (live half unmeasured) | 2026-09-28 | New `Computer/HumanInputWatch.swift`, `SecureFieldRule.swift`, `ComputerYieldSelfTest.swift`, `ComputerYieldLiveSelfTest.swift`. Ten posting sites in `AccessibilitySnapshot` now go through one tagged `CGEventSource` and the per-event `post(_:)` seam. Guards in `ComputerToolExecutor` and `BrowserToolExecutor`; a browser `fill` checks the DOM `type` before typing. `COMPUTER_YIELD_OK: 76 grant-free cases` (INTEGRATION), `CLICK_COORDINATE_OK`, `COMPUTER_VISION_OK`, `UI_STRINGS_OK`, `TOOLLOOP_PRODUCTION_OK`, `TOOL_REVIEW_OK`, `SCHEDULE_OK`, `MEMORY_OK`, `make test` 30/30 | `5b2c10b` |
| P1-23 **MEASURED 2026-09-28** | **`eventSourceUserData` SURVIVES** `post(tap: .cghidEventTap)` and reads back in a listen-only tap on this Mac, so the mechanism is a **tag**, not the timestamp window the task offers as the fallback. The fallback is implemented anyway — a driver that dropped the field would otherwise have the agent read its own clicks as the person. **Yield latency: NOT MEASURED.** The live half did not run: `AXIsProcessTrusted()` answers **false even through `--via-open`**, and the harness window is not frontmost. That is the known red state on a locked screen, the same one `--selftest-computer-actions` is in and which this task did not change — the environment answer, **not a pass**. Y1–Y5 therefore remain unrun; only the grant-free half is green | | | | | |
| P1-23 notes | (a) **A pause belongs to the turn, not the call.** `endAction()` originally cleared the state, so the agent yielded for one call and resumed by itself on the next — the person reached for the mouse and the plan carried on regardless. Only "carry on" and a new request clear it now, and `RealtimeAgent.handle` calls `resetForNewTurn()`; the mutation is what the case catches. (b) **`SecureFieldRule` was one function too many**: `mustBeLeftToThePerson` and `refusal` disagreed on two of six cases and the grant-free table caught it — the first now delegates rather than being deleted. (c) `AXTextField`/`AXComboBox` are deliberately **not** secrets; refusing every ordinary field would refuse the whole app. (d) The guard sits in the per-**event** seam, not per tool call: a `scroll` is ten events, so a per-call check would let the agent finish nine more after the person reached for the mouse | | | | | |
| P1-24 | An answer about your mail, calendar or Drive comes from reading them; a short offer is an offer (J L1–L5) | 1 | P1-11, P1-07 | done | 2026-09-27 | `--only O01,O02,O04,O09` **`TOOLLOOP_LIVE_OWNER 1/4 → 3/4`**: O04 PASS with the guard's own `query=in:inbox`, O02 PASS, O09 PASS, O01 still UNGROUNDED (see note). Ten pure cases in `--selftest-toolloop-production`; `TOOLLOOP_PRODUCTION_OK`, `TOOLLOOP_OK`, `VOICE_TURN_ROUTING_OK`, `VOICE_CONVERSATION_OK`, `NATIVE_TOOLS_OK`, `make test` 30/30 | `9f49a37` |
| P1-25 | An id in an action comes from something read or said, never from the model (J L13, L22) | 1 | none (soft: P1-19) | done | 2026-09-27 | I1–I4 green in `--selftest-toolloop-production` plus "every id parameter is marked" and "nothing else claims to be one"; four parameters marked (`read_email.message`, `read_doc.document_id`, `append_doc.document_id`, `reply_email.message_id`); `TOOLLOOP_PRODUCTION_OK`, `TOOLLOOP_OK`, `NATIVE_TOOLS_OK`, `CAPABILITY_MANIFEST_OK`, `make test` 30/30 | `361078c` |
| P1-26 | "Clear conversation" starts a new one; it does not erase every past conversation (J L20, L21) | 1 | none | done | 2026-09-27 | `--selftest-index` **case inverted** and `INDEX_OK`: "New conversation" keeps every earlier session's passages, "Forget all conversations" removes them. `SEARCH_OK`, `MEMORY_OK`, `MEMORY_REVIEW_OK`, `UI_STRINGS_OK`, `PERSONA_OK`, `TOOLLOOP_PRODUCTION_OK`, `make test` 30/30 | `62f70f6` |
| P1-27 | The Phase 1 gate includes the owner's own failed requests (O01–O10, `TOOLLOOP_LIVE_OWNER`) | 1 | P1-01 | done | 2026-09-27 | `TOOLLOOP_LIVE_OWNER 6/10` on a full 40-case run (`TOOLLOOP_LIVE_SCORE 17/30`, 390.6 s, Qwen3-4B-Instruct-2507) — the thirty did not move. `TOOLLOOP_LIVE_GRADER_OK` with 14 new pins; `--quick` 5/10; `make test` 30/30 | `5c15739` |

| P1-28 | The prompt cache survives a conversation: size the context once, keep the prompt's front stable (J latency) | 1.5 | none (P0-18 done) | done (R1/R3 unmeasured) | 2026-09-28 | New `AgentPromptContext.volatileTail`, joined **last**; the catalogue split into `coreIDs` (section 5, stable) and the earned entries (the tail); `plannerRules` returns fixed rules only. **Stable prompt front measured at 90 %, up from 73 %** (R2, pure — no model needed, and the number is on the marker). `NotesModelRuntime.refusesToLoadForLaunchDiagnostic()` refuses the load under a launch-time diagnostic. New `model.unload` span with `reason=idle\|pressure\|switched\|trial\|shutdown\|error` in the existing `metrics.jsonl`. `LLM_PREFIX_CACHE_OK: … stable prompt front 90% (was 73% before P1-28)`, `NATIVE_TOOLS_OK`, `CAPABILITY_MANIFEST_OK`, `TOOLLOOP_PRODUCTION_OK`, `TOOLLOOP_OK`, `TOOL_REVIEW_OK`, `VOICE_TURNS_OK`, `MEMORY_OK`, `GUIDED_OK`, `RESIDENCY_OK`, `make test` 30/30 | `927b8c8` |
| P1-28 notes | (a) **R1 and R3 need the Agent-role model, which is not on this Mac, so they did not run** — the task's own instruction is to print `LLM_PREFIX_CACHE_ABSENT` and never OK, and the marker says the model is absent. R2 is the substance of cause 2 and is **pure**, so it runs regardless. (b) **The context was NOT resized** (target 1) — §12's "max context 32,768" and the memory cost of a larger context are unmeasured here, and resizing a live KV cache is a memory trade that should be measured on the machine that pays for it. Recorded as not done rather than done quietly. (c) The first version of the diagnostic list included `--selftest-`, which **broke** `--selftest-llm-prefix-cache`: its live half drives a *private* runtime and legitimately needs a load. A self-test reaches a model through private instances and temp stores already; what it must never touch is the shared runtime. (d) `--selftest-native-tools`' catalogue case had to change: it asked whether one contiguous string was present, and the catalogue is now in two places. The question is now stronger — every selected id appears *somewhere* in the prompt | | | | | |
| P1-29 | One turn id across the existing logs; card, clear and near-miss wake events recorded; audit file rotates | 1 | none | done | 2026-09-28 | `AgentAuditEntry` gains optional `turnID`/`conversationID`, stamped in `AgentAuditLog.record` — **the one writer** — so every row joins the usage log's existing ids by construction rather than by remembering at each call site. `LatencyCorrelation` gains `turnID`; both `decodeIfPresent` because the keys postdate the files. Card lifecycle rows: shown (`PermissionGate.present`), cancelled (counted, at the gate rather than at its five entry points), expired (`FunctionCallWatcher`'s 180 s wait). Erasure rows: session end, compaction, new conversation, forget-all — counts and no text. `WakeWordTelemetry.recordNearMiss` fed by the score `WakeWordDetector.spotPhonetically` was discarding; gate is `nonisolated` + `OSAllocatedUnfairLock` so real-time code never hops to decide. Audit file rotates at 8 MB into `agent-audit.1.jsonl`; the in-memory cap is now `AgentAuditLog.memoryRows`. `--usage-report --usage-turn <uuid>` prints one turn across both logs. `ACTIVITY_OK`, `WAKE_OK`, `USAGE_LOG_OK: 25 cases` | `dfedb87` |
| P1-29 notes | (a) **The near-miss floor is measured, not chosen**: `WakePhraseConfirmation` scores *any* speech with vowels against the phrase, so idle conversation lands near the bar by accident — "so what did you think about the roadmap" **0.260**, "the weather is nice today" **0.333** — while the sound-alikes worth tuning on sit well above ("hey world this is a long sentence about the weather" **0.667**). The task's implied "half the bar" is 0.325 and **admits chit-chat**; 0.50 separates the groups and is written as an offset from `acceptedCloseness`. (b) **"hey we need" cannot be the test case**: it scores 0.900 and is **accepted** — the accent tolerance working — so it never reaches the rejection path. The rejection that matters is a sound-alike *inside* a longer sentence. (c) A real bug in my own first cut, found by the test: the throttle read `guard let last = stamp, … else { return false }`, so **the first near miss of a session was the only one ever written** and every later one was blocked by the 10 s interval. (d) This file's `check(name, condition)` names the **failure**, and three of my four first-draft assertions were inverted against that convention — reporting a leak, a miscount and a wrong answer that had not happened. The convention is now stated in the test. (e) **Pre-existing red found while verifying**: `--selftest-usage-log` E1 ("the typed turn wrote no answer row for its turnID") fails **identically at HEAD with this work stashed**. P0-20a's guard, not introduced and not fixed here. (f) The 13 Sep fixture rows are **17 of 768** by dry run; the owner applies them (`--apply`), an agent does not | | | | | |
| P1-30 | Memory review keeps no one else's words, and nothing after "clear" (J L17) | 1 | none | done | 2026-09-28 | `requests[]` keeps key/date/session only. `RoutineSuggestion` loses `request` **too** — the sentence was in the same file, so the log's `text` alone was half a fix. `refused`/`skipped` are a reason and a count, collapsed by reason; `saved` holds memory entry ids, not the facts' text. A `.cleared` conversation is **purged, not reviewed**: the clear is still announced, and `MemoryReviewScheduler.enqueue` is the one writer that drops the queue and moves the watermark past it. Retention goes from counts-only to 30 days **and** a resolved suggestion's rows; both at load. One-time migration rides on `version` 1 → 2, with lenient decoders dropping the old `text` values. `MEMORY_REVIEW_OK` (marker unchanged), `MEMORY_OK`, `SCHEDULE_OK`, `make test` 30/30 | `4a4abac` |
| P1-30 notes | (a) **The offer can no longer quote what was said, and that is the real cost.** `phrase(for:)` presents the key as a list because a key sorted alphabetically is not an order anyone spoke in, and curly quotes would claim those words were said together by this person. (b) **Two existing assertions changed** — they pinned exactly what the task reverses: one asserted a clear *replaced* the queued review with a `.cleared` job holding the whole session, the other asserted the offer contained "what", which is in `filler` and so is not in the key for "what's on my calendar today?" (that key is just "calendar"). (c) **The privacy finding on this Mac**: `agent-memory-review.json` is version 1 with **82 request rows, all carrying text**, 41 refused + 67 skipped decisions carrying proposed-fact text, and 4 saved facts duplicated. The microphone does not distinguish speakers, so side talk was saved as the owner's words. It migrates at the owner's next launch. (d) A first draft of the pruning case seeded `timeIntervalSince1970` where the store encodes `timeIntervalSinceReferenceDate` — the rows landed 31 years in the future, the 31-day row passed, and the test was **green for a store that had pruned nothing**. (e) An early assertion that a resolved key needed a second explicit `prune` call was also backwards: `load()` prunes, so seeding and loading **is** the behaviour | | | | | |
| P1-31 | Needle 3 System One executes the first tool; Agent-role mid-sized LLM System Two answers and continues | 1 | P1-01, P1-03, P1-05, P1-06 | in progress; no promotion | 2026-09-30 | [Current paired investigation](../../../Tests/Reports/toolloop-live/2026-09-30-p1-31-investigation.md): all four installed candidates quick-tested; Qwen full ordinary 17/30, owner 7/10 vs Needle 16/30, owner 8/10. Whole-case p95 49.038 s vs 51.012 s. Gates failed; ordinary path retained. Other candidates' full runs, live negatives, first-token/audible/overlap and repeated gate runs remain. | — |
| P1-31a | ↳ First-call validation, continuation, answer claim guard, fixture roster and measurement evidence | 1 | P1-31 | done (bounded slice) | 2026-09-30 | Red-first policy and claim/denial failures preserved in report; `TOOLLOOP_PRODUCTION_OK`; `USAGE_LOG_OK: 25 cases`; 30 dictionary tests pass. Usage protocol test corrected to P1-02's two-round typed path. Native tools independently remains 4/5 grammar-valid, not green; parent quality gates unchanged. | `ac3b852` |
| P1-31b | ↳ Honest timeout/claim classification and broad-mail grounding; reject prompt experiment | 1 | P1-31a | done (bounded fixes; parent gates failed) | 2026-09-30 | Final rebuilt/installed grader, production and capability checks pass; 30 dictionary tests; `TOOLLOOP_LIVE_GRADER_OK`, `TOOLLOOP_PRODUCTION_OK`. Candidate ordinary quick 5/10→4/10, new WRONG_TOOL; prompt changes removed. Heavy-load warm-up interrupted without a score. [Report](../../../Tests/Reports/toolloop-live/2026-09-30-p1-31b-follow-through.md) | `163ba41` |
| P1-31c | ↳ Explicit personal memory saves at the action producer | 1 | P1-31a | done (bounded fix; parent gates failed) | 2026-09-30 | Actual Y01 bad-output replay red→green; guarded durable save and rejection flows, `TOOLLOOP_PRODUCTION_OK`, 30 correction tests. Y01 ordinary and Needle-first-enabled PASS; fixed quick 4/10→5/10 still below 9/10, p95 51.417→59.094 s. [Report](../../../Tests/Reports/toolloop-live/2026-09-30-p1-31c-explicit-memory.md) | `4063667` |
| P2-01 | Per-stage voice latency spans, `--selftest-voice-latency`, and the main-actor stall | 2 | P0-06, P0-11, P0-20a, P4-01 | in progress | 2026-10-08 (previous: 2026-10-01) | **Reconciled 2026-10-08 (state unchanged):** matched voice-preparation pair, 1 warm-up + 5 measured turns ([5bbdf53](../../../Tests/Reports/agent-overhaul-progress/voice-preparation/verification.md)): median L1 1.778 -> 0.671 s, L2 3.322 -> 2.448 s, L3 3.777 -> 2.649 s; original main stall 122 ms failed the unchanged 100 ms limit, fixed 36 ms p90 passes. Installed `eac522c` split-prewarm run ([32209bc](../../../Tests/Reports/agent-overhaul-progress/p2-split-prewarm/verification.md)): speech-end->audio 3.788/4.139/4.241 s, diagnostic UNQUALIFIED (warm-up counted two commits), exit 1 on the 0.9 s gate. L1/L2 200 ms and 0.9 s first-audio targets NOT met; no latency or phase promotion. The original WAV is missing, so these are a new baseline, not a repeat. **Historical (2026-10-01, state `in progress`):** Installed instrumentation green. Original warm-up + five native turns failed: median first audio 4.776 s, worst stall 156 ms, missing speculative usage IDs in all five and duplicate commit in run 5. Usage producer fix committed bdd9766: original/current producer red→green and installed five native usage joins pass. Current median2.894s; cold duplicate remains open. No latency/phase promotion. |  |
| P2-02 | Prewarmed frontend sessions and one streamed frontend decision | 2 | P2-01, P0-06 (coordinate: P1-03, P1-07) | in progress | 2026-10-08 (previous: 2026-10-03) | **Reconciled 2026-10-08 (state unchanged):** split-session prewarm verified ([32209bc](../../../Tests/Reports/agent-overhaul-progress/p2-split-prewarm/verification.md)): original 17979 focused contract 9 failures -> fixed 18218 pass; real SDK corpus consumes the exact prewarmed route in all 14 successful route calls and the answer in all 7 answer calls; the unchanged corpus still fails the same 2 calendar cases (status classified as spawn; missing task identity). Untouched prewarmed answer survives a cancel before inference ([cb19aef](../../../Tests/Reports/agent-overhaul-progress/p2-unconsumed-answer-stage/verification.md), original RED2 -> pass). `--voice-latency-first-token-budget 0.600` is now enforced ([2ecafc6](../../../Tests/Reports/agent-overhaul-progress/p2-first-token-budget/verification.md), original 4 failures -> pass; instrumentation only). **Single streamed decision REJECTED** ([f6a1fd2](../../../Tests/Reports/agent-overhaul-progress/p2-single-decision-rejected/verification.md)): single 12/15 vs split 13/15 on the same 15 authored cases; split stays in production. Open: production mode selection, 0.6 s first-token and 0.9 s first-audio gates, routing quality (2 calendar failures), native cancellation, speed benefit not established. **Historical (2026-10-03, state `in progress`):** Parallel isolated worktree implementation underway: existing native staging/session owner, intent-only route and diagnostic single streamed decision. Production mode unchanged pending actual routing corpus/cancellation/concurrent-request/latency qualification; source drafts are not passing evidence. | |
| P2-03 | Append-tolerant speculation, started on quiet and on the early EOU | 2 | P2-01, P2-02, P2-04, P0-06 | in progress (bounded children verified) | 2026-10-08 | **Reconciled 2026-10-08 (was `todo`):** bounded producers verified, parent exit open. Frozen playback context so a committed turn adopts the prepared producer ([d209b29](../../../Tests/Reports/agent-overhaul-progress/p2-frozen-playback-context/verification.md)); committed courtesy reuse for exactly 'please'/'thanks'/'thank you' ([61fadf0](../../../Tests/Reports/agent-overhaul-progress/p2-speculation-courtesy/verification.md), 15 actual cases, 3 original failures -> pass); dictionary-corrected preparation reuse ([22675db](../../../Tests/Reports/agent-overhaul-progress/p2-dictionary-preparation/verification.md), original RED5 -> pass); early lexical preparation for 160/199 ms inputs ([bfee5fe](../../../Tests/Reports/agent-overhaul-progress/early-lexical-preparation/verification.md), original 3 failures -> pass); `--voice-no-speculation` made effective ([b6a3a22](../../../Tests/Reports/agent-overhaul-progress/p2-no-speculation/verification.md), original fails the unchanged producer assertion). Open: partial->partial cancellation (caller/epoch integration), route-only reuse, Smart Turn arbiter (P2-04, still `todo`), native hit rate and speed (not recorded). **Historical:** no evidence recorded. |  |
| P2-03b | ↳ (Optional, upstream) FluidAudio EOU-signal callback PR | 2 | P2-03 | todo | | | n/a (upstream PR) |
| P2-04 | Smart Turn v3.2 (CoreML) as the end-of-turn arbiter; lower debounce and fallbacks | 2 | P2-01, P0-10 | todo | | |  |
| P2-05 | VAD-driven ducking barge-in (FluidAudio Silero VAD) | 2 | P2-01 (best after P2-08) | in progress (bounded children verified) | 2026-10-08 | **Reconciled 2026-10-08 (was `todo`):** bounded native VAD ducking ([5a8a363](../../../Tests/Reports/agent-overhaul-progress/p2-vad-duck/verification.md)). Silero 6.0 on cleaned 16 kHz PCM, one 4096-sample window; real player gain 0.3 before bargeDuck; original host RED6, Pocket RED2, same-fixture AEC replay RED3 -> fixed pass. Final binary `8108942b...`: 66 native Pocket probes, duck 0.593321 s before the lexical pause at 1.132846 s, stop 3.793065 s. **Cold 200 ms still FAILS** (sole VOICE_BARGE failure; no retry, fixture padding or threshold relaxation). Warm replay: echo-only 65 probes no duck; double-talk duck 0.1459375 s sample-time (not wall-time, not a physical room). Open: <= 200 ms live, physical echo, stable latency, Phase 2 readiness. Native barge controls on Pocket: voice-to-pause 1.130 s, voice-to-stop 2.571 s ([8aeb7fb](../../../Tests/Reports/agent-overhaul-progress/p2-pocket-native-controls/verification.md)), prescribed <= 0.838 s not met. **Historical:** no evidence recorded. |  |
| P2-06 | TTS pipelining: one `PocketTtsSession` per reply, synth-ahead, engine kept running, comma-first chunk, first-audible ack | 2 | P2-01, P0-09 (P2-07 recommended first) | in progress (bounded children verified) | 2026-10-08 | **Reconciled 2026-10-08 (was `todo`):** reply-scoped `PocketTtsSession` ([4c96d09](../../../Tests/Reports/agent-overhaul-progress/p2-pocket-reply/verification.md)). Original3: 11 delivery assertions and 9 native-pipeline assertions fail (engine restarted 3 times, first callback 104.186 ms, signed gap estimates 171.808 / 166.807 ms). Fixed engine: one engine start, first played callback 34.032 ms for a 240-sample head, gap estimates -9.989 / +9.720 ms (callback granularity, not acoustic silence), three clauses with exact ordered receipts. Also verified: first clause starts before sentence end ([33b5baa](../../../Tests/Reports/agent-overhaul-progress/p2-first-speech-chunk/verification.md), original RED11 -> pass); inter-clause gap spans now emitted ([961d6d8](../../../Tests/Reports/agent-overhaul-progress/p2-pocket-gap-spans/verification.md), original 3 failures -> spans match native callbacks within 1 ns); Apple voice answers immediately while Pocket is still preparing ([0cd52da](../../../Tests/Reports/live-freeze-2026-10-06/voice-readiness/verification.md), original 2 failures -> VOICE_SUSPEND_OK; host-availability mitigation). Open (report says P2-06 is not fully closed): physical gap and prosody, prescribed full voice-latency/barge runs, live full-duplex acceptance; no `--selftest-tts-pipeline` marker is cited by these reports. **Historical:** no evidence recorded. |  |
| P2-07 | EOU and Pocket resident; prewarmed at launch or arm | 2 | P2-01 | in progress (bounded children verified) | 2026-10-08 | **Reconciled 2026-10-08 (was `todo`):** bounded residency/preparation producers verified, no launch-time latency distribution measured. Cached EOU preparation at wake-arm/manual activation ([ee4b59b](../../../Tests/Reports/agent-overhaul-progress/p2-resident-eou/verification.md), original 3 pre-capture assertions fail -> pass; cache-only, busy/pressure/thermal/quit refuse); EOU reuse across sessions ([1952172](../../../Tests/Reports/agent-overhaul-progress/eou-session-reuse/verification.md), original 6 failures with two loads -> one load; single paired prepare 2.337 s / 0.312 s -> 0.847 s / 0.000690 s, not a distribution); Capture-owned Silero residency ([120b72d](../../../Tests/Reports/agent-overhaul-progress/p2-resident-silero/verification.md), original 5 failures -> pass); Pocket preparation bound to the selected voice ([800d6f9](../../../Tests/Reports/agent-overhaul-progress/p2-pocket-prepare-voice/verification.md)). Open: live residency under pressure, quit with active microphone/playback, the endSession frontend-await/reopen race, independence from model roles. **Historical:** no evidence recorded. |  |
| P2-08 | Smaller audio I/O buffers (capture and output) | 2 | P2-01 (do last) | todo | | |  |
| P3-01 | Step 0: tests describe production | 3 | P0-07, P0-11 | done | 2026-10-01 | Installed old-route regression red→green; original correction refill sign fixed with unchanged budgets. All nine flags passed; C1/nil-frontend mutation failed; restored actual round two started in 8 ms. Core passed 17/18 with only the unchanged wake failure. [Report](../../../Tests/Reports/voice-production/2026-10-01-p3-01.md). Phase quality and readiness gates remain open. | `c1e635b` |
| P3-02 | C2 full: the input barrier applies only when an effect commits | 3 | P3-01, P0-07 | done | 2026-10-01 | 7e3aba1: installed old-producer red; final three duplex runs OK (2 overlaps, max45ms, tab@1), related flags and corrected original capture scenario pass; broken post-wait revision check fails. Core16/18 retains wake/dictation failures; no phase/model/IM-16 promotion. | 7e3aba1 |
| P3-03 | TaskBridge: one ledger for voice jobs, typed tasks and ACP; status from the ledger | 3 | see subtasks | in progress | 2026-10-03 | P3-03a canonical admission/status, truthful outcome and same-job input continuation have actual bounded producer proof; full public API, revisions, ACP ledger/live ownership migration remain open. | |
| P3-03a | ↳ `TaskBridge` ledger behind the coordinator; status gate | 3 | P3-02, P3-06a | in progress | 2026-10-03 | Actual219 RED14/47 →220 PASS47 and12 related flags. Metadata/status/task-start original235 RED33/85 →fixed236 PASS200 (metadata52/time33/Foundation51/encoding64), shadow289/divergences0; all15 related flags PASS including unchanged authority58/worker2366 and isolation21files32defaults. Rejected234 legacy/clock regressions are repaired at same SQL ownership and genuine transition timestamps; original failures retained. Truthful outcome/same-job input is bounded-verified: corrected original244 RED17/52 → fixed246/248 PASS68 plus prior200 and shadow489/divergences0. Corrected routing original247 RED30 →fixed248 PASS: six unchanged acknowledgement phrases retain one SQL row/same job+worker+Work and commit answer before the second run. Twenty other246 related flags pass (worker2678); final248 lifecycle and isolation21files32defaults pass. Invalid243 and introduced245/old246 routing failures remain retained. Live grounding244/246 fails identically on timeout attribution; this inherited model-quality gate stays open. Public duplicate/current-session answer admission265 and canonical revision274 have bounded verified evidence below; Canonical ordered public progress now passes46 in300 below; generic waiting-permission/full API/legal-transition producers, delivery/ACP/live ownership remain open. [Outcome proof](../../../Tests/Reports/agent-overhaul-closure/p3-task-bridge-production/voice-outcome-input-production/verification.md). [Proof](../../../Tests/Reports/agent-overhaul-closure/p3-task-bridge-production/canonical-metadata-production/verification.md). | |
| P3-03a-1 | ↳ Canonical ordered public voice progress | 3 | Existing same-Manager worker and primary admission; bounded§4.1 | done (bounded) | 2026-10-04 | Corrected original299 RED11/46 →300 same46 PASS via actual planner/confined files/Activity/Manager/SQL/status. Exactly2producer deltas/1112compiler inputs; all29 related flags pass including worker2678 and owner isolation. SQL rollback/export admission and stale revision/cancel-refusal/session-closed feed refusal pass. INVALID296–298 intended-read policies retained. No heartbeat/effect/general latency/legal-state/ACP/recovery/live UI or parent claim; coherent source delivery remains open. [Proof](../../../Tests/Reports/agent-overhaul-closure/p3-task-bridge-production/manager-voice-worker-ownership-production/verification.md). | |
| P3-03b | ↳ One ledger including ACP; delete `Coordinator.jobs` | 3 | P3-03a | in progress | 2026-10-04 | Same-Manager ownership57, ordered progress46 and cancellation14 retained. Qualified original310 RED102 →fixed311 functional status285/stored-copy28/mixed-result7/selector-helper17 PASS with unchanged strict copy/origin/two-row companion controls. All28 other integrated flags PASS, including delivery/worker2678/authority58/restoration188/ACP/MCP/isolation21files32defaults. Whole lifecycle still FAILED solely on unchanged5ms receipt target (5.416916ms); stable latency remains open. Original306 copy/latency and309 fixture-contract failures, invalid308 compiler exit and earlier invalid builds retained. Stored-copy projections do not prove legal transitions; ordinary punctuated selector callsites now pass19 in315 after original314 six actual failures; original model/account/effect acceptance remains open. ACP original316 qualifies40 checks/15 target failures. Actual scalar320 confirms the unverified warning is truthful; strict SAME-COMMON full warning/receipt assertions qualify original321 RED1 closed-retirement defect →fixed322 same78 PASS and whole lifecycle exit0 with source/bundle invariance. The reducer now consumes exact terminal IDs while closed without reopening/resetting background work; all29 related flags PASS. Packaging319 failed ENOSPC after compilation and is INVALID; original317 signing failed and is INVALID. Stable5ms timing, actual provider/account/effect/ACP activity/revision/approval and full task transitions remain open. Terminal COMMON original323 qualifies seven actual defects across19 added checks (voice3/scheduled4), durability37 PASS. The superseding33-check terminal fixture adds the expected late unbound-worker boundary; serial329 RED13 is qualified and fixed330 terminal33 passes with worker2702/durability37; all28 other integration flags PASS; unchanged lifecycle5ms FAIL. Typed frontend receipts and spoken approvals remain parallel preparations; typed critical-number/negation/ack and compile corrections precede native proof. No parent/live/recovery/cessation/phase or clean-checkout/installation claim. [Proof](../../../Tests/Reports/agent-overhaul-closure/p3-task-bridge-production/manager-voice-worker-ownership-production/verification.md). | |
| P3-04 | OutputScheduler / AgentDelivery: the only thing that starts audio | 3 | see subtasks | in progress | 2026-10-03 | Bounded completion123 and status/order/carryover168 pass actual original/fixed and26 related flags; exact question/approval, phrasing, sessionless heads-up and all-audio/live-token ownership remain open. | |
| P3-04a | ↳ `OutputScheduler` for deliveries | 3 | P3-03a, P3-06a, P2-06 | in progress | 2026-10-03 | Bounded actual completion delivery verified: corrected original250 RED38/123/control0 →fixed253 same123 PASS plus all26 required related flags (worker2678/restoration188/authority58/isolation21files32defaults). Same Manager completion →primary delivery →one queue →existing speak-owned OutputID/current generation/listener; codec marker2 preserves legacy unowned bytes. Original249 INVALID is retained. Introduced251 legacy selection failure measured252 (canonical quiet=false selected before eligible legacy) is repaired253 at eligibility producer; exact same fixture/observer passes with canonical rows retained. Actual approval priority, phrasing, sessionless heads-up, all tokens/physical onset and full parent remain open. Bounded status/order/carryover extension now verified: corrected original257 RED8/168/control0 →fixed258 same168 PASS and all26 related flags. Historical254–256 expiry inputs INVALID (negative age); SAME COMMON real row finishedAt+43201 qualifies257. Same primary status consumption, genuine chronology/bounds, queued expiry silent commit and exact refusal retention pass. Exact question delivery now bounded-verified: corrected original260 RED20/276/control0 →fixed261 same276 PASS and all26 related flags. Same saved request/current original recipient, software OutputID/onset, question-before-result, exact answer/cancel withdrawal and stale-token/same-text successor pass. Original259 type-invalid retained; SAME COMMON typing corrected beforeboth. Actual approvalP3-08, phrasing, D13, all-token/physical/live/full parent remain open. [Question proof](../../../Tests/Reports/agent-overhaul-closure/p3-task-bridge-production/output-delivery-question-production/verification.md). [Parent proof](../../../Tests/Reports/agent-overhaul-closure/p3-task-bridge-production/output-delivery-status-carryover-production/verification.md). | |
| P3-04b | ↳ All audio through `OutputScheduler` (`OutputToken`) | 3 | P3-04a | in progress | 2026-10-04 | Actual390 RED8/23 →391 SAME23 PASS via existing Scheduler/audio/tracker/scheduled consumers: stale append/finish/cancel/replay/fixed replies and wrong answer attribution refused. Prior636/Gate controls pass;29/30 integration flagsPASS, inherited5ms fails. COMMON16caller/interface paths preserved; exactlyfour producer compiler delta. Delivery priority actual395 RED10/85 →396 SAME85 PASS (scheduler721/token23), only Scheduler producer changed; unheard results retain no attempt, heard results require current committed turn, refused retirement cannot replay. Related396 passes29/30 after unchanged worker2710 repeat; first history/noReview failure retained, cause unproven. ModelsSettingsTab preview source-adopted, private preview/native interaction not exercised. All-caller/physical/cessation/latency/full dependency gates open. [Priority proof](../../../Tests/Reports/agent-overhaul-closure/p3-task-bridge-production/manager-voice-worker-ownership-production/priority396-qualified-results.json). | |
| P3-05 | Receipt-first frontend contract and no-filler prompt rules | 3 | P3-03a, P3-04a, P2-02 | in progress | 2026-10-04 | Actual original324 reports59 target failures/84; fixed325 typed84 PASS introduces D8 original-field corruption, retained as FAILED. SAME corrected F05 exact-objective+raw-prompt COMMON qualifies326 RED2 →327 same84/whole routing PASS with unchanged D8. Coordinator passes exact objective/raw into SAME Work; immutable optional raw words format only its existing prompt. All9 focused related flags PASS including durability37/authority58/isolation21files32defaults; terminal original32913 defects are bounded-fixed330; lifecycle5ms/full legal-state acceptance remains separate. Actual model routing-only324/327 both exit1 on the same two calendar inputs (original incomplete/new status0 on the second). Answer first-text deltas range-41…612ms in one ordered pair; these include answer generation, not isolated route-end/first-audio/display timing.100ms route-overhead acceptance remains OPEN. Ordered revisions now have original348 RED6/81 →fixed349 same81/whole routing PASS; exact raw words reach the same worker and primary row. Four schemas now have actual354 RED22/98 →355 SAME98 PASS; offered model approval53 and voice ACP56 pass with28/29 integration. Same frontend actor/decision adapter and D3 now have bounded364→365627 proof, with corrected52 routing and duplex passing; actual Gate companion now636 PASS386 with exact full streamed prompt/current approval/zero effects; output tokens/priority, ordinary no-filler answer rules, model/cloud/live eval, stable latency and P2-02/full parent remain open; P2-02 dependency and full parent are not promoted. | |
| P3-06 | VoiceSession reducer and VoiceEvent stream; TurnID / OutputID / TaskID | 3 | see subtasks | in progress | | |  |
| P3-06a | ↳ Contracts + reducer in shadow mode | 3 | P3-02 | in progress | 2026-10-03 | Bounded foundation committed: installed10traces/121events/zero40comparisons4fields; concurrent/lifecycle/duplex observed zero with unavailable floor4/0/3. Recorded replay exits0; invalid traces/refusal exit1; scripted teardown no live wake subscription. Core16/18 wake/computer failures. Actual explicit-cancel event original197 RED2/14→198 PASS14/full lifecycle and six related flags PASS; one Coordinator producer, deterministic/parsed real workers, stale/reset/close negatives and zero divergences. Actual206 RED3/12→207 PASS12 now emits exact same-work naming/parsed revisions1/2/3 through the existing private recorder, with prior cancel14 and six related flags PASS. Only Coordinator differs across1,076 compiler inputs. [Revision proof](../../../Tests/Reports/agent-overhaul-closure/voice-work-revision-shadow-production/verification.md). Physical pipeline/barge/rapid, remaining full event coverage and full-suite coverage open; no ownership switch. [Cancel proof](../../../Tests/Reports/agent-overhaul-closure/voice-explicit-cancel-shadow-production/verification.md). | `5ecc7e6` |
| P3-06a-1 | ↳ Repair shadow playback pause/end/proposal projection at its producer | 3 | Existing shadow contracts; bounded §4.1 | done (bounded) | 2026-10-02 | Original92 RED13 → identical fixed93 PASS33; common reducer RED6 →10traces/actual121events/zero39comparisons4fields. All20 focused flags and native trace replay PASS;1041Source/fullbundle invariant. Actual Apple callbacks reach confirmed capture pause; no fake native receipt/model/mic/live ownership. Original WAV latency ABSENT; postresume receipt/epoch, late-after-resume and actual Gate/Island acceptance open. [Proof](../../../Tests/Reports/agent-overhaul-closure/voice-playback-projection-prerequisite/verification.md). | 1db83e3 |
| P3-06a-2 | ↳ Capture original post-resume receipt ownership failure | 3 | Existing capture/playback owner; native epoch/progress prerequisite | in progress | 2026-10-02 | Original94 real28 checks/RED4, all input/token/owner/cleanup controls valid. Neutral common nil SelfTest observer at existing synchronous resume seam. Historical heard/late-before-pause packet still unsafe; current99 same28 RED4. Separate97/98 native diagnostic22 passes but supplies no positive authority; Negative repair100 RED4 →101 same48 PASS below; qualified positive resume authority and live UI remain open. [Original proof](../../../Tests/Reports/agent-overhaul-closure/voice-playback-projection-prerequisite/resume/original94-verification.md). | 54ec8a4 |
| P3-06a-3 | ↳ Actual owned Apple player timeline diagnostic | 3 | P3-06a-2 real resume failure | done (bounded) | 2026-10-02 | Corrected97 RED3 → identical98/99 native22 PASS; all buffers join, old/stopped packets rejected. Invalid96 recorder overflow retained. Future clocks/partial-tail candidates are not acoustic/live speaking authority; original resume RED4 remains open. [Proof](../../../Tests/Reports/agent-overhaul-closure/voice-playback-projection-prerequisite/resume/timeline/verification.md). | c29ec53 |
| P3-06a-4 | ↳ Repair actual render-tap shutdown lock cycle | 3 | Same native suspend/stop producer | done (bounded) | 2026-10-02 | Actual98 hangs main engine.stop vs tap engine.outputNode; sampled lock cycle →99 same native flow PASS4times, exact1Source delta. Existing lane query+epoch guard, no new queue/wait/cache.31 focused final passes; initial worker metrics anomaly unattributed/open; quality/physical/parent gates remain open. [Proof](../../../Tests/Reports/agent-overhaul-closure/voice-playback-projection-prerequisite/resume/timeline/tap-shutdown/verification.md). | c29ec53 |
| P3-06a-5 | ↳ Refuse historical playback as resumed speaking at both producers | 3 | P3-06a-2 actual failure; existing shadow owners | done (bounded) | 2026-10-02 | Original100 RED4 → identical101 PASS48 (native28+commonrepeat20); exact3producer deltas in1046manifest. History retained, physical resume unchanged; old onset cannot promote awaiting.23 focused flags PASS incl reducer10/121events/zero40comparisons, worker1352, native suspend/drain/restart and isolation21files32defaults. No positive backend receipt/live UI/latency/phase claim; shadow pending can persist. Final101 quickFAILED3/10 (84.8s), core21/22 unchangedwake, awarenessPASS; emailtimeout passes/browserUNGROUNDED remainsopen. [Proof](../../../Tests/Reports/agent-overhaul-closure/voice-playback-projection-prerequisite/resume/negative-contract-verification/verification.md). | 7225a39 |
| P3-06a-6 | ↳ Qualified same-clause Apple resume publication into existing owners | 3 | P3-06a-5 negative contract; actual owned player | done (bounded) | 2026-10-02 | Original102 RED6 after actual2qualified backend receipts → identical103 PASS44/proofs2/events2/resumes2;2232callback joins, late-origin/repeated/stop/replacement controls green. Exact1producer-body delta in1047 common manifest. All25 focused flags PASS incl prior48/worker1352/physical suspend/isolation. Production metadata/cursor overhead unmeasured; partial84/184frame suffixes not acoustic cut/audibility. No live Island/otherbackend/engine-loss/short-tail/phase claim. QuickFAILED2/10 (87.5s), core21/22 unchangedwake; new C04 hallucination/open attribution retained. [Proof](../../../Tests/Reports/agent-overhaul-closure/voice-playback-projection-prerequisite/resume/positive-owner-verification/verification.md). | 9d9a01f |
| P3-06b | ↳ Reducer owns the state (ownership switch) | 3 | P3-03b, P3-04b, P3-05, P3-08, P3-09 | todo | 2026-10-08 | **Reconciled 2026-10-08 (state unchanged `todo`):** `Sources/NextNotes/Agent/Duplex/VoiceSession.swift` line 6 still reads `enum Mode { case shadow }` (checked 2026-10-08; audit: [status audit](../../../Tests/Reports/agent-overhaul-progress/2026-10-08-status-audit.md)). The reducer owns no live state; the ownership switch needs the ledger/output/frontend/approvals/Island routes and divergence gates first. **Historical:** no evidence recorded. |  |
| P3-07 | Compute: capacity lanes, a second llama context, LocalToolLoopWorker | 3 | see subtasks | todo | | |  |
| P3-07a | ↳ Capacity lanes + measured FM overlap flag | 3 | P0-06, P3-02 | todo | | |  |
| P3-07b | ↳ Second llama context | 3 | P3-07a, P0-18 | todo | | |  |
| P3-07c | ↳ `LocalToolLoopWorker` | 3 | P3-07b, P3-05, P3-09 | todo | | |  |
| P3-07d | ↳ (Optional) fallback conversational lane | 3 | P3-05 | todo | | |  |
| P3-08 | C8 spoken approvals | 3 | P3-02, P3-03a, P3-04a, P3-05, P3-06a, P1-07 | in progress | 2026-10-04 | Corrected original337 qualifies91 actual failures across505 scheduler checks/221 added approval checks, controls green. Introduced338/339 nil proposal-tool producer is confirmed and repaired inside SAME transaction. Observed343 identifies retained heard scope plus fixture quiet-clock fault; corrected original344 fails only C05, fixed345 delivery505 passes. Measured346 then SAME COMMON347 qualify the original deterministic amendment and separate actual partial-model effect barrier. Delivery505/duplex/C06 pass347; offered model53 now passes355 (total delivery558), including actual fourth-schema offer and exact captured authority. Inherited5ms remains failed. No full approval acceptance. Strict validator/exact pending payload preserved. Historical fixture/packaging failures retained. Full physical/account/consequential/live/dependency gates open. | |
| P3-09 | C10 island state owned by VoiceSession (workers never drive it) | 3 | P3-06a, P3-03a; lands after P3-03b | in progress | 2026-10-04 | Parallel normal ownership source implementation and actual isolated Island conductor in preparation. Eager shared Island MeetingStore/Notes/Diarization constructor confinement must qualify before native mount. Diagnostic-only receipt projection is not live ownership acceptance. Native/physical/displayed and dependencies remain open. | |
| P3-10 | A "not addressed to me" frontend route, and a session close after consecutive side-talk turns (H2 V15) | 3 | P3-05, P3-06a, P0-23 | in progress | 2026-10-04 | Source candidate reviewed through existing streamed decision, exact user-row retraction, current Capture tick and retained worker/output owners. Actual350 RED24/52 →352 SAME52/whole routing PASS;81/84/context20 controls preserved. Exact captured history/review/memory and capture close/held-worker delivery consumers exercised. Related352 complete28/29 PASS, only inherited5ms failed; all52 controls retained355. Live harness235a is WITHHELD pending actual DictionaryStore/grounding constructor read isolation, not ready native. Packaging351 INVALID retained; prescribed live10side/10positive×3, physical/native and full dependencies remain open. | |
| P3-11 | A typed message during a running turn is a turn, not a cancel (OpenMuse O2) | 3 | P3-03b, P3-05, P1-20 | in progress | 2026-10-04 | Actual AgentView/Manager/work/tool extraction376 RED15/29 →377 PASS31, qualified jointly with same-input permission race382 RED1/40 →383 PASS40. Old proposal/grant absent, original read retained, revised effect once;29/30 integration flags PASS, unchanged5ms failed. Full displayed/installed typed flow, declared dependency/core/owner/model gates and symbolic CancelReason API remain open. | |
| P4-01 | Cached "Now" block in every prompt — **runs in Phase 1** (owner, 2026-09-27) | 4→1 | P1-01, P0-18 | done | 2026-09-27 | `NOW_BLOCK_OK`; the planner's `Today is …` and the runner's `Now:` lines are gone, replaced by one block as section 7. Voice first pass 4,229 → 4,362 chars of its 4,500 budget (94% → 97%), no ceiling raised. `PERSONA_OK`, `SCHEDULE_OK`, `ROUTINE_AUTHORITY_OK`, `TOOLLOOP_OK`, `TOOLLOOP_PRODUCTION_OK`, `GROUNDING_OK`, `make test` 30/30 | `c4fa973` |
| P4-02 | Router sees the previous exchange; a deflection re-routes once | 4 | P2-02, P4-03 | in progress | 2026-10-03 | Actual211 RED8/20 →212 PASS20 through composer/route/SDK boundary; eight related flags PASS. Bounded labelled prior exchange and outgoing claim guard only. Native classifier/deflection re-route, prerequisite/full phase and latency gates remain open. [Evidence](../../../Tests/Reports/agent-overhaul-closure/route-context-and-scheduled-reader-production/verification.md). | — |
| P4-03 | Prompt rewrite: one identity, typed depth, act on the likely reading, persona scoping, fuller voice card | 4 | P1-01, P1-02, P1-03, P4-01 | todo | | |  |
| P4-04 | Pre-meeting brief on `meetingStarting` | 4 | P4-01, P0-11, P4-12 (P3-04 for the spoken path) | in progress | 2026-10-01 | Bounded reader-aware prerequisite P4-04a complete under owner §4.1; installed app12 functionality green, fixed quick FAILED 3/10 retained below 9/10. Full hosted trigger/card/notification/consent/delivery chain remains open. | |
| P4-04a | ↳ Event-ready brief and actual reader window through existing notes/Agent consumers (P4-04 steps 1/1b) | 4 | P4-01, P0-11, P4-12 | done (bounded; aggregate gate open) | 2026-10-01 | Original red9/current green (brief 2491 → 7894 chars, fetch 10 → 40, file 5 → 20); public tool 20 unchanged. Installed notes/context/resume/isolation 21 files/31 defaults pass; actual NotesService.generate/prompt/save/capture and Agent context method only. Complete quick 3/10 Gemma fallback 129.9s, identical app5 case verdicts; direct incomplete 4 cases retained cause unknown. No quality/model promotion or hosted chain/latency claim; see meeting-brief report. | |
| P4-05 | Post-meeting "what you owe" wrap and a suggestion lane | 4 | P4-04 | todo | | |  |
| P4-06 | Morning digest offer, owed-item nudges, next-step offer as a pending intent | 4 | P4-04, P4-05, P4-02, P1-02, P1-03 | todo | 2026-10-08 | **Reconciled 2026-10-08 (state unchanged `todo`):** related but not this task: a moment-titled Catch-up routine now replaces digest/podcast in the scheduler ([5c7df10](../../../Tests/Reports/agent-overhaul-progress/catch-up-core/verification.md); text first, single-voice file render, reads-only, original 8 failures -> pass, decoded 19.36 s AAC sample). It has no offer path, no owed-item nudges and no next-step pending intent, so P4-06's exit is untouched. Live creation, spoken catch-me-up and typed closing offers remain open. **Historical:** no evidence recorded. |  |
| P4-07 | Explicit statements saved to memory | 4 | P4-07a, P0-11 | in progress | 2026-10-03 | Actual staged155 RED13/70 → fixed156 PASS70, identical typed/committed-voice conductor and fixture; only two producer hooks differ across1061 compiler inputs. Six related flags PASS including existing Remember/duplex/isolation21files32defaults. Review precision unchanged15/16; background short-fact skips remain P4-11. Current quick3/10 FAILED; native caption, prescribed live statement/full/CORE/latency open. [Proof](../../../Tests/Reports/agent-overhaul-closure/explicit-memory-production/verification.md). | — |
| P4-07a | ↳ Provenance survives the write: `MemoryEntry` keeps a `MemoryProvenanceRecord`, never `userText`/`untrustedText`; hand-written `init(from:)`; version 3. **Prerequisite for P4-07 and P4-11** (folded 2026-09-25, REVIEW-LOG §6.3) | 4 | P0-11 | done (bounded; aggregate gates open) | 2026-10-01 | Original producer red16 → current green; installed MEMORY_OK with exact 115-byte legacy snapshot, scripted review precision .938/recall 1.0 (one inherited false positive), PERSONA_OK, isolation 21 files/31 defaults. CORE21/22 wake and fixed Gemma quick 3/10 remain open; see memory proof. | `8888474` |
| P4-08 | Longer history; fitted `KnowledgeAsker` for typed library questions | 4 | P4-01, P1-18 | in progress | 2026-10-03 | Advertised fitting children verified; actual typed original161 RED18/59 → fixed162 PASS59 with same receipt-qualified fixture, two producer files across1062 compiler inputs and seven related flags PASS. Same provider/graph scope, actual stream/saved citation rows, fallback/action negatives/caps. Reader budgets now qualified163 RED17/51 →164 PASS51; eight producer files across1062 inputs, nine latest related flags PASS. Initial three-read deadline failure retained; original/recheck pass without changes, timing attribution open. Actual assembler duplicate producer190 RED2/5→191 PASS5 plus complete flag and ASK/schedule/UI/isolation PASS; saved page retains each named file once. Provider reader171 RED4/31→172 PASS31 also verified; genuine loaded capacity remains open. Scheduled advertised-reader forwarding now211 RED1/8 →212 PASS8 through actual runner/model/recorder and full schedule flag, with eight related flags PASS; loaded native capacity, chips/full gates remain open; quick162 repeat times out before scoring at unchanged300s; prior1563/10 remains latest scored failure. [Reader proof](../../../Tests/Reports/agent-overhaul-closure/reader-budget-production/verification.md). [Typed proof](../../../Tests/Reports/agent-overhaul-closure/typed-knowledge-production/verification.md). | — |
| P4-08a | ↳ Fit actual KnowledgeAsker input to its advertised provider window | 4 | P4-01/P1-18 existing callers; bounded §4.1 | done (bounded) | 2026-10-02 | Original94 ASK RED2 → identical fixed95 PASS15/all11 focused flags;4096 envelope4974→3057,32768 retains20,512 no stream. Synchronous actual wrapper contract, real SQLite/progress/citations/index/owner invariance;1043Source/fullbundle stable. Required quick FAILED4/10;CORE21/22 known wake only; tool-awareness/answers PASS. Loaded runtime/floor/headers/typed/memory/Assembler/physical gates open. [Proof](../../../Tests/Reports/agent-overhaul-closure/next-implementation-review/p4-08-knowledge-fitting/verification.md). | f9f9acc |
| P4-08b | ↳ Preserve feasible3 and fit actual metadata envelopes | 4 | P4-08a existing provider/SQLite/stream seam | done (bounded) | 2026-10-02 | Original97 RED6 → same98/99 PASS20+prior15;1900 admits3/cost1712,1500 retains1/cost1329,4096 longtitles6/cost3916. Retrieved events/citations exactly match sent rows; no extra retrieval/model round. Final31 checks pass on recheck; quick3/10 +CORE21/22 open, initial metrics anomaly retained. Loadedcapacity/typed/memory/Assembler/parent gates open. [Proof](../../../Tests/Reports/agent-overhaul-closure/next-implementation-review/p4-08-knowledge-fitting/boundary-preparation/boundary-verification.md). | 9663d27 |
| P4-09 | Capable model for typed and background work, with its own consent | 4 | P0-01, P0-03, P0-14, P1-01, P0-17, P0-19, P0-20 | todo | | |  |
| P4-10 | Post-meeting review fits a small window and reads the asks, not only the tail (H3 #3, #4, #16; H1 #25) | 4 | P0-20b, P1-10a | in progress | 2026-10-03 | Actual184 RED9/31→185 PASS31: same captured reader/system reaches real fitter and model request; earlier candidate/action-item asks remain in bounded chronological speech. Five related flags PASS; selected-role agent-answers UNAVAILABLE at existing Keychain lookup, no answer accepted. Transcript-owned evidence actual187 RED11/89→189 PASS89 and five related flags PASS; intermediate188 literal-punctuation live-consumer failure retained and repaired at matcher. Compact prompt/catalogue/rounds, persisted failures and actual loaded/Apple/six-owner/full gates remain open. [Proof](../../../Tests/Reports/agent-overhaul-closure/meeting-review-fit-production/verification.md). |  |
| P4-11 | Memory review stops echoing saved facts and keeps short ones (H3 #7–9, #25; H1 #23) | 4 | P4-07a, P4-07, P0-11 | in progress | 2026-10-03 | Actual staged167 RED33/71 →168 PASS71 through reviewer/guarded writer and dictation harvest; complete memory-review flag passes, explicit70 preserved. Five related flags PASS. Settings diagnostic original178 crash→179 successful exit verified after two owned-window ARC contract repairs; earlier168/167/164 failures retained. Native interaction and owner quit crash remain open. Actual169 RED28/63→170 PASS63 through same reviewer/writer/state reader; reader71/explicit70 preserved. Lifetime totals survive recent-row trim; native UI appearance unverified. Provider capacity actual173 RED7/28→174 PASS28, preserving prior204 memory checks; genuinely loaded factory remains open. Introduced past/modal environment gap now has actual180 RED30/60→181 PASS60: ten incorrect writes removed, six durable controls retained, prior232 checks preserved and five related flags PASS. Preference-subject original193 RED32/102 is retained. First repair194 passes102 but introduces existing declaration failures; unchanged declaration117 original195 RED4 plus5 prior failures→196 PASS117/prior292. Recall199→200 restores unchanged scripted recall25/27 but exposes2 existing MEMORY merge/correction regressions. Qualified original204 RED4/189→205 PASS189/prior292 fixes both through the actual guarded writer/store; six related flags PASS, including unchanged MemorySelfTest and isolation21files32defaults. Only MemoryGuard differs across1,076 compiler inputs; scripted precision19/19/recall25/27 preserved. Invalid203 quoted seed expectation retained/corrected identically before both. This bounded preference-subject repair is verified; live/loaded/native/full parent gates remain open. Genuine loaded/real-model/native/full acceptance remains open. [Current proof](../../../Tests/Reports/agent-overhaul-closure/memory-preference-subject-production/verification.md). Actual review quality/native/full gates open. [Proof](../../../Tests/Reports/agent-overhaul-closure/memory-review-production/reader-harvest/verification.md). |  |
| P4-12 | Routines run on Apple Intelligence and may be as long as their template needs (H3 #10, #11, #23) | 4 | none (soft: P1-05) | done (bounded; aggregate gate open) | 2026-10-01 | Actual copied producers: original 10/16 failed, current 16/16 passed. Installed routine/schedule/digest/podcast and UI checks pass; CORE21/22 retains wake failure; dictionary30 pass. Fixed quick Gemma local fallback3/10 stays below 9/10; owner digest/native Apple inference remains unverified. | `8f7ecdf` |
| P4-13 | Consent-shaped defaults for proactive meeting features (H3 #12–15) | 4 | P1-16, P4-10, P4-04 | todo | | |  |
| P5-01 | `FrontendResponder` seam for cloud frontends | 5 | P3-03, P3-04, P3-05, P3-06, P3-08, P4-01, P4-09 | todo | | |  |
| P5-02 | OpenAI Realtime frontend (opt-in, Keychain key, consent) | 5 | P5-01, P5-04 | todo | | |  |
| P5-03 | Gemini Live frontend (gated on NON_BLOCKING support) | 5 | P5-02, P5-04 | todo | | |  |
| P5-04 | `--selftest-realtime-cloud` loopback fixture server | 5 | P5-01 | todo | | | |
| P6-01 | Step 0: tests describe production — pin today's restart behaviour in a green test that goes red at P6-04a (**6A**) | 6 | P0-07, P0-11 | done | 2026-10-01 | Installed TASK_DURABILITY_OK: 5 cases, TASKS_OK, isolation 18 files/23 defaults unchanged; actual restart-map mutation fails 4 assertions and path-binding mutation refuses before seeding. Core **16/18**: standing wake failure plus real dictation silent-hold tap/empty failure; separate dictation recheck fails capture timing. Those remain unresolved, not passes. No recovery/host or phase-green claim. [Report](../../../Tests/Reports/durable-tasks/2026-10-01-p6-01-restart-baseline.md). | ff40a93 |
| P6-02 | Durable store plus artifact/evidence producer/UI integration (**parent**) | 6 | P6-01; complete after P6-02a/P6-02b | in progress | 2026-10-01 | Split into canonical existing-manager mirror and original step-7 producer/UI child; parent stays open until both pass. No recovery, read switch or IM-16 unblock. | |
| P6-02a | ↳ Canonical existing-manager SQLite mirror, typed durability defaults, failure visibility and SQLite/WAL/SHM isolation (**6A**) | 6 | P6-01 | done | 2026-10-01 | 670bc35: installed18cases/tasks/isolation21files23defaults green; mapper/mirror/fail-fast mutations red. JSON read authority retained; core16/18 wake/dictation unresolved. Parent/P6-02b/recovery/IM-16 remain open. | 670bc35 |
| P6-02b | ↳ Artifact/evidence metadata at verified producers and actual approval/result UI (original P6-02 step 7) | 6 | P6-02a; producer/UI ownership, serial ToolStepRunner after P3-02 freeze | in progress | 2026-10-02 | Bounded artifact child P6-02b-1 original107 RED23 -> fixed108 worker1487,23functional flags PASS. Verified mail producer/request child P6-02b-2 passes paired proof; parent remains OPEN for actual Based on/result/privacy UI consumers, native interaction, normal nested dispatch/restoration and complete effect/authority acceptance. Quick4/10 and CORE20/22 OPEN, retained computer takeover refusal plus unchanged standalone pass. [Actual proof](../../../Tests/Reports/agent-overhaul-closure/next-implementation-review/p6-02b-artifact-production/full-pipeline/native-verification/verification.md). | |
| P6-02b-1 | ↳ Verified document/file descriptors through canonical task history and named result actions | 6 | P6-02a; exact producer/card lease; §4.1 bounded proof | done (bounded) | 2026-10-02 | Original107 RED23 only feature failures -> identical fixed108 PASS1487; exact7producer delta/full1049Source invariant; COMMON edited-approval/CLI/receipt/SQL/export/card135 cases.23focused flags green including authority58/reader40/isolation21files32defaults. Schema4 legacy collisions neutral, older3reader refusal explicit; no owner migration. Quick4/10 (112.1s), CORE20/22 wake +computer takeover; standalonecomputerPASS without Source changes does not erase core failure. Physical UI/clipboard/VO, mail/Based on, migration latency/recovery/retry/IM16/parent gates OPEN. [Proof](../../../Tests/Reports/agent-overhaul-closure/next-implementation-review/p6-02b-artifact-production/full-pipeline/native-verification/verification.md). | 2725895 |
| P6-02b-2 | ↳ Verified mail metadata through frozen next-action intent, approval request and receipt | 6 | P6-02b-1; producer/request lease; §4.1 | done (bounded) | 2026-10-02 | Original111 exactRED36/new metadata only -> fixed112 worker1714;12 actual modes preserve controls/effects. Exact3producer delta/full1051pins;32functionalPASS, stale portability failure retained; separate fixture-only114 passes31rows/30retained/1refused +worker1714/isolation. Quick4/10, CORE21/22 unchangedwake OPEN. Public Based on/rendering, normal nested dispatch/restoration, unloaded restart, broader effects/recovery/retry/IM16/parent gates OPEN. [Proof](../../../Tests/Reports/agent-overhaul-closure/next-implementation-review/p6-02b-verified-mail-review/native-verification/verification.md). | f4d2a16 |
| P6-02b-3 | ↳ Cached exact saved-source projection into actual approval/result card callers | 6 | P6-02b-2; owned UI/cached receipt seams; §4.1 | in progress (bounded functional proof; installed verification held) | 2026-10-02 | Staged original127 exactRED28/no controls -> identical fixed128 actual1908PASS;1050inputs/only2getter bodies. COMMON194 preserves edited request/receipt/primary/fresh readers/privacy/exact-binding and denied/held/released/partial controls. Both32PNG captures explicitlyUNAVAILABLE; visible/nativeUI remainsOPEN. Earlier12633supportedflagsPASS +retained invalid typo; quick1264/10 andCORE12621/22 wakeOPEN. Unloadedrestart/normalnesteddispatch/completeauthority/latency/recovery/retry/IM16/wholeparentP6-02bOPEN. |  |
| P6-03 | Journal actual manager transitions in the same SQLite snapshot transaction; receipt-aware event retention | 6 | committed, verified P6-02a storage | done | 2026-10-01 | 1c68d3e: original actual boundaries red13, installed37cases/tasks/activity/tool-loop/review/isolation21files23defaults green; atomicity/age mutations red. JSON authority remains; ACP/scheduled contexts and real attempt/lease/receipt/recovery open. Core16/18 wake+computer focus fail; dictation passes this run, earlier intermittent failures unresolved. | 1c68d3e |
| P6-04a | `.recovering` (AgentTaskStatus), pure planner, strict one-time import/read authority and held launch decisions (**6A**) | 6 | P6-03 | in progress | 2026-10-08 (previous: 2026-10-01) | **Reconciled 2026-10-08 (state unchanged):** TaskStore export reconciliation now keeps task history readable across a volume remount ([811f3bb](../../../Tests/Reports/live-freeze-2026-10-06/task-remount/verification.md)): original 3 failures (two remount refusals, one wrong-volume acceptance) -> fixed 63 authority cases pass; wrong inode/volume still refused without changing bytes. Isolated store/consumer proof only: no owner-store migration, no remote-task hosting (IM-16) and no owner rows were seeded. **Historical (2026-10-01, state `in progress`):** P6-04a-1 committed6f50e07: original20/stale-copy13/old-baseline5 red; isolated53 green (34 pure+19 actual store/manager), including init persistence failures. Installed actual delegate9 red→recovery56 green; durability37 and all12 related flags green, isolation21files23defaults. Actual producer mutations4/6/9 and pure terminal3 fail; related sync28 green. P6-04a-2 committed5de382a, installed: authority54/recovery56/durability37, all13 targeted flags green, isolation21files23defaults. SQL primary/tagged export; original producer3 red, admission/import mutations red1 each; native omission nonsensitive. Four actual process exits/readers pass. Latest CORE15/18 fails dictation capture/continuity, wake and computer focus. Older-binary rollback/live repair/large-history latency open. Input/permission card restoration plan-only until real routing verified. No auto execution or IM-16 host. | |
| P6-04a-1 | ↳ Held restart, strict legacy reads and truthful rejected delegation | 6 | P6-03 | done | 2026-10-01 | Installed recovery56, durability37 and all12 related flags green; original/mutations red. Superseded storage authority by P6-04a-2. | 6f50e07 |
| P6-04a-2 | ↳ Strict SQL authority migration and primary-commit dispatch admission | 6 | P6-04a-1 | done | 2026-10-01 | Authority54/recovery56/durability37, all13 targeted flags green, isolation21files23defaults. Original red3, admission/import mutations red1 each; native omission nonsensitive. Four process exits/readers pass. CORE15/18 red; older-binary rollback/live repair/large-history latency open. Parent remains in progress. | 5de382a |
| P6-04a-3 | ↳ Actual pending-card restoration and visible retained-history failure/repair routing | 6 | P6-04a-2; coordinate external app UI owner before shared consumer edits | in progress | 2026-10-01 | Installed restoration82 (app20), authority58/historyrepair58 (app19); original filesystem.read/path input red2/scope4 then fixed42, latest48 includes continuation ownership checks. Staged223 restoration188 adds query46 and directory60 through actual Manager/SQL/receipt/backing. Directory222 RED3/26→223 PASS60;12 related flags PASS, worker retains inherited100ms latencyFAIL1. Rendered cards/picker, broader worker/repair and receipt/recovery contracts remain open; no automatic replay. | |
| P6-04b | Voice work joins recovery: `TaskState.recovering`, recovered delivery through `OutputScheduler` (**6B**, new 2026-09-27) | 6 | P6-04a, P3-03b, P3-06b, P3-04a | todo | | | |
| P6-05 | Heartbeat and stale detection, per runtime class (**6A**); `waitingOnPerson` has no window | 6 | P6-04a | in progress | 2026-10-03 | Actual227 RED19→229 worker2366/13 related PASS preserves eligible ACP periodic progress and shared cadence. Local/scheduled admission238 RED21→239 worker2524/17 related PASS. Task-scoped scheduled ownership241 RED34/154→242 same154 PASS both runs; unchanged integrated repeat2678 and19 related checks PASS, including voice-scheduling/reader40. Same per-run Task/attempt/context, cancellation-save-refusal fencing and independent B completion are verified. First242 small-history1830.389ms FAIL1/callback1777ms remains UNATTRIBUTED; passing repeat44.657/57.725ms does not close general latency. Historical237 history118.263ms and other timing failures retained. Scheduled quarter-window beats/model progress, normal wallclock/current complete observations, health/recovery/retry/IM-16 remain open. [Current proof](../../../Tests/Reports/agent-overhaul-closure/p6-restoration-monitor-storage-production/scheduled-run-owner-production/verification.md). | |
| P6-05a | ↳ Bounded admitted typed-local worker/tool activity fields | 6 | existing P6-06b transaction/fence; §4.1 isolated producer prerequisite | done (bounded) | 2026-10-02 | Original app21 FAILED20 assertions; identical fixture app22 OK93 and all14 focused flags pass, isolation21files32defaults unchanged. Same SQL transaction and exact memory/SQL rollback, no extra save/event/await/timer. Stale/classification/retry/receipt joins/IM-16 remain open. | 776d1de |
| P6-05b | ↳ Preserve exact attempt fencing across runtime classes; native browser admission metadata | 6 | actual P6-06b/P6-05a/P6-06c seams; bounded §4.1 | done | 2026-10-02 | Original installed app33 RED122, prior169 green. Unchanged original extension passes app34 worker354; final app35 worker362 adds damaged/bare waiting backend negatives. All14 related flags pass; exact primary/receipt refusal before preparation, actual browser descriptor metadata stops before authorization/backing. MCP/stale windows/liveness/retry/IM-16 open. [Evidence](../../../Tests/Reports/agent-overhaul-closure/runtime-class-fence/README.md). | eb97f3e |
| P6-05c | ↳ Bind the existing typed-local worker handle to its admitted attempt for observation | 6 | actual P6-05b/P6-06b seams; bounded §4.1 | done | 2026-10-02 | Original37 nil scaffold/unbound producer RED7 feature assertions, prior362 green; unchanged fixture passes app38 worker399 +14 related flags. Actual entry/held-backing snapshot, read-only invariance, completion/cancel/restart/rejected-start flows. Same map/Task, no health/authoritative SQL/stale/retry/IM-16 authority. [Evidence](../../../Tests/Reports/agent-overhaul-closure/worker-binding/README.md). | 952383f |
| P6-05d | ↳ Retain the last existing primary worker check in the bound handle | 6 | actual P6-05c/primary-validity seams; bounded §4.1 | done | 2026-10-02 | Original42 nil getter RED15 missing-feature; unchanged61 extension passes app43 worker491 +14 related flags. Same read/predicate/file binding, actual cached diagnostic, query-free LAST getter, contention/damage/restart/successor. No current authority/health/receipt-completeness/stale/retry/IM-16 claim. [Evidence](../../../Tests/Reports/agent-overhaul-closure/authoritative-observation/README.md). | e522aa9 |
| P6-05e | ↳ Observe the last exact live tool-backing boundary in the existing bound worker | 6 | actual P6-05c/P6-06c tool-start/completion seams; bounded §4.1 | done | 2026-10-02 | Actual original50 nil-observer RED15 missing-feature; same fixture fixed51 worker629 (prior531+98), all19 flags green:14 related +worker +privacy40 +ACP/MCP/confirmation. Same handle binds exact receipt/tool/captured attempt; admitted entry and return/threw before completion-save rejection. No added query/save/store/await/timer/schema/state change. LAST metadata supplies no complete active/effect/health/retry/IM-16 proof. [Evidence](../../../Tests/Reports/agent-overhaul-closure/tool-backing-observation/README.md). | 40618f1 |
| P6-05f | ↳ Settle shared ACP/MCP requests on peer stdout closure | 6 | existing shared JSONRPC stdio producer; bounded §4.1 | done | 2026-10-02 | Original48 actual ACP RED1 → same revised fixture fixed49 ACP/MCP/confirmation/worker531/isolation PASS; source/bundle stable and no recognized remaining owned peers. Existing map/locks, no timeout change/retry/polling/store. EOF is not process health/effect/recovery/IM-16 authority. [Evidence](../../../Tests/Reports/agent-overhaul-closure/stale-observation-frontier/acp-review/protocol-verification.md). | 3b07f4c |
| P6-05g | ↳ Admit ACP callbacks only for the exact established session | 6 | existing Session callbacks; bounded §4.1 | done (bounded) | 2026-10-02 | Original52 RED20/68 → identical fixed53 origin68 plus five serial scheduling controls; related MCP/confirmation/worker629/privacy40/production/isolation PASS. Guard before reply/activity/permission attribution; no prompt-active gate or new wait. Current-client/nested durable authority/recovery/IM-16 remain open. [Evidence](../../../Tests/Reports/agent-overhaul-closure/stale-observation-frontier/acp-invocation-review/origin-admission/verification.md). | a6daafc |
| P6-05h | ↳ Preserve cached historical receipt load quality and last existing write comparison | 6 | existing receipt reader/writer/runtime failure seam; bounded §4.1 | done (bounded) | 2026-10-02 | Original71 nil-scaffold RED13 metadata assertions; unchanged fixed72 worker794 (prior764 plus30), all20 focused flags PASS. Actual original read/changed-source refusal controls unchanged; cached diagnostics, no new I/O/timer/store/queue/query/save. Sources/binary/bundle invariant; no health/full-history/stale/recovery/retry/IM-16 claim. [Evidence](../../../Tests/Reports/agent-overhaul-closure/stale-observation-frontier/receipt-source-quality-review/verification.md). | 15aaa5a |
| P6-05i | ↳ Sample current exact owned ACP Process/transport through existing worker | 6 | actual Session/stdio producer +same bound handle seam; bounded §4.1 | done (bounded) | 2026-10-02 | Actual original84 nil-producer RED10 → identical fixed85 worker1132/all20 focused flags PASS;1034-source/binary/fullbundle invariant. SAME exact child PID/open/pending1 and held-primary plus live-child verified; repeated reads nonmutating, competing/late attach refused, standalone EOF/alive→actual exit→nil. No registry/store/query/save/timer/new foreground await. Not health, complete tool/effect/current receipt coverage, stale verdict, recovery/retry/IM-16 or parent promotion. [Proof](../../../Tests/Reports/agent-overhaul-closure/stale-observation-frontier/current-runtime-observation-review/verification.md). | 272c7b0 |
| P6-05j | ↳ Observe live task-owned Gate approvals including queued requests | 6 | same current bound worker +existing Gate entries; bounded §4.1 | done (bounded) | 2026-10-02 | Actual original86 false-scaffold RED6 → identical fixed87 worker1161/all20 focused flags PASS;1035-source/binary/fullbundle invariant. Real visible/queued waits with forty-day admitted progress; queries nonmutating, refused decision retains both, genuine decision promotes B, Gate withdrawal clears then release returns nil. ONLY Gate projection body differs; restored-only query unchanged. Approval-only taskID exclusion, no stale/agewindow/attempt/retry authority/newstore/timer/query/save/state/model/foreground await. [Proof](../../../Tests/Reports/agent-overhaul-closure/stale-observation-frontier/human-wait-observation-review/verification.md). | d7fee76 |
| P6-05k | ↳ Integrate current primary/receipt-bound heartbeat age diagnostics | 6 | same primary/Gate/ACP/receipt seams +pure windows; bounded §4.1 | done (bounded) | 2026-10-02 | Corrected original90 missing-feature RED149 → identical fixed91 worker1352/all20 focused flags PASS;1040Source/fullbundle invariant. Parallel pure policy/current fingerprint producers reach actual Manager consumer. Actual old-age candidates, visible/queued approval exclusion and fresh-generation primary unavailable despite child live; source changes retain fired evidence/no successful delivery. Unknown session/tool/effect coverage preserved; no automatic monitor/beat/state/retry/model/foreground await/newstore. Initial88/89 invalid fixture assumptions retained. Parent P6-05/P6-06/recovery/IM-16 and aggregate gates open. [Proof](../../../Tests/Reports/agent-overhaul-closure/stale-observation-frontier/heartbeat-integration-review/verification.md). | 83d4853 |
| P6-06 | Retry policy keyed on `AgentRisk`, and the receipt rule: a recovered task never auto-fires a consequential action | 6 | P6-05, P0-20a, P1-21 | in progress |  |  |  |
| P6-06a | ↳ Bounded P1-21 receipt-persistence and actual pre-fire disk admission prerequisite | 6 | existing P1-21 receipt producer; isolated store seam; §4.1 bounded entry | done | 2026-10-01 | Actual original harness red10/production writer red7; fixed store26 and installed runtime5/review/restoration70/authority58/durability37/isolation21files31defaults pass. Quick13 FAILED3/10 (bar9,189.3s), same ten case classes as app12; bounded closure under §4.1. No process-crash, fsync, attempts/leases, task receipt join, retry or IM-16 proof. | |
| P6-06b | ↳ Bounded typed-local attempt ownership and primary tool-fact admission prerequisite | 6 | existing local worker/store/receipt seams; isolated production regression; §4.1 bounded entry | done | 2026-10-01 | Original app17 failed10 assertions across27 unchanged checks; installed app19 worker61 and all12 related checks pass, including durability37/recovery56/authority58/restoration70/repair58/isolation21files31defaults. Attempt/process metadata and captured callbacks use existing primary transaction; rejected tool-start produces zero backing, completion rejection retains runtime receipt without success delivery. Latest quick13 remains FAILED3/10, not an app19 model verdict. App20 adds restoration82: actual approval/input prior+1/currentPID exactly once before backend/backing; old contexts refuse successor facts/tokens. No heartbeat, retry, liveness, replacement-worker lifecycle, task receipt join or IM-16 authority. | 1ab186e |
| P6-06c | ↳ Bind actual typed-local action receipts to admitted attempt/process and primary tool-start transaction | 6 | actual P6-06a/P6-06b/P6-05a seams; bounded §4.1 | done | 2026-10-02 | Original installed app26 RED9; app29 worker156 and14 related checks PASS, including exact fresh receipt/SQL before backing and permission/input successor links. Independent review complete; parent recovery/liveness/retry/IM-16 remain open. [Evidence](../../../Tests/Reports/agent-overhaul-closure/receipt-attempt-join/README.md). | 4e07d36 |
| P6-06d | ↳ Refuse task success when the actual terminal action receipt cannot commit | 6 | P6-06a/P6-06c actual runtime/store seams; bounded §4.1 | done | 2026-10-02 | Original installed app30 RED3; byte-identical fixture passes app31 worker169 +14 related checks. One actual read, honest action-ran/result-not-saved failure, no successful task delivery, retained fired evidence/exact link, no fresh-manager replay. Parent consequential reconciliation/recovery/liveness/retry/IM-16 open. [Evidence](../../../Tests/Reports/agent-overhaul-closure/receipt-terminal-commit/README.md). |37acf9a |
| P6-06e | ↳ Preserve action receipt history changed after writer initialization | 6 | P6-06d actual writer/runtime seams; bounded §4.1 | done | 2026-10-02 | Original installed app40 RED5; unchanged original13 +18 additive boundaries pass app41 worker430 +14 related flags. Actual writer retains exact new unreadable bytes/fired memory/link, honest failed task, one read/no replay. No concurrent CAS/reconciliation/recovery/retry/IM-16 claim. [Evidence](../../../Tests/Reports/agent-overhaul-closure/receipt-source-admission/README.md). | 904af46 |
| P6-06f | ↳ Prevent denied harness task-history reads at the existing producer | 6 | existing isolated task-store/Manager seam; bounded §4.1 | done | 2026-10-02 | Original installed46 RED10/40 actual Store/fresh-Manager canaries via dedicated pre-App entry; unchanged40 pass fixed47 and worker531. Denied reader returns empty before owner JSON/SQL; admitted temp import/authority/export controls preserved. Default nil guard precedes owner path/lazy mirror. All14 related flags PASS; mutation guards are unchanged-byte proof only. No owner decode/seed in original proof, no new store/query/await/timer/schema. Full-pane model/default/prewarm isolation, liveness/recovery/retry/IM-16 and quality gates remain open. [Evidence](../../../Tests/Reports/agent-overhaul-closure/task-harness-read-isolation/README.md). | e6e5790 |
| P6-06g | ↳ Positive normal typed ACP attempt admission before backend entry | 6 | existing bound worker/primary seams; bounded §4.1 | done (bounded) | 2026-10-02 | Original57 RED14, fixed58 worker656; integrated60 worker678/all20 PASS. Compatibility and session health stay open; bounded receipt startup/completion joins are now verified by P6-06j/P6-06k, without outcome reconciliation. | 1675da8 |
| P6-06h | ↳ Refuse an exact retained context after its worker handle is released | 6 | P6-06g integrated worker baseline; bounded §4.1 | done (bounded) | 2026-10-02 | Original59 RED5 actual same-context second read; fixed60 worker678/all20 PASS, one backing and zero absent-handle SQL. Atomic effect gap/direct record metadata stay open. | 1675da8 |
| P6-06i | ↳ Refuse successful ACP delivery when unverified terminal receipt cannot be saved | 6 | P6-06g actual attempt/receipt injection; bounded §4.1 | done (bounded) | 2026-10-02 | Original61 RED3; identical actual fixture fixed62 worker701/all20 PASS. Retained fired evidence, failed task/exact error, no result delivery/replay; accepted output unchanged. No reconciliation/recovery/IM-16 claim. | 3b2acbb |
| P6-06j | ↳ Admit exact normal typed ACP receipt join before process startup | 6 | P6-06g/P6-06i actual attempt/receipt seams; bounded §4.1 | done (bounded) | 2026-10-02 | Authoritative original65 RED9; unchanged fixed66 worker731/all20 PASS, one exact primary UUID at actual peer startup; start rejection no launch/link/success.63/64 fixture type error retained, both versions repeated. Bounded completion is now verified by P6-06k; combined completion failures, actor-gap/effect/recovery/IM-16 remain open. | e946ecd |
| P6-06k | ↳ Require admitted ACP completion before task result delivery | 6 | P6-06j startup join/P6-06i terminal receipt; bounded §4.1 | done (bounded) | 2026-10-02 | Original67 RED4; identical actual fixture fixed68 worker764/all20 PASS. Completion rejection fails task/no success delivery while actual returned receipt survives; accepted control unchanged. Actor/effect/recovery/IM-16 open. | 404725b |
| P6-06l | ↳ Encode actual ACP permission outcome and preserve cancellation | 6 | Existing ACP Gate/Session seams; bounded §4.1 protocol prerequisite | done (bounded) | 2026-10-02 | Original69 RED3; unchanged fixed70 permission22/origin68/worker764/all20 PASS. One archived six-mode origin wire expectation upgrade; same inputs/other guards. Nested durable/client/effect/recovery/IM-16 open. | 4f37916 |
| P6-06m | ↳ Fence nested ACP permission entry against exact live/current primary attempt | 6 | P6-06j/k/l admitted normal typed ACP; bounded §4.1 | done (bounded) | 2026-10-02 | Corrected original74 RED1 held wire allow → identical fixed75 worker849/all20 PASS; source1030/binary/bundle invariant. Real fresh manager hold without cancellation; valid offered allow retained, held offered reject/no Gate relay. Same policy hop + fail-fast primary probe; no store/queue/timer/model pass. Initial73 timestamp control defect retained; both authoritative runs use same codec-corrected fixture. Gate admission/post-Gate/client epochs/recovery/retry/IM-16 open. [Evidence](../../../Tests/Reports/agent-overhaul-closure/stale-observation-frontier/acp-nested-attempt-review/verification.md). | a8422ec |
| P6-06n | ↳ Admit bound live Gate requests/decisions and refuse released permission facts | 6 | P6-06m +current actual worker/Gate; bounded §4.1 | done (bounded) | 2026-10-02 | Corrected original78 RED21 → same fixed79 worker1017/all20 PASS;1031-source/binary/bundle invariant. Actual6modes/SQL triggers, same exact-card retry, cancellation false, released worker facts refused. Historical76/77 readiness prerequisite corrected before both via real unchanged-ID confirmation; broader identifier-review bug stays open. Existing2 Gate primary writes now boundACP; no separate save/store/await/timer/model pass. Post-Gate/client/standing grant/edited payload/recovery/retry/IM-16 and parent gates open. [Proof](../../../Tests/Reports/agent-overhaul-closure/stale-observation-frontier/acp-gate-admission-review/verification.md). | 7756ebf |
| P6-06o | ↳ Revalidate current primary after actual saved Gate approval | 6 | P6-06n fixed Gate/current-worker prerequisite; bounded §4.1 | done (bounded) | 2026-10-02 | Actual original80 RED1 → same fixed81 worker1074/all20 PASS;1032-source/binary/bundle invariant. Actual approved-before-held event retained, held wire nowreject/no cancellation substitution, current controlunchanged. ONE existing fail-fast primary probe in sameGate suspension, no newawait/save/store/timer/model pass. Broker allow/standing grants/actor handoff/client/close/payload/recovery/retry/IM-16 and parent gates open. [Proof](../../../Tests/Reports/agent-overhaul-closure/stale-observation-frontier/acp-post-gate-review/verification.md). | c3997f6 |
| P6-06p | ↳ Keep internal ACP routing ID out of editable operation arguments | 6 | P6-06n/o fixed admission +actual metadata producer; bounded §4.1 | done (bounded) | 2026-10-02 | Actual original82 RED4 → same fixed83 worker1092/all20 PASS;1033-source/binary/bundle invariant. ONE Session line removes duplicate editable taskID; exactoperation/typedrequest/context unchanged. Standaloneactual18 +common n160/o57 amendments preserveauthority and strengthenoperation checks; boundreviews fields1/problems0. No inspector scrub/exemption/newquery/save/await/store/timer/model pass. Generic grounding/physicalUI/standinggrant/client/close/after-probe/payload/recovery/retry/IM-16/parentgates open. [Proof](../../../Tests/Reports/agent-overhaul-closure/stale-observation-frontier/acp-review-metadata-review/verification.md). | 416fd44 |
| P6-06q | ↳ Select only offered one-time ACP permission options; preserve malformed/cancelled/lasting-only outcomes | 6 | Existing P6-06l…p Session/Gate contracts; exact isolated constructor prerequisite; bounded §4.1 | done (bounded staged proof) | 2026-10-03 | Original153 RED40/151 → fixed154 PASS151 unchanged real Session/Gate/owned-peer cases. Only Session differs across1060 compiler inputs;10 launch refusals and19 related flags pass, worker1908/isolation21files32defaults. Native-tools FAILED1 also reproduced original153; aggregate gates retained. Selected CORE1/1; no install, parent/retry/IM-16 promotion. Guard hashing/default snapshots are owner reads. [Proof](../../../Tests/Reports/agent-overhaul-closure/stale-observation-frontier/acp-offered-option-review/verification.md). | — |
| P6-07 | Usage is a projection: `UsageRecord.taskID`, no second log, cost stays `nil` | 6 | P6-06, P0-20e, **AO P0-20c and DM D-01b** (same two files; `roadmap/BUILD-ORDER.md` — `taskID` is additive, so it lands *after* both, never alongside) | in progress | 2026-10-03 | Actual175 RED8/36→176 PASS36, full USAGE_LOG27groups PASS. Same real Manager/local reads and owned accepted/failed ACP peer; only3producer delta. Existing writer/load/report exact UUID and unknown-cost controls preserved; All six related flags PASS (durability37/worker1908/ACP/MCP/confirmation/isolation). Read-only report follow-up actual182 RED5/20→183 PASS20 retains rotated history/metadata and leaves missing sources absent; usage-log/Activity/worker1908/isolation all PASS. Shared-file dependencies/live task detail/full historical attribution remain open. No second ledger. | |
| P6-09 | Revisions survive a restart; a revision is a work-lifetime event and never invalidates output | 6 | P6-03, P3-06b, P1-07 | in progress | 2026-10-04 | Typed journal actual388 RED5/64 →389 SAME64 PASS through existing Manager conditional transaction, journal INSERT refusal/explicit continuation and fresh restart hold/completed output readers. Exact one producer compiler delta;29/30 integrated flagsPASS, inherited5ms fails. Voice running corrections and permission amendments/retries now also bounded-verified: original392 RED4/138 → unchanged394 repeat SAME138 PASS/API40; exact Manager/Store compiler delta and29/30 related flags. Signing393 and first394 disk-full status case retained invalid/incomplete. Question-answer journal403 RED8/163 →404 SAME163 PASS now retains exact answers before continuation. Same-worker activity411 RED4/69 →412 SAME69 PASS refreshes heartbeat/lastProgress in the existing transaction while preserving attempt/start binding; related41212/14 PASS, receipt5ms and ACP history138.97375ms>100 fail. Recovered revision re-read/replay, actual new-attempt admission and dependencies remain open. [Voice journal proof](../../../Tests/Reports/agent-overhaul-closure/p3-task-bridge-production/manager-voice-worker-ownership-production/p6-09-voice394-qualified-results.json). | |
| P6-08 | Observability: the journal, Activity job rows through the projector, and `--jobs-report` as a diagnostic | 6 | P6-09, P3-04a, P1-10b | in progress | 2026-10-03 | Actual177 API-only scaffold RED6/23→178 PASS23 and full Activity flag. Three real temporary task flows yield3rows/14ordered saved events through same marked ledger/journal; health/effects unknown, damaged-source/no-replay/privacy controls pass. Only projection body differs; relateddurability37/authority58/worker1908/isolation all PASS. Actual saved Timeline original201 RED6/37→202 PASS37 through real SavedJobs/HistoryRow bodies, same3tasks14events; only projector body differs. Related durability37/authority58/worker1908/UI strings/isolation PASS. Offscreen bodies are not pixel/focus/VO/native interaction proof. [Timeline proof](../../../Tests/Reports/agent-overhaul-closure/p6-08-activity-ui-frontier/verification.md). Early noncreating route prepared; ordinary owner-positive CLI remains unrun. Full Activity/revisions/output/streamed-finish dependencies open. | |
| P6-10 | Parallel worker graphs: fan-out, join, cancellation propagation, depth 1 | 6 | P6-06, P6-09, P3-07a, P1-03 | todo | | | |

The "Depends on" column mirrors each task's own **Depends on** line. If a phase file adds
lettered subtasks, add a row per subtask directly under its parent.

## Phase gates

| Phase | `make test` | `make acceptance TIER=core` vs baseline | Exit flags (final lines) | Report | Date | Commit |
|---|---|---|---|---|---|---|
| 0 | `30 tests in 2 suites passed` (re-run on a quiet machine after the dictation workstream committed) | `CORE 14/15 PASS` (only known-red wake-live; baseline was 12/14) | 16/19 green; `agent-answers` and `model-unopenable` are timing budgets red under load 24–58 (green on 09-24); `toolloop-production` is the known P1-03/P1-06 red; `voice-pipeline` carries P0-10's blocked EOU race. Headline: `AGENT_ANSWERS_OK: 3/3 answered by Qwen3-4B-Instruct-2507` | `Tests/Reports/AGENT-OVERHAUL-P0-2026-09-25.md` | 2026-09-25 | `db9a84f` |
| 1 | | | `--selftest-toolloop-live` ≥ 25/30 in two consecutive **full** runs (not `--quick`), 0 `LEAK`, 0 `ERROR`; Apple FM full run with 0 `FABRICATED`; **and (2026-09-27) every owner-log case O01–O09 PASS in both runs (`TOOLLOOP_LIVE_OWNER`, P1-27), `--selftest-now-block` OK (P4-01 moved in)** (plus the flag list in the Phase 1 file's exit gate) | **Historical (2026-09-27) reading, superseded: see the Reconciled 2026-10-08 block at the top (gate still not met on the latest retained pair, 25/30 and 23/30). NOT MET** — 17/30 twice (5/30 baseline); LEAK=0 and ERROR=0 met, >=25/30 not; refusal=2 not verified; run-to-run variance is +-4, larger than any cluster closed. **Owner set: 6/10 on the 2026-09-27 40-case run (390.6 s), reds O01/O04/O08, and the set has a ±1 band of its own** — O02 passed on one run of the same binary and failed on the next | | |
| 2 | | | `--selftest-voice-latency` median warm end of speech → first audio ≤ 0.9 s over 5 runs and main-actor stall ≤ 100 ms; `--selftest-voice-barge` duck ≤ 200 ms; `--selftest-tts-pipeline` gap ≤ 50 ms; `--selftest-voice-duck`, `--selftest-smart-turn`; `--selftest-voice-pipeline` with a speculation hit (Phase 2 file §0.7) | `Tests/Reports/AGENT-OVERHAUL-P2-____.md` | | |
| 3 | | | `--selftest-voice-duplex-work`, `--selftest-voice-session-reducer`, `--selftest-voice-overlap` | `Tests/Reports/AGENT-OVERHAUL-P3-____.md` | | |
| 4 | | | `--selftest-now-block`, `--selftest-proactive`; `--selftest-toolloop-live` ≥ 25/30 with N01, N02, R01 PASS and `TOOLLOOP_LIVE_EXTRA 5/5` | `Tests/Reports/AGENT-OVERHAUL-P4-____.md` | | |
| 5 | | | `--selftest-realtime-cloud` | `Tests/Reports/AGENT-OVERHAUL-P5-____.md` | | |
| 6 | | | `--selftest-task-durability`, `--selftest-task-recovery`, `--selftest-task-retry` (all CORE at Phase 6 exit), `--selftest-task-graph`, `--selftest-activity` (job rows), `--selftest-usage-log` (task cases), `--selftest-tasks`, `--selftest-meeting-resume` | `Tests/Reports/AGENT-OVERHAUL-P6-____.md` | | |

## BLOCKED notes

Use this format for each note, newest first:

```
### <ID> — blocked <YYYY-MM-DD>
Tried: …
Failing line: `<NAME>_FAILED: …` (output saved at ~/Library/Caches/NextNotesBuild/agent-overhaul/<ID>-….txt)
Missing: <model | grant | network | owner decision | other agent's uncommitted work>
Next step when unblocked: …
```

### P0-14b — blocked 2026-09-24 (cause moved)
Tried: P0-14's full workflow, then P0-04 (which fixed the first cause).
Failing line: `AGENT_ANSWERS_FAILED: What's on my calendar today?: the reply said “took
too long”` (output `~/Library/Caches/NextNotesBuild/agent-overhaul/P0-14b-attempt2.txt`,
reproduced twice). The three turns now print:
`AGENT_ANSWER 1: appLLM · Qwen3-4B-Instruct-2507 · model-answer · …`,
`AGENT_ANSWER 2: … · model-answer · …`, and
`AGENT_ANSWER 3: … · model-tools · On Friday, September 25, 2026: - 10:00 AM — Haitch
content … - 2:00 PM — VIDEO | AI st…` — the tool call ran and returned the real calendar.
Missing: the warm-answer budget. **The first cause (the opening `<tool_call>` dropped by
`piece(special: false)`) is fixed by P0-04 `b56a37d`.** The remainder is the 18 s
model-warm limit on a three-round local tool turn; P0-18's prefix reuse (no re-prefill of
1.2–2.3 k tokens per round) is the Phase 0 fix and is now unblocked (P0-04, P0-06 and P0-14
are done). If it still overruns after P0-18, it is P1-06's per-round budget, exactly as
P0-05's risk note says.
Next step when unblocked: after P0-18 is green, re-run
`Scripts/run-selftest.sh --selftest-agent-answers` and expect
`AGENT_ANSWERS_OK: 3/3 answered by <model>`.

### P0-14b — blocked 2026-09-24 (superseded cause)
Tried: P0-14's full workflow, including the P0-14b harness. `--selftest-agent-answers` runs the
three typed turns through `RealtimeAgent.handle(_:source: .text)` against the real Agent-role
model.
Failing line: `AGENT_ANSWERS_FAILED: What's on my calendar today?: the reply said “invalid tool
request”` (output `~/Library/Caches/NextNotesBuild/agent-overhaul/P0-14-verify-answers.txt`;
red run `P0-14-red-agent-answers.txt`). Turns 1 and 2 print
`AGENT_ANSWER n: appLLM · Qwen3-4B-Instruct-2507 · model-answer · …`.
Missing: P0-04. Measured on the raw planner completion: `len=180 open=false close=true` — the
model emits `<tool_call>{…}</tool_call>` but the opening delimiter is dropped because the
streaming path renders pieces with `special: false`. Without the opening tag
`AgentToolCallParser` sees only the closing one and the turn ends as an invalid tool request.
P0-04's `renderSpecial` (and, for the general case, P1-04's tolerant parser) is the fix; note
P0-04's steps must also cover `provider.stream(…)`, which is the typed planner path.
Next step when unblocked: after P0-04 is green, re-run
`Scripts/run-selftest.sh --selftest-agent-answers` and expect
`AGENT_ANSWERS_OK: 3/3 answered by <model>`.

### P0-10 — blocked 2026-09-24
Tried: implemented all three P0-10 steps (immediate `tick(force: false)` from `noteModelEOU`,
`lastEndpointTrigger`, `tickInFlight`); ran P0-10's Verify three times.
Failing line: run 3 `VOICE_PIPELINE_FAILED` / `VOICE_PIPELINE_WRONG: file speech did not end
from local EOU model: vad`; no `VOICE_ENDPOINT_TRIGGER` printed. Saved at
`~/Library/Caches/NextNotesBuild/agent-overhaul/P0-10-run3.txt`. Runs 1–2 printed
`VOICE_ENDPOINT_TRIGGER=eou` with `VOICE_MODEL_EOU_TO_ENDPOINT` 0.0039 s / 0.0040 s
(`P0-10-run1.txt`, `P0-10-run2.txt`); run 2 additionally shows the pre-existing
`expected one committed spoken turn, got 2` (a late EOU committing after the VAD fallback
already committed).
Missing: a warm EOU model. The measured `VOICE_MODEL_EOU=sinceVoiceEnd` is 4.3–10.8 s in the
failing runs against a 2.5 s VAD fallback, i.e. the streaming EOU head confirms after the
silence fallback has already committed — exactly the condition P2-07 (resident EOU, prewarmed
at launch or arm) and P2-04 (Smart Turn, lower debounce/fallbacks) exist to remove. Phase 2's
own baseline table records "EOU model prepare per session 1.67–3.04 s warm; 9.1–12.7 s cold".
Next step when unblocked: re-run P0-10's Verify after P2-07 lands and confirm 3/3 `eou`; the
late-EOU double commit (run 2) then needs its own decision — it is outside P0-10's three steps,
which keep every existing gate in force.

## Decisions and deviations

- **2026-09-27 P1-27: three points where the task text could not hold as written**, all corrected
  rather than forced, none of them a lowered bar. (1) O05's `anyOf` named `computer.open_app` and its
  check wanted "gmail" in the app's name, so a run that opened Google Chrome **and** navigated to
  mail.google.com was graded `WRONG_TOOL`; the URL tools carry the requirement and the app is `allowed`.
  (2) The task's "one full run" needed a run whose selection can hold only unscored cases, which the
  old bar arithmetic would have failed; a selection with no scored case now returns true **and says so
  in words** rather than printing `0/0`. (3) `Expectation.answerOnly` is per case, so O06 needed one new
  `ExtraRule` (`noToolFromSecondTurn`) for "the first turn may look, the second must not". The timeout
  budget and `Scripts/acceptance.sh` were resized from 30 cases to 40 (9,300 s → 12,300 s) because a full
  run now executes the owner's ten too.
- **2026-09-27 — APPROVED by the owner: P4-01 (the "Now" block) runs in Phase 1.** Its id is unchanged.
  It lands before P2-01's baseline, `--selftest-now-block` is on the Phase 1 exit list, and P1-27's
  O07 is its live check. Reason: the live log audit (J L11, L13) — a 2023 agenda for "today" and a
  wrong clock spoken aloud. This is the second named exception to "Phase order is strict".
- **2026-09-27 — APPROVED by the owner: Phase 6 is split into 6A and 6B; 6A starts after the Phase 1
  gate** (`07-PHASE-6-DURABLE-JOBS.md` §0). 6A = P6-01, P6-02, P6-03, P6-04a (was P6-04), P6-05,
  P6-06, P6-07 and makes `AgentTaskManager`'s tasks durable in parallel with Phases 2–3; this is the
  one named exception to "Phase order is strict" (00-README §4). 6B = P6-04b (new), P6-09, P6-08,
  P6-10, after Phase 3. Rule while both are open: P6-04a and P3-03a/b never edit
  `AgentTaskManager.swift` at the same time — record here which landed first.

Pre-filled by the roadmap editor on 2026-09-23 (G integration; see REVIEW-LOG §4):
- 2026-09-23 roadmap: G N2 (llama prefix reuse) is placed in Phase 0 as P0-18, not in Phase 2. The reasons: Phase 1's eval re-prefills on every pass, three tasks already assume reuse, and the change does not touch the voice pipeline.
- 2026-09-23 roadmap: G N3 (MiniCPM5 control tokens) is folded into P0-04 (`minicpm5` family row, explicit BOS token, case 5). It is not a new task.
- 2026-09-23 roadmap: live-eval per-task gates use `--quick` (10 fixed cases). Full 30-case runs are for the baseline, the phase gates, P1-05's default flip and P4-03.

Record each one on a single line: date, task, what you changed relative to the task text, and
why. For example, "2026-09-24 P0-08: T15 is already unreachable for plain requests; pinned
the remaining `.localModel` case instead."

- 2026-09-24 shared-tree assistance: while Wave 7 was blocked, the meetings workstream's
  untracked `Meetings/MeetingBacklogSelfTest.swift` (M-07) could not compile — it was parked
  to a copy outside the repo and restored, then given two mechanical completions with the
  owner's standing authorisation for build-blocking one-liners: `import FluidAudio` (the
  source of `ASRResult`/`TokenTiming`) and `nonisolated` on `fakeCallSeconds` (a
  `@MainActor` constant used in a nonisolated closure). Both are named here so the M-07
  author can fold or replace them.

### OPEN FINDING (not a roadmap task) — 5 app crashes on 2026-09-26, 14:52–15:18

**Signature, identical in all five.** `EXC_BAD_ACCESS` in
`swift_getObjectType` <- `swift_task_isMainExecutorImpl` <-
`swift_task_isCurrentExecutorWithFlagsImpl`, i.e. a **`SerialExecutorRef` holding garbage** — the
faulting addresses are tiny integers (`0x1e`, `0x220`, `0x7c8`), and `x0`/`x16`/`x17` hold that same
tiny value, so a small offset is being called as a function pointer.

**Trigger is always UI hit-testing on the main thread**, reached three different ways:
`-[_NSTrackingAreaAKManager setCursorForMouseLocation:]` during the display cycle (14:52),
`TooltipBridge.responder(at:)` on `mouseEntered` (14:57, 15:18), and `MenuBarClientCore` (15:12).
All five were launched from a Terminal coalition with a 2 s–4 min lifetime.

**What is ruled out, by evidence rather than assertion:**
- **No NextNotes frame is on any stack** past `NextNotesApp.$main()` / `main`. The crashing code is
  SwiftUI's `NSViewResponder.platformCurrentEvent`, AppKit's tracking-area manager, and
  `MenuBarClientCore`.
- **Install churn is ruled out**: `Scripts/install-bundle.sh:12` runs `pkill -x` *before* the bundle
  is swapped, so no live process is ever standing on a replaced binary. A SIGTERM also cannot produce
  an `EXC_BAD_ACCESS` report.
- **A clean launch is healthy**: `open -n -a "Next Notes"` at 16:25 survived 45 s with the file index
  (9,193 rows), `gws`, `Qwen3-4B-Instruct-2507 loaded on GPU` and `Parakeet: ready in 37.0s` all
  logged normally, and no new report.
- Every report carries the same `HIE: M_` thread parked in
  `SOME_OTHER_THREAD_SWALLOWED_AT_LEAST_ONE_EXCEPTION`, which is the thread AGENTS.md already records
  for the launch-time HIServices abort. These are SIGSEGV in the run loop, not that SIGABRT, so the
  documented "agent launch false alarm" does **not** cover them and they are not being written off.

**Not yet attributable.** Nothing in today's Phase 1 work touched a view, the island or the status
item; the work was Agent/, Support/ModelRoles and self-tests. What the trigger does point at is our
own UI surface in that path: 58 `.help(...)` tooltips across `UI/`, the `NSStatusItem` in
`NextNotesApp.swift`, and the event monitors in `UI/Island/IslandPanel.swift` (the island finds the
pointer with monitors because a collapsed island ignores mouse events).

**CORRELATION FOUND, 2026-09-26 16:40 — these are harness launches, not a user session.**
- `P1-11-quick-green.txt` was written at **14:52:32**; the first crashing process launched at
  **14:52:33** — one second later.
- `P1-08-baseline-quick.txt` was written at **15:08:36**; the third crashed process launched at
  **15:08:40**.
- A third window (14:54) holds `.gates.jCCVuM`, the dictation workstream's gates launcher, so a
  *second* harness was also starting processes then.
The crashing processes are `Scripts/run-selftest.sh` foreground launches: the self-test prints its
marker and calls `NSApp.terminate(nil)`, and the fault lands on the way out with the window tree,
the status item and the tracking areas still live on the main thread. That is the same family as
the launch-time HIServices abort AGENTS.md already records, and the `HIE` thread present in all
five reports is consistent with it — but this one is a SIGSEGV in the run loop, so it is **not**
covered by that entry and is recorded as a real defect in the harness's teardown path, not as noise.

The owner does not recall using the app in that window, which matches: a person's own launch is
healthy (`open -n -a "Next Notes"` at 16:25 survived 45 s with every subsystem logging normally).

**Honest limit of the correlation:** two of the five match to the second, a third lands on another
workstream's launcher, and 14:57 / 15:12 / 15:18 have no file evidence — they fall in the same
25-minute window with the same signature. So: strongly indicated, not proven for all five.

**Where the repair belongs, when someone takes it:** the teardown path in `Scripts/run-selftest.sh`
/ the self-test terminate, not the app's turn logic. No NextNotes frame is on any stack. Nothing in
today's Phase 1 work touched a view, the island or the status item. Nothing is being changed on the
strength of a guess.

**The Apple FM leg of the gate IS met.** Full 30-case run, `--model apple`, 264.6 s:
`pass=5 error=0 timeout=0 leak=0 refusal=4 wrong_tool=1 **fabricated=0** missed_tool=17 ungrounded=3`.
`FABRICATED=0` and `ERROR=0` and `LEAK=0` are all satisfied, which is P1-11's guard holding on a full
run. The score is 5/30 and `missed_tool` is 17 — which is exactly P1-05's measured finding: Apple's
model narrates instead of calling when asked in prose (**2/10 prompt vs 6/10 native**). With
`agentNativeToolCalling` still off, the prompt convention is what this leg exercises, so **this leg is
the argument for the flag** rather than a verdict against the Agent. It also cannot be run with
`--allow-cloud` off, so no cloud number exists.

### Phase 1 EXIT GATE — **NOT MET**, and the reason is the most important result in the phase

Gate requirement (`STATUS` row 1): `--selftest-toolloop-live` **>= 25/30 in two consecutive full
runs**, 0 `LEAK`, 0 `ERROR`, and an Apple FM full run with 0 `FABRICATED`.

**Measured, two consecutive full runs, agent role (Qwen3-4B-Instruct-2507), quiet machine:**

| run | score | elapsed | classes |
|---|---|---|---|
| baseline (P1-01) | 5/30 | 629.2 s | — |
| **gate run 1** | **17/30** | 225.5 s | `pass=17 error=0 timeout=0 leak=0 refusal=0 wrong_tool=1 fabricated=0 missed_tool=6 ungrounded=6` |
| **gate run 2** | **17/30** | 286.3 s | identical |

**5/30 -> 17/30, and every safety class is zero**: `error`, `timeout`, `leak`, `refusal` and
`fabricated` were all 0 on both runs. 29 of 30 verdicts were identical between the two runs.
**`LEAK=0` and `ERROR=0` are met. `>= 25/30` is not.**

After `1c6e9e8` closed four more cases with model-free pins (M01, M03, M05, C04, N02, N04), the best
quiet run of that binary was **20/30** and the final run **16/30**.

**THE FINDING THAT OUTRANKS THE SCORE: two quiet full runs of the *identical binary* differ by four
cases in each direction — 20/30 and 16/30.** Earlier runs of the same tree scored 19/30 and 13/30, the
latter at load 33. So **run-to-run variance on this 4B model is +-4, which is larger than any cluster
that was closed.** A single 30-case run cannot resolve an 8-case difference, and cannot confirm the 7
that were fixed. **No honest claim about this gate is available from single runs**, and the phase
cannot be declared green on this evidence.

**Safety, unresolved: `refusal` moved 0 -> 2** on `.reminders` and `.memory` classes that were not
modified. The one universal change that demonstrably moved cases into `REFUSAL` — stating the
answering model on every turn — was found and reverted by gating it to a turn that asks. The residual
2 is inside the +-4 band and **cannot honestly be called 0**, so the gate's "0 refusals" condition is
recorded as **not verified**, not as passed.

**A case defect found and deliberately NOT edited (owner's call):** `N01`'s
`mustNotMention: ["i'm {assistant}"]` is defeated by typography, so the verdict measures the model's
apostrophe rather than whether it introduced itself in the first person. Byte dumps: the baseline reply
`"I’m Will, your assistant."` contains U+2019 and **passes**; a run producing `"I'm Will."` with U+0027
is graded `UNGROUNDED`. The case's intent is sound and the fix is to match both apostrophes — but that
is a case edit, so it is recorded here rather than done silently.

**Also recorded:** C04 is a two-tool case (`allOf: search_email, get_agenda`) in a suite scored on a
model that calls a second tool unreliably, so its verdict depends on a *second* decision rather than
one capability. And `--selftest-toolloop-live` cannot be resolved on this model by more runs; closing
the remaining Y/K/F cluster needs either a model this eval can drive deterministically, or an
explicit decision about whether the eval is a capability measurement or a coin-flip measurement at
30 cases on a 4B model. **That decision is the owner's, and it is Phase 1's real exit blocker.**

**What did land, with model-free proof rather than a score:** the invented-mail-filter bug
(`1c6e9e8`), the two false statements to a person (the same commit), and the three exit blockers
(`fd4e6ae`). A post-hoc false-answer guard was built, measured to replace two *correct* answers, and
**deleted** rather than shipped, with its rationale left in the file as a comment.

### OPEN FINDING (not a roadmap task) — a FOURTH crash signature, 2026-09-27 05:08:24

**Not one of the two documented entries, and not written off.** `NextNotes-2026-09-27-050852.ips`:
`SIGABRT`, `Abort trap: 6`, the first SIGABRT here that is not the launch-time HIServices abort.

**Signature, read off the report's own stack.** Thread 4, dispatch queue
`com.apple.coreml.DefaultAsyncPredictionQueue`:
`-[MPSGraphTensorData initWithMTLBuffer:shape:strides:interleaves:dataType:]` →
`MTLReportFailure` → `__assert_rtn` → `abort`, under `Espresso` (the ANE) and `CoreML`. That is a
**Metal framework assertion on a CoreML prediction**, not a null dereference.

**Zero NextNotes frames on the crashing thread.** Every frame is libsystem, Metal,
MetalPerformanceShadersGraph, Espresso, CoreML or libdispatch. The only thread carrying a NextNotes
frame is thread 6, and it is *blocked*, not faulting: `NotesModelRuntime.decodePromptWhileScheduled`
(`NotesModelRuntime.swift:848`) sitting in `ggml_metal_synchronize` — a llama.cpp prefill running
concurrently with the CoreML prediction that aborted. The main thread is idle in the AppKit run loop.

**Distinct from the three already on disk, compared frame by frame:**

| report | exception | queue | top app-visible frame |
|---|---|---|---|
| `2026-09-26-151816`, `-154549` (and three more) | SIGSEGV | main thread | `swift_getObjectType` ← `SerialExecutorRef` |
| `2026-09-27-030508` | SIGSEGV | cooperative | llama.cpp `token_to_piece` / `unicode_utf8_to_byte` |
| **`2026-09-27-050852`** | **SIGABRT** | **`com.apple.coreml.DefaultAsyncPredictionQueue`** | **none — `MPSGraphTensorData`** |

**What happened around it, in evidence.** The process was 16 s old, launched by
`nohup Scripts/run-selftest.sh --selftest-toolloop-live` from a Terminal coalition with an exited
parent. The log's last lines are PocketTTS CoreML models loading
(`cond_prefill`, `flowlm_stepv2`, `flow_decoder_fused`, `mimi_decoder_fused`) and a `PocketTtsSession`
chunk being processed, immediately before the abort. The eval printed `TOOLLOOP_LIVE_MODEL` and
**zero** `TOOLLOOP_LIVE_CASE` lines — it died before the first case, during model and TTS warm-up.

**Not attributable to P4-01 or P1-27, by what they touch.** Both are text and eval-data changes: a
prompt section and a list of cases. Neither reads CoreML, Metal, a model file, or the audio path, and
this report has no frame from either. Recorded as a fact, not a defence — the honest limit is that a
report with no app frame cannot name a cause, only exclude these two.

**Why it matters, and the one thing it is evidence for.** P1-28's target 3 already says *"A load
already in progress is cancelled before `terminate`, which removes the crash path"*, written after
`2026-09-27-030508` (a llama load during `NSApp.terminate`). This report is a second instance of the
same family on the **CoreML/ANE** side rather than the llama side, and it happened during warm-up
rather than teardown — so P1-28's cancellation should be measured for **CoreML predictions**, not only
for the llama load, or it will close one half of a two-half problem. **Nothing has been changed on the
strength of a guess**; the next action is a re-run, which is both the P4-01 measurement P4-01 needs
and the reproducibility test this finding needs.

### P1-26 — done, `62f70f6` (2026-09-27). A green test over a feature that deleted 21 sessions

"Clear conversation" deleted **every** conversation ever indexed and asked for no confirmation. The
button was a trash can labelled "Clear conversation", which a person reads as "tidy this chat". The
audit found deleted chunks for about 21 sessions still in `knowledge.sqlite-wal`'s free pages, and the
Agent "doesn't remember past conversations" while knowledge search finds none of them.

**Nothing failed and nothing logged, because the behaviour was correct.** The design comment in
`KnowledgeIndexer` says the whole index goes, and `--selftest-index` pinned it. That is the finding
worth more than the fix: **a green test over a feature that quietly deletes history is worse than a
red one, because it certifies the deletion as intended.** So the case is inverted, and the inversion
is the proof rather than a formality.

| `--selftest-index` | before | after |
|---|---|---|
| "New conversation" | asserted `chunks == 0` | **every earlier session's passages survive**, and the session it ended is indexed |
| "Forget all conversations" | — | removes them |

`INDEX_OK` (the inverted case and the deleting path), `SEARCH_OK`, `MEMORY_OK`, `MEMORY_REVIEW_OK`,
`UI_STRINGS_OK`, `PERSONA_OK`, `TOOLLOOP_PRODUCTION_OK`, `make test` 30/30.

Two methods, and the split is the point. `startNewConversation()` ends the session the way an idle
one does — so it **is** indexed and reviewed — and writes an *empty store* rather than removing the
file, because "absent" and "empty" are different states to anything reading it.
`forgetAllConversations()` is the only path that reaches `onConversationCleared`. A **new
`ReviewReason` case** rather than a boolean, so "deliberately deleted" and "the person started a new
chat" cannot be confused later by reading a flag. The button is a verb, not an adjective: "New
conversation", a plus rather than a bin, and its help says *"Past conversations stay in search."*
Deleting moved beside the index it removes from, behind the one confirmation AGENTS.md allows for an
irreversible action.

**The self-test call sites were renamed rather than left on a stale name.** Twelve of them called
`clear()` and all of them meant "wipe everything so the next case starts clean", which is the deleting
path — calling it that is more honest than calling it `clear()`, and a stale name that still
compiles is how the next person re-introduces the button.

**The chunks already lost cannot be restored.** That is recorded here as a fact about this Mac rather
than as a failure of the task, exactly as the roadmap's "Done when" asks.

### P1-25 — done, `361078c` (2026-09-27). An id has to have been *said*, and "said" is not a shape

`append_doc` was approved on 20 September with `document_id` = **"You open Google Chrome"** — a
fragment of the person's own sentence — and Google rejected it. The only Workspace write ever approved
on this Mac.

**The reason the meeting side's grounding did not catch it is the interesting part, and it is why
this is a different check rather than a stricter one.** Grounding asks "is this value supported by a
source", and for an id there is no shape to ask about: `"Marcus"` is not an email address, and
grounding is the wrong question for it. A document id is not a word at all. So the question here is not
*what is this* but **whether anyone ever said it** — which is a containment test, not a similarity
one.

`FunctionCallGrounding.normalize` and the containment test are **reused**, not reimplemented. Its
*paraphrase* branch — one significant borrowed word is enough — is right for an address in a sentence
and wrong for an id, so the id check deliberately uses the strict branch: the value must appear in the
normalized source **whole**.

Three things the four cases found, and **two of them were mine**:

1. **The guard checked nothing.** It paired the parameter *names* with a placeholder value, so the
   empty-value check skipped every parameter and the rule looked green while enforcing nothing. The
   case found it — by *crashing*, because it indexed `[0]` on an empty array. That is the worst way
   to find a real bug, and the case now reads a named binding and returns early.
2. **A pre-existing budget case broke, and the fixture was the wrong one, not the guard.**
   `largestResultSeen` asked `read_doc` for `document_id` `"1"` on a turn about a pricing sheet —
   an id nothing said or showed — so the guard refused it and the case measured 0 characters. A real
   turn cannot have an id nobody ever saw, so the fixture now **searches and then reads the document
   the search named**, which also puts I2 through the real loop rather than only through the pure
   function.
3. **"Every id parameter is marked" caught my own omission** of `reply_email.message_id`. That
   assertion is the one worth keeping: a tool added next month with an unmarked `document_id` would
   otherwise be silently unguarded.

**I4 is the case that keeps the guard honest in the other direction.** A search prints numbered rows
and the tool says to read one by its number, so `"2"` is grounded by having been *printed* and not
by resembling an id — a shape test would refuse it and break every "read the second one" turn. So the
guard must not refuse grounded ids, and that is pinned as carefully as I1.

The store is a **bounded, conversation-scoped window** on `AgentSession` — 12 results, 8,000
characters, the **raw** result rather than the capped one, since an id near the end of a long listing
must not be un-grounded for having been cut. No new log; P1-29 is what makes these ids joinable
across the logs on disk.

### ENVIRONMENT — the disk filled up mid-task (2026-09-27 ~16:00) and it is not mine to fix

`make build` began failing with `internal error in Code Signing subsystem`, then
`volume "Macintosh HD" is out of space`. **`df -h /` read 317 MiB free on a 228 GB disk, 98% full.**
The code-signing message is a *symptom*; a full volume is the cause, and it is worth knowing that a
signature failure can present as a toolchain fault rather than as a disk fault.

This also **re-frames two earlier measurements**, and both had been read as code results:

- `--selftest-function-calls` exceeding 15 minutes was disk pressure, not a slow test. Re-run after
  reclaiming space it completes; it is nonetheless **red for its own reason** and not P1-25's:
  `FunctionCallSelfTest` calls `propose` on the engines directly and never touches
  `ToolStepRunner` or `AgentToolExecutor`, so a guard living in `ToolStepRunner.execute` cannot be in
  that path. Its failures are *"needle did not propose send_email for 'no address anywhere' (nothing
  at all)"* and *"localModel … the answer did not fit the required shape"* — a 3B-class engine
  declining, and a local model producing unusable output. Pre-existing, INTEGRATION tier, not on the
  Phase 1 exit list, and **not chased** on the strength of a guess.
- The CoreML/MPSGraph abort recorded above happened in the same window, and **a full disk is a
  plausible contributor to a Metal assertion on a CoreML prediction**. That is a hypothesis, not a
  finding: the report has no app frame and the machine had 317 MiB free at the time. It should be
  re-run with room on the disk before either finding is treated as closed.

**What I removed:** five `NextNotesBuild/install-*` staging directories, 628 MB, all from today and
yesterday. They are copies of the app bundle that every `make install` regenerates, the installed app
at `/Applications/Next Notes.app` is untouched, and `install-bundle.sh` already reaps ones older than
a day. **What I did not touch, and what is actually large:** `scratch` 1.9 GB, `test-scratch` 1.8 GB,
`scratch-p106` 1.6 GB, `competitors` 1.3 GB, `dictation-meetings` 445 MB — none of them mine, and
freeing real space is the owner's call. 757 MiB was free after the reclaim, and a build consumes
some of that, so **this session cannot continue indefinitely without the disk being freed.**

### P1-24 — done, `9f49a37` (2026-09-27). The read runs; one reply is still too thin

**The app reads; the model is not asked to.** That is the entire difference from the re-plan note
P1-14 measured and deleted, and the comment still standing in `RealtimeAgent+ToolLoop.swift` says
why that one lost: *"the model answers prose after a re-plan whatever the note says."* A read is not
a note. It runs through `ToolStepRunner` — the same executor, the same risk classes, the same
approval policy as any other call — and the always-affordable final round answers from the result.

| `--only O01,O02,O04,O09` | before | after |
|---|---|---|
| O04 "can you look at my inbox" | MISSED_TOOL | **PASS** — `search_email(query=in:inbox)`, the guard's own default read |
| O02 "check my emails" | MISSED_TOOL | **PASS** — `search_email`, reply lists the mail |
| O09 "summarise mail + tomorrow" | PASS | PASS |
| O01 the invented mailbox | MISSED_TOOL | **UNGROUNDED** |
| | **1/4** | **3/4** |

**O01 is not fixed, and the reason is located rather than guessed.** The read now runs — two
`search_email` calls, one of them the guard's own — and the model then answers the *provenance*
question with a reassurance: *"Yes, that's from your emails — all the messages listed came directly
from your inbox."* It names no sender. A person who asks "is this coming from my emails?" after a
summary wants the mail, not the assurance. That is what the final round is **asked for**, so it is a
prose problem and **P4-03 owns it**; no amount of matcher work changes it, and the guard must not try
to, because a rule that forced a sender into a reply would be inventing content.

**The fourth condition took three measured replies and one real bug to get right.** The first
`isQuestion` looked at the last character of the reply — and the owner's fabricated mailbox ends
`- Cyril <cyril@example.com> — Dinner tomorrow?`, so it read a three-line invention as a question and
**exempted the exact turn the guard exists for**. A list item is not a sentence; only one of them can
be a question. Found by the case table, which is the whole reason the table has a case for it.

**Then the matcher was generalised rather than extended, three times, each from a real reply** — and
that sequence is the finding worth keeping, because each fix is a rule rather than a word:

| the reply that exposed it | the first version | the rule that replaced it |
|---|---|---|
| "Checking your **latest** emails right away" | fixed phrase "your emails" — needs adjacency | the account is a **possessive and a two-word window** |
| "Here are the **six emails** sitting in your inbox" | a content modifier, which this has none of | the account noun appearing **twice** is the signal |
| "Of course. I'll check your inbox right away" | both of the above | a **read promise**: first person + a verb stem |

**And then the promise rule fired on the app's own honest sentence** — "I haven't looked at your
email yet." — which is the *output* of this guard's other branch, so a rule that read it as a promise
would re-read in answer to its own honesty, forever. The fix is a general property, not a denylist of
the three sentences this file writes: **a promise looks forward and a denial looks back**, so a
negation anywhere in the reply settles it. The stems are stems rather than contractions because the
tokenizer splits on anything that is not a letter or a digit, so `"haven't"` arrives as `"haven"` —
a list containing the contraction would not have matched the one sentence the rule exists not to match.

**Broad here is safe in a way it would not be in the other direction.** This gate only ever *adds* a
read, and a read cannot replace a correct sentence; P4-02's rule is the one that applies. The
consequence is that the three regression cases are the load-bearing half of the table — G4 (a
grounded meetings answer), G5 (a grounded screen answer), G6 (a proposed draft) — because P1-14's
version detected every bad turn *and* replaced two correct ones, and a table that only proved the good
cases would have shipped that again. G8 (*"your calendar is a good place to keep that"*, advice, not
content) is the fourth, and it is why the account noun is deliberately not in its own content list.

**Two places this task's text could not hold as written, both recorded and neither a lowered bar.**
(1) The task's condition 4 ("names it as the person's in a non-question sentence") and its own G8
("advice, not content → untouched") are contradictory as stated — *"Your calendar is a good place to
keep that"* satisfies the first. The discriminator the task does not name is **where the account is**
versus **what is being said about its contents**, and that is what the possessive window plus the
content rule implements. (2) The task says to read "the session's tool rows"; there are none, and the
audit log cannot stand in — it is the whole process and carries no session id. The set is therefore
`AgentSession.completedToolIDs`, in memory and conversation-scoped, cleared on `endSession` and
`clear`. **No new log.** P1-29 is the task that makes these ids joinable across the logs on disk.

**Not covered, and stated rather than implied:** the task's G2 is a *loop* behaviour — run the read
where `agentAutoRunReadTools` is on, say the honest sentence and arm the offer where it is not — and
that needs a scripted provider driving the real loop, which this table does not have. What is pinned
is the pure half: the offer carries the person's own request and the tool id, the honest sentence
names no tool, and it is not a question. The assertion that the guard must **not** fire on its own
output is here, and it earned its place: the first draft of the promise rule failed it.

### P4-01 — done, `c4fa973` (2026-09-27). One clock, and the two lines that duplicated it are gone

`AgentNow.swift` is one renderer over one cache, and every path with a clock reads it. The planner's
`Today is …` line and the routine runner's `Now:` line are **deleted**, not moved — `grep` finds no
third date source, which is the only way to know a substitution happened rather than an addition.

| | before | after |
|---|---|---|
| voice first pass | 4,229 chars (94% of 4,500) | **4,362** (97%) — no ceiling raised |
| planner prompt | 5,394 (per the 09-27 note) | 5,515, against a 15,000 bound |
| "What do I have tomorrow?" | an agenda for 2023-10-27 on 09-14 | `get_agenda(2026-09-28)` — the right day |
| "What's today's date?" | "the clock reads 1:45 AM", 3½ h out | "Today is Sunday, September 27, 2026." |

`NOW_BLOCK_OK`; `PERSONA_OK`, `SCHEDULE_OK`, `ROUTINE_AUTHORITY_OK`, `TOOLLOOP_OK`,
`TOOLLOOP_PRODUCTION_OK`, `GROUNDING_OK` (its model-absent red unchanged), `make test` 30/30.

**The size number is the one to watch, and it is not a pass.** The voice first pass went 94% → 97% of
its 4,500 budget. No ceiling was raised, and `voiceFirstPassBudget`'s own comment already says
trimming that prompt is a latency decision rather than something to do by lowering a bound. **+133 is
this Mac's floor** — no calendar is connected here, so the block renders short — and the `.full` cap
of 600 is the ceiling by design. If a later task needs room in that prompt, the block is the first
thing to trim, and the shape table is what says which lines a path may lose.

**Two honesty rules in the block, both with a case each.** `- Calendar: not connected` is never
rendered as `- Next: nothing in the next 24 hours`, because the second teaches a model to invent a
confident answer about an account nobody connected. And nothing in the block names an id — task ids,
proposal ids, event ids, file paths — because a model that can read one will put it in an answer, and
a person cannot use it. A cloud reader gets the clock and nothing else unless `agentCloudConsent` is
on, read as absent = false until P4-09 owns the key.

**The self-test earned its keep twice on the way, both times against my own case data.** The first run
reported *every* prompt "lacks today's date", because the fixture was built from a fixed instant while
the prompts render the live clock; the shape loop failed the same way for the same reason. The
renderer is now checked against a fixed instant and the prompts against the real today — which is the
distinction the test needed to be able to state at all, and is the same discipline P1-27's
`DynamicMention.todayDate` needed.

### P1-27 — done, `5c15739` (2026-09-27). The owner's ten are in the run, and the run still says 17/30

Ten `scored: false` cases O01–O10 sit in `LiveEvalCases.all` beside the frozen thirty, print
`TOOLLOOP_LIVE_OWNER n/10`, and get their own section in the saved report. A full run now executes
**40** cases; `TOOLLOOP_LIVE_SCORE` and the pass bar still count the thirty, so appending them moved
no threshold, and the flag's own verdict is a statement about the thirty.

| run | model | `TOOLLOOP_LIVE_SCORE` | `TOOLLOOP_LIVE_OWNER` | elapsed |
|---|---|---|---|---|
| full, 40 cases | Qwen3-4B-Instruct-2507 | **17/30** | **6/10** | 390.6 s |
| owner subset ×2 | Qwen3-4B-Instruct-2507 | — | 6/10, then 6/10 | 68.6 s, 108.3 s |

**17/30 is the number the two recorded gate runs already have**, which is the point: the thirty did
not move. Reports `agent-overhaul/P1-27/full-run.md`, `owner-baseline.md`, `owner-baseline-2.md`.

**The three reds are the owner's own failures, reproduced on the gate's model.** O01 is the one the
roadmap predicted exactly: two turns, **no tool call at all** (`tools=-`), and a confident
*"Yes, that's from your emails. I pulled the last few messages directly from your inbox."* — the
sentence `ToolClaimGuard` cannot see, because `"i pulled"` is not on its list and a list of invented
emails that makes no claim at all is invisible to any claim grammar. It is graded **`MISSED_TOOL`**,
the honest reading, and it is `MISSED_TOOL` on three of three runs. O04 (*"Sure, I'll check your inbox
for you. Let me pull the latest messages."*, no tool) and O08 (a `filesystem.search` for "trip", then
*"I don't have access to your trip document"*) are the other two.

**Six are green without anything having fixed them**, which is worth saying plainly: O03, O05, O06,
O07, O09 and O10 pass today. O07 — *"Today is September 27, 2026."* — passes on this model, so P4-01's
missing Now block did **not** reproduce on Qwen3-4B; the audit's wrong clock was a different turn. The
case is the regression guard, not a live red.

**The owner set is subject to the same variance the phase gate is blocked on, and the first run proved
it.** Two runs of the *identical binary* both scored 6/10 with **different membership**: O02 passed then
failed (`MISSED_TOOL` both times after — `search_email` ran on the first run and not on the second),
while O05 went the other way for a reason that was mine, below. So 6/10 is a number with a ±1 band, and
the gate's "O01–O09 PASS" is not something a single run can establish — the same conclusion the 30-case
gate reached, now measured on a second set.

**One case defect found by running it, and it was in the case, not the Agent.** O05's first baseline was
`WRONG_TOOL` on a run that opened Google Chrome **and** navigated to `mail.google.com` and replied
*"Opened mail.google.com in Google Chrome."* — the whole request, done. I had put `computer.open_app`
in `anyOf` and then given it a `name` check wanting `"gmail"`, so naming the browser the *person* had asked
for was scored as a wrong tool. The app is the other half of the sentence, not its subject: the URL tools
carry the requirement and the app moved to `allowed`. Both directions are now pinned in the grader, so
the correction is a contract rather than a number that moved. Recorded rather than quietly fixed, because
the rule is the same one that made N01 an owner's call — with the difference that this is data this task
wrote, and the measurement is what caught it.

**O08 is anti-correlated with its own expected fix, and that is P1-25's problem to settle.** The case
passes on "find, then append (or ask which document)", which is the roadmap's own definition. But P1-25
exists to make the Agent **refuse** an ungrounded `document_id`, and its refusal — *"That document hasn't
been found yet — search for it first."* — is a statement, so `orQuestionMentioning` never reads it. Once
P1-25 lands and behaves correctly, this case will grade that correct refusal `REFUSAL`. Recorded here
rather than pre-empted: widening `compoundQuestionMentions` would change F03's pinned behaviour ("email"
inside a quoted file query is not a question asking for the address), and the owner owns that call.

**Three implementation notes, all load-bearing:**

1. **`--only O07` must not print a meaningless green.** A run whose selection has no scored case is a
   diagnostic, so it returns true **and says so in words** — `TOOLLOOP_LIVE_OK: no scored case in this
   selection — the TOOLLOOP_LIVE_OWNER line above is the result` — rather than `0/0`, which reads like a
   score of nothing against everything. The pass bar now scales on `scored.count`, not `selected.count`,
   so the ten cannot move a threshold on any path.
2. **O06 needed a new `ExtraRule`, and the grader caught why.** `.answerOnly` is judged over the whole
   case, so a two-turn case cannot say "the first turn may look, the second must not" — permitting turn 0's
   `filesystem.find` in `allowed` permits it in the greeting too. `ExtraRule.noToolFromSecondTurn` is the
   one line that says it, with a failing-branch pin. The first grader run after writing the ten reported
   `TOOLLOOP_LIVE_GRADER_WRONG: O06 expected PASS got WRONG_TOOL` — **the self-test failing on my own data,
   which is the whole reason it exists.**
3. **O07's date mention is a list of spellings, read at grade time.** `DynamicMention.todayDate` asks for
   *"Today is 2026-09-27"*, *"Sunday 27 September 2026"*, *"27 September 2026"*, *"September 27, 2026"*,
   *"Sun 27 Sep"* and *"Sunday"* — and deliberately **not** a bare day-of-month, which sits inside any date
   the 27th of a month appears in and would turn a wrong answer into a pass once a month. The date is
   read when the case is graded, not when the list is built, so a run crossing local midnight is not judged
   against yesterday. This is the same class of defect as N01's apostrophe, designed out rather than
   recorded.

**Regressions, all run on the same binary:** `TOOLLOOP_LIVE_GRADER_OK` (14 new pins), `make test`
30/30, `NATIVE_TOOLS_OK`, `CAPABILITY_MANIFEST_OK`, `TOOLLOOP_OK`, and `--quick` at **5/10** — the
post-P1-08 number, so appending ten cases cost the per-task gate nothing. **One correction to a claim
above:** `--selftest-toolloop-production` now prints **`TOOLLOOP_PRODUCTION_OK`** (0 `_WRONG`), where
three of these notes record "1 (P3-01's)". P1-27 cannot be the cause — the flag reads no eval data — so
the last commit to have changed it is `fd4e6ae` or `1c6e9e8`. Recorded so the next executor does not
spend a task on a red that is green; P3-01's voice-header size line may deserve a re-read rather than
a fix.

**Not run, and it is not a gap in the work:** a full run on Apple FM, and any run with `--allow-cloud`
(which is off, so no cloud number exists). The Agent role now reads `cloud` on this Mac
(`modelRoles.agent`), so both owner runs above pinned the gate's model with
`--model unsloth/Qwen3-4B-Instruct-2507-GGUF/…` to stay comparable with the recorded 17/30 runs; with
the role as it stands the eval falls back to Apple FM. That is an owner setting, not something this task
changed, and it is worth knowing before the next gate run. **One observation about the log, not the
eval:** a third-party `onnxruntime` stderr line landed *inside* the `TOOLLOOP_LIVE_CLASSES` line in the
captured output, so that one line is unreadable in the log while the run itself printed it whole. It is
pre-existing (any eval with Parakeet resident can hit it) and the classifier reads the *final* line, but
a class tally should not depend on a foreign writer staying quiet.

### Exit-gate blockers — done, `fd4e6ae` (2026-09-26)

Three defects in committed code made specific eval cases unwinnable for reasons unrelated to the
Agent. **No verdict bar moved.**

1. **`lexicon[.screen]` carried the bare word "open"** — it introduces a site, an app and a file
   equally, so nearly every request selected the whole 13-tool screen class. Replaced by
   `namesKnownApp`, which asks `AgentDirectIntent.parse(_:wholeSentence: false)` — the one app-name
   list in the tree — whether the sentence opens a *named* app.
2. **`search_email` was in `coreIDs`**, so a mail search sat in the schema of every turn including a
   browser request. Out (9 -> 8 core ids). Mail requests still select the mail class **whole**, pinned
   for five requests. **Parity stays 65** — nothing left `allowed`, so the execution allowlist, the
   refusal guard, "what can you do" and the direct-intent shortcut are untouched.
3. **The eval's fake mailbox could not answer any form its own tool description advertises** —
   `from:`, `subject:`, `newer_than:`, `is:unread`, and the empty query that means `in:inbox` — and
   answered a miss with `""` where the real tool says *"No message matches <query>."*, which is how a
   case concluded "no new email summaries were found" about a mailbox of six.

**Blocker 3 went a third way, and the reasoning is the interesting part.** Adding rows was
overfitting: the query is the **model's**, not the case's (M03 sent `recent`, `recent` and
`from:productflo.com` in three runs), so no corpus change makes "the case's query" answerable and
fitting one sample of a stochastic model would make the exit gate irreproducible. Correcting a query
was impossible: C04/M03/M05 contain no query. So the **matcher** was fixed — the same six messages, no
row added, removed or renamed, no address or subject invented, with `GmailQuery.normalize`/`tokens` as
the one grammar, the real tool's newest-first numbered rendering, and its miss and refusal sentences.
14 query forms, 3 miss sentences, 2 refusals and the numbering are pinned from
`--selftest-toolloop-live-grader`, written **before** the fix and proven red against the old scanner
(17 problems).

| | before | after |
|---|---|---|
| `--selftest-toolloop-live --quick` | 5/10, `wrong_tool 1`, `ungrounded 3` | **5/10, `wrong_tool 0`, `ungrounded 4`** |
| `--only A01,A02,A03,C04,M03,M05` | 1/6 | **3/6** (A01 and A02 PASS) |
| `CAPABILITY_MANIFEST_PARITY` | 65 | 65 |
| `CAPABILITY_MANIFEST_PROMPT` | 1,440 tokens / 16 tools | 1,440 / 16 (byte-identical) |
| `CAPABILITY_MANIFEST_SMALL` | 1,124 tokens / 9 tools | **1,091 / 8** — the fix itself |

**An honest cost, measured and not buried: N04 went `PASS` -> `UNGROUNDED`**, deterministic across
3/3 runs and confirmed by a controlled probe that put `search_email` back into `coreIDs` and flipped
it to `PASS`. With the mail line gone from the catalogue the model writes *"get info about meetings"*
where it wrote *"what's on your calendar"*. The capability is intact — `get_agenda` is still core, the
calendar class still whole, grounding still says "their calendar" — and its `mustMention` is the
single literal word "calendar", untouched. **This is the exit gate's first open item**: the score held
and the shape improved (`wrong_tool` is a schema defect, `ungrounded` is a paraphrase), and both facts
belong in the ledger rather than behind a green number.

**The three mail cases are still red, and the reason is now correctly located**: the Agent sends a
query the corpus cannot answer and then reports the miss, instead of retrying with the empty query the
tool documents. That is a **query-repair gap in the Agent**, not a fixture gap — and it belongs to
P1-09's recoverable-bad-query path or to the next phase.

### P1-13 — done, `44c176d` and P1-05 — done, `58d0b8c` (2026-09-26)

**Phase 1 is now 14 of 14 committed.** P1-13 and P1-05 ran as a parallel wave — their file lists do
not overlap (P1-13 is `AgentDirectIntent` + the tool-loop self-test; P1-05 is `Agent/Planner/*` plus
the provider and formatting files).

**P1-13 — two-word sites before one-word sites.** "Open google calendar on google chrome" opened
google.com in Chrome and never opened the calendar; the planner then refused and fabricated a
`get_agenda` run. Ten seconds, grade 0. `knownSitePhrases` is eight Google product phrases matched as
contiguous word runs **and consumed by index**, so the strict remainder and `namedApp` never read
those words twice. A leftover noun still goes to the planner; "open google calendar on google chrome"
consumes the phrase, leaves nothing, and opens `calendar.google.com` in Google Chrome. The red run
also caught an unadvertised bug: `namedURL("open drive")` said `drive.google.com` while
`namedURL("open google drive")` said `www.google.com` — the same page answering two ways.

**The roadmap's stated cause was wrong and the red run proved it.** It said P1-08's strict parse
would send that sentence to the planner with "calendar" left over; in fact `openConsumed` already
unions every word of every app and site name and "calendar" is a `knownApps` key, so the remainder is
empty and the shortcut *fires* — which is the 22:07:03 symptom itself. The fix is the phrase pass plus
index consumption, not a stricter remainder. Pass order is phrase -> spelled domain -> single word, not
the sketch's order, because reversing today's domain check would let a bare "google" beat a typed
"youtube.com".

**P1-05 — three constrained-decoding backends.** llama gets a GBNF grammar over `manifest.selected`
plumbed into the streaming sampler; Apple FM gets one `Tool` per entry with `Tool.call` bridged into
`ToolStepRunner`; the OpenAI-style providers get `tools` + `tool_choice` with `tool_calls` deltas
reassembled. `PlannerBackends.make(for:)` is the only place a backend is chosen, from the provider the
turn already resolved.

| measurement | prompt convention | native |
|---|---|---|
| `--quick --model apple` | **2/10** (`missed_tool` 6) | **6/10** (`missed_tool` 0) |
| `--quick` agent role (Qwen3-4B) | 5/10 | 5/10, 11 rounds on `llama-grammar`, 0 refusals |

Same Apple model both times: asked in prose it narrates instead of calling in 6 of 10 cases; given the
schema it calls. No malformed-call repairs and no `LEAK` in any of the four traces.

**The grammar and the schema are provably one set**: `--selftest-native-tools` parses the *rendered*
grammar back with `GBNFParser` and compares it to `manifest.selected`, to `toolWireDefinitions` and to
the fitted catalogue's ids, and the grammar's tag literals are the parser's own `openTag`/`closeTag`.

**The tolerant path is still intact, deliberately**: the same self-test requires P1-04's parser to
recover the measured 2026-09-23 leak while the grammar refuses that same string, and
`PromptConventionPlanner` remains both the default and the rollback path.

**`agentNativeToolCalling` stays `false` — the task's own rule** requires three full 30-case runs
scoring at least as well on both models, and only `--quick` was run. So the native path is a rollout
switch, not a shipped default, and `Settings.swift` and `AGENTS.md` say so. **This is therefore the
Phase-1-exit gate's first job, not an optional extra.**

Two spec points could not hold as written and were corrected, not forced: the live llama half asserted
"the four tool prompts call the expected id", but the manifest's own rule line says "call
`schedule.list` first" and the model obeyed it — so the assertion now measures what constraining
decoding actually buys; and the planner round must not go through `streamConversation`, which prefixes
a role on some providers and moved the fitted prompt by two tokens per round.

### P1-11 — done, `fd8ebc3` (2026-09-26)

`ToolClaimGuard` refuses a reply that says a completed action happened when this turn ran nothing: a
first-person completed verb, a passive count, or a registry id/alias. One such claim buys exactly one
re-plan (audit row + `replanNote`); a second in the same turn is replaced whole by an honest sentence
and the fabricated text is never typed or spoken. The grader now reads its claim list and its
leak-name list **from the guard**, so `FABRICATED` and the guard ask one question with one list.

| | before | after |
|---|---|---|
| `--selftest-toolloop-live --quick --model apple` | `fabricated 2, pass 1` | **`fabricated 0, pass 2`**, refusal 0 -> 0 |
| K01 on Apple FM | `FABRICATED` | **`PASS`** — the re-plan note made it run `meeting.decisions` and answer from the result |
| `--selftest-toolloop-production` | 22 `_WRONG` (21 this task's) | **1** (P3-01's) |
| `--selftest-toolloop-live --quick` (agent role) | 5/10 | 5/10, identical tally, no `PASS` lost |

**The honest boundary, stated rather than widened.** The guard refuses *claims of a completed action*.
An ungrounded assertion in the second person — *"You have no events on your main calendar today"*, no
tool run — is not a claim by this grammar and is not refused; that is the `MISSED_TOOL`/`UNGROUNDED`
class, which is why C01 moved `FABRICATED` -> `MISSED_TOOL` on Apple FM rather than to a pass. The
remaining fabrications use verbs the list does not read (*"I created a new reminder"*, *"I've started
searching your Gmail"*). **Widening the shared list would also widen the eval's own definition of
`FABRICATED`**, so the shapes are named here rather than the metric quietly changed. That is P1-08's
and P1-13's ground.

**What the guard must let through, each pinned**: an offer, the idiom (*"Ran into traffic?"*), an
honest negative after a search that really matched nothing, and any claim a call in this turn backs.
A claim naming no tool is backed by any completed call, because nothing in the sentence says which
call it means and a verb-to-tool table would refuse true sentences. F03 is the live proof it is not a
refusal machine — *"I found the pricing document: Pricing 2026.pdf in your Documents folder"* passed
through untouched because `filesystem.search` really did complete.

The Apple FM number is a **cross-build comparison, not a controlled A/B** (model nondeterminism, and
P1-10's report is a different build), and the first Apple FM attempt could not warm up and said so:
`Apple's built-in intelligence did not answer a warm-up (com.apple.SensitiveContentAnalysisML error
15)`. The retry ran.

### P1-10 — done, `3aac1a4` and P1-07 — done, `de3763c` (2026-09-26)

Third parallel wave (P1-10 with P1-07, which have no file overlap — P1-10 and P1-11 *do* share three
files, so they are not a pair). Both ended with one genuine cross-dependency, resolved here rather
than by either agent touching the other's file.

**P1-10 — the reader-scaled cap and the single renderer.** A 30,000-character tool result went to a
4,096-token reader whole, and a reply that ended in a timeout still named the tool, the step, and
nothing about running out of time. `ToolResultBudget` is the ladder 700 / 1,200 / 4,000 / 12,000 at
4k / 8k / 32k / 256k, doubled for the read tools, with a `@TaskLocal` reader bound around each
`AgentToolExecutor.run` so `WorkspaceToolRunner` sizes its own truncation for the model that will
read it. A per-round fitter drops the earlier conversation, then folds, then caps: four
30,000-character results fit a 4,096-token window at 2,834 of 4,096. A context-window error is now
`.contextOverflow` — *"That was too much to read at once"* — not a planner failure.

`AgentTurnOutcome` has ten cases and `AgentReplyRenderer.render` is the one place a reply is
written. **The scrub runs last on every path, and an outcome of `nil` means the text is an answer
and nothing is rewritten** — which is the fix for `voiceSafeReply` having answered *"What's a sales
quota?"* with a usage-limit notice.

| | before | after |
|---|---|---|
| `--selftest-toolloop-production` | 63 `_WRONG` (19 genuine) | **1** (P3-01's) |
| `--selftest-toolloop-live --quick` | 5/10, ungrounded 4 | 5/10, timeout 0, leak 0, ungrounded 4 |

Red-first found a bug in the agent's own first cut: the cap chose the wrapper's `"<name> returned:
"`
as the line boundary, kept 19 characters and threw away the document it was written to bound.

**The ungrounded count did not move, and the reason is the fixtures, not the code**: three of the
four are `search_email` calls whose query matches **zero rows** of the eval's own fake mail, so the
tool ran and there was nothing to summarise. A cap, a fold and a renderer cannot make content
appear. The fixture table is `Agent/LiveEval/ToolLoopLiveEvalFixtures.swift`, which is P1-01's file
— **worth an owner's decision**: either the fixtures gain the rows the cases ask for, or the cases
are asking for something the fixture never had.

**P1-07 — the conversational rules.** A question with no verb beside its noun missed the tool-shape
gate and was answered from guesswork; a denial the person contradicted was spoken anyway; an
acknowledgment aimed at the agent's own question was clarified instead of resolving it. All three
fixed: word-bounded question routes gated on classes with a *ready* tool, one-shot denial escalation
through `AgentRefusalGuard.rebuttal(for:manifest:)`, and one pending-action slot with one
acknowledgment vocabulary.

**The positive corpus is pinned beside the junk, which is the whole point** — the shape-version of
the noise gate shipped on 09-22 and silenced the app, because `normalize()` strips leading fillers
and a four-word question became a two-token fragment. Nine ordinary questions are proved to reach the
model and be answered; the four question forms are proved to route only when a tool is ready, and
answered by the model when none is.

**Everything added routes to work; nothing subtracts a model answer.** The one rule that withholds
the model is the `mayBeDenial` hold, and it withholds *speech*, not the turn — audio is delayed
while a reply might be a denial, and an honest reply is then spoken whole. The cost is a pause,
never a wrong word.

**The cross-dependency, resolved here:** P1-10 re-pointed `voiceSafeReply` at `scrub(_:outcome:)`,
which reds four P0-7 assertions living in `VoiceCapabilityConversationSelfTest.swift` — P1-07's
file. Neither agent was allowed to touch the other's, so both reported it rather than reaching
across. The four are now retargeted at `AgentReplyRenderer.render(_:voice:)` with the outcome the
turn ended on, **and the complementary direction is added in the same block** — an answer is never
rewritten — so the test cannot quietly become weaker than the one it replaces. That edit is in P1-07's
commit, so P1-10's commit is momentarily red on that one flag by design, and its message says so.

`VOICE_TURN_ROUTING_OK`, `VOICE_TURNS_OK`, `VOICE_CONVERSATION_OK`, `DUPLEX_OK`, `TOOLLOOP_OK`,
`CAPABILITY_MANIFEST_OK`, `make test` 30/30.

### P1-06 — done, `4047bd9` and P1-12 — done, `078c51c` (2026-09-26)

Second parallel wave, no file overlap. Both green. Both had a cancelled first attempt whose in-flight
work was picked up and finished rather than reverted.

**P1-06 — the per-round budget.** The eval's `TIMEOUT` class was a wall clock, not a verdict: a plan
answered in 3-12 s was cut off at 18 s and the person was told *"I stopped the tool plan because it
took too long."* `--selftest-agent-answers` was flaky for the same reason (2 of 3), and the pre-P1-02
tree recorded it five times. One plan now gets a per-round deadline and a total; time on the user's
voice floor or an approval is never charged, writes stay unbounded. Typed local 30 s/round, 20 s/read,
120 s ceiling, +45 s on round 0 only when the app's own model is cold. **The final answer round is
deliberately kept affordable**: it runs on exhaustion of rounds/calls/a repeated call, never on a
timeout, with no catalogue in its prompt, and is not charged to the ceiling — a plan that spent its
allowance still owes the person a reply.

| | before | after |
|---|---|---|
| `--selftest-toolloop-live --quick` TIMEOUT | 3 (1 vs the committed baseline) | **0**, no `LEAK`, no `PASS` lost, slowest case 36.6 s of a 150 s cap |
| `--selftest-agent-answers` | flaky 2 of 3 | **`AGENT_ANSWERS_OK: 3/3`, three consecutive runs** |
| `--selftest-toolloop-production` | 18 `_WRONG` (in the red build) | **1** (P3-01's) |

K01 and R02 reached PASS; C04 and M01 are no longer `TIMEOUT` and are now `UNGROUNDED`, which is
P1-08's ground. No deadline was inflated to get there, and none of the ten cases reached the call or
round cap — that backstop is pinned by self-test cases 5-7 instead.

**P1-12 — one provider per turn is now actually true.** A turn resolves once at
`AgentModelRouting.provider(for:voice:)` -> `ModelRoleStore.provider(for: .computerUse)` ->
`case .app` -> `provider(for: .agent)`, terminating in one `LLMProvider`; the manifest is fitted to
the reader that will see the prompt. **Before this, a computer-use fallback answered with the
library's active GGUF while the person's Agent role was on Apple's — a silently different model, which
was the bug.** A remembered Codex quota is now a `Date` only (never the output, URL or transcript),
and it produces one plain sentence: *"Codex can't take this until <weekday> at <time>, so I did it
here."* — no `ERROR:`, no link, once per window.

**A guard that made it worse than a dead end, found and fixed:** the route guard asked
`computerUseHarness` — the *resolved readiness* — before the quota check. A remembered quota turns
that readiness red on its own, so after the next launch or Settings refresh the guard returned nil,
no sentence was ever said, and the job **silently stopped going to Codex**. Stored choice and live
readiness are now two separate questions.

Three inherited changes were corrected rather than kept: that guard; a test case that returned early so
a broken parser could never show its own case red; and a `displayName(for role:)` change with **no
production caller anywhere in `Sources/`** — the "finished feature with no call site" trap — so it and
its assertion were reverted.

**`--selftest-model-unopenable` went `MODEL_UNOPENABLE_OK` on both P1-12 runs.** The marginal S1-mini
timing gate (5.0-5.1 s against its 5 s budget) is therefore **flaky, not fixed**: it passes on a quiet
machine and fails under load. Nothing was lowered. Treat it as a load-sensitive measurement.

Two things neither task could run: the owner smoke test (no Codex CLI on this Mac, and the allowance
window has passed — the self-test's far-future fixture covers the same path), and the full 30-case eval
(a Phase-1-exit artefact, not a per-task gate).

### P1-04 — done, `bb3a326` (2026-09-26) and P1-09 — done, `cf99705` (2026-09-26)

Run as one parallel wave; no file overlap. Both green, no regression anywhere.

**P1-04 — the tolerant parser.** A model writing one closing brace too many (`"},"rationale":`) had its
whole call refused and leaked its reasoning to the person — the sentence the live eval grades as a
`LEAK`. It recovers exactly one call per marked region and only as a *prefix*: the prefix must parse
as one JSON object with a usable name, and the tail must hold no `{`, no `[` and none of `"name"`,
`"arguments"`, `"tool_call"`. Still refuses: a run-out-of-text object, JSON with no name, unmarked JSON
whose name is not in this turn's roster, and anything past two repairs per turn. **Two of its own tests
caught it answering wrongly where it used to fail loudly** — a registered-but-not-allowed router hit
used to fall through to fuzzy matching and swapped `files.find` for `browser.fill`; and a near miss
turned `launch_rocket` into `memory.forget`, a destructive tool. Both are ceilings now: an unavailable
router hit refuses, and a near miss must agree on the leading token, so `send_emial` -> `send_email`
still resolves and nothing crosses capability.

| | before | after |
|---|---|---|
| `--selftest-toolloop-production` | 3 `_WRONG` | **1** (P3-01's) |
| `--selftest-toolloop-live --quick` | 5/10, leak 1 | **5/10, leak 0**, M05 `LEAK` -> `UNGROUNDED` |

Two spec points could not hold as written and were adapted, not faked: Levenshtein-<=2 cannot map
`get_calender` -> `get_agenda` (distance 4, over even its own <=3 tier), so resolution also matches the
entry's `userPhrase` words; and an unknown tag still yields `.invalid` rather than escalating to
`.tools`, because `--selftest-voice-conversation` pins that and only *call markers* escalate.

**P1-09 — the recoverable bad query.** `older:1d` and `in:after 2026-09-04` are rewritten to Gmail's
real operators, the normalised query is reported on an empty result so the next attempt does not repeat
the word, and an invented operator throws `invalidRequest` naming operators that work — which P1-04's
classifier maps to recoverable, so the turn re-plans with at most two repairs. `read_email` is new
(`.read`, registered, parity pin, refusal guard, voice snapshot). **The "from unknown sender" bug is
fixed at its measured source**: `+read` prints `from` as `{"name","email"}` and metadata puts headers in
`payload.headers[]` — neither is a top-level string, which is where 5-of-5 unknown-sender audit rows
came from. `GWS_FIXTURES_FAILED: 28 of 9` -> **`GWS_FIXTURES_OK: 9`**, `GWS_OK` signed in, and one real
read measured `GWS_LIVE_MAIL: 3 messages, 3 senders parsed, 3 subjects parsed, 1.03s` (counts and a
duration only, because that line lands in a log file).

**Two honest negatives, recorded rather than buried:**
1. **The eval did not move for P1-09**: 5/10 on `--quick`, identical to the post-P1-03 baseline, with
   M01/M03/C04 still non-PASS. They are now *answerable*; the model does not spend a second round on
   `read_email`, which is P1-04/P1-06's ground. R03 also remains `MISSED_TOOL` with a correct roster.
2. **There is no snippet in `search_email`.** Gmail returns one only for `format: full`, measured at
   71,698 bytes against metadata's 601 for the same message — the difference is the whole body — so
   honouring the same task's "do not read message bodies" rule costs the snippet.

Provenance: P1-09's two `NextNotesApp.swift` hunks were swept into the iMessage workstream's commit
`32174e4` before staging, so they are recorded in `cf99705`'s message rather than its diff.

### P1-03 — done, `0a7281a` (2026-09-26)

`AgentCapabilityManifest` is now the one per-turn source of truth, built once per planner turn from the
registry (native, MCP, Composio), the four switches, consent, the reader and live readiness. It answers
for the planner's schema, the rule lines, the grounding sentence, the execution check, "what can you
do", and the voice gates. `plannableTools()` survives as a wrapper over it, not a second opinion.

| Measurement | Before | After |
|---|---|---|
| `--selftest-capability-manifest` | 33 problems | **`CAPABILITY_MANIFEST_OK`** — 78 registered, 64 allowed, 95 id/alias spellings, planner 1,411 tokens / 15 tools, small talk 1,131 / 9 |
| `--selftest-toolloop-live --quick` | 2/10 | **5/10**, four runs, identical |
| leak verdicts in `--quick` | 3 | **1**, no new leak |
| `--selftest-toolloop` / `--selftest-mcp` / `--selftest-persona` / `--selftest-ui-strings` | green | green |

**One of the two `toolloop-production` prompt-size lines closed, and it was the wrong bar.** 1,561
tokens described a hand-picked 12-tool roster the turn never really sends; the manifest measures 1,814
for 25 tools on an 8,192 reader. The old 900-token bar for the *whole* prompt was arithmetically
unreachable — persona, rules and grounding are 1,038 tokens with an empty catalogue. The prompt shrank
anyway: small talk 1,841 -> 1,131 tokens, the conversation roster 6,316 -> 4,794 chars.

**The second line stays red and is not this task's**: the voice header pass carries no tool roster at
all, and 2,692 of its characters are `voiceRoutingRules`, which **P3-01** owns. Left exactly as it
was. Recorded here so P3-01 inherits it deliberately.

**Refusal per clause, and an offer is a refusal** — but only when the same clause says it is blocked.
"I don't have enough information to set that reminder" survives as an honest limit; "I'd need to use
your tools — would you like me to…" is caught by the `blockedNeeds` register. A denial of something
switched on but not connected is honest: those entries go in `unavailable` with a setup sentence.

**Why the eval moved**: K01 ("what did we decide") now selects the meetings and knowledge classes whole
and reached PASS; R02 passed on the reminders rule. **R03** ("what's on my to-do list") is still missed
*with a correct roster* — the 4B model answering from guesswork, which is **P1-04/P1-11's** grounding
problem, not a selection defect.

Nine pinned self-test expectations that asserted the old mechanics were updated to the manifest: no
threshold lowered, no assertion removed. Two pieces of dead code deleted rather than kept — the private
`allowedIDs` list, and `VoiceCapabilitySnapshot.selfTest`, which a grep showed had no callers.

### P1-14 — done, `bf8fe44` (2026-09-25)

One file, `Agent/RealtimeAudioSession.swift`, no registry edits (`--selftest-duplex` already existed
in all three, as the task's own "Red-first self-test" says). The short-edge and single-word residual
rules now fire only against a clause that is `active` or ended within a 1.5 s `echoTailSeconds`
tail, through the single predicate `isInEchoTail(_:now:)`. The residual's older 3 s age clause is
subsumed. A fresh utterance more than the tail after the agent's last *ended* clause — and that
clause ending in a question — gets no lexical rule at all; an inherited mask is never "fresh", so a
cumulative revision cannot open a hole in itself. Span rule, provisional-prefix rule, inherited
mask, `echoWindow = 15`, `maxEchoReferences = 6` untouched.

`DUPLEX_WRONG` x4 -> **`DUPLEX_OK`**, stable on three further runs. `VOICE_TURNS_OK`,
`VOICE_EOU_OK`. `--selftest-voice-pipeline` is down to its one documented Phase 2 answer-quality
line — **the P0-10 EOU line is gone**. Two documented deviations, no deleted assertion and no
lowered threshold: the "09:07 revised reply tail" case is a single-word residual match at +10 s,
which the task's own Target behaviour scopes out of the tail, so its expectation is restated and a
new +0.5 s companion still asserts removal; and a seventh case pins the 2-word short edge, which the
task's six did not cover.

**This is what unblocks P1-07**: a spoken "yes" / "okay" / "calendar" answering the agent's own
question now survives `userSpeechExcludingPlayback` and reaches the pending-action slot.

### P1-02 — done, `7bc440a` (2026-09-25)

The typed tool-less first pass is gone and the pending action is typed: `Agent/PendingAction.swift`
(new) holds the offer and its negative matchers for 180 s, session-scoped, with a `confirmedPrefix`
guard so a confirmation bypasses `AgentDirectIntent`. "yes" carries the action instead of
re-deriving it.

| Measurement | Before | After |
|---|---|---|
| `--selftest-toolloop-live` (full, agent role) | 5/30 in 629.2 s | **10/30 in 270.9 s** |
| `--selftest-toolloop-live --quick` | 1/10 | **2/10**, stable over 3 runs |

C02, C03, M04, A04 and R01 — P1-02's named targets — reached PASS. Red was verified first-hand: the
three production hunks `#if`-disabled produce 18 `_WRONG` lines, restored byte-identical (sha256).

**Step 6's export for P1-06** (measured live: window 32768, prompt 1,678–1,825, visible 1,024):
`RealtimeAgent+ToolLoop.swift:1169-1170` declares once-per-plan `let window =
AgentAnswerBudget.readerContextTokens(for: provider)` and `let depth = answerDepthForTesting ??
Settings.shared.agentResponsiveness`, consumed at :1289-1294 by
`AgentAnswerBudget.tokens(kind: .plannerRound(background:), contextTokens: window, promptTokens:,
depth:)`. Both literal 256s are gone.

**Two things P1-02 surfaced, which are the next two tasks' work, not defects to hide here:**
1. **Five new `LEAK` verdicts, all one shape** — the model writes `"},"rationale":` and the strict
   parser refuses it. The round cap moving 256 -> 1,024 gave it room to write malformed JSON that
   256 used to truncate. That is **P1-04's** tolerant parser, and the eval is now finding it.
2. **`--selftest-agent-answers` is flaky**: "took too long" on 2 of 3 runs against the unchanged
   18 s typed plan ceiling versus a 1,024-token round. The pre-P1-02 tree recorded the same failure
   5 times and 1 pass. That is **P1-06's** named bug.

The typed prewarm is retargeted from `voiceRoutingSystem(voice: false)` to the new
`typedWarmSystem()` (a prewarm of a prompt no typed turn sends passes nothing);
`LLM_PREFIX_CACHE_OK: reused 646/666` holds. The inherited 15,000-char prompt ceiling had no
measured number behind it: the real roster is 6,316 chars, so the ceiling is 8,000 (the bound the
same file already holds the tool-request prompt to) with a permanent `CONVERSATION_PROMPT_CHARS`
print.

`TOOLLOOP_PRODUCTION` stays at its 2 baseline prompt-size lines (P1-03/P1-06), no third.
`TOOLLOOP_OK`, `PERSONA_OK`, `VOICE_CONVERSATION_OK`, `UI_STRINGS_OK`, `make test` 30/30.

### P1-01 — done, `de07497` (2026-09-25)

The first Phase 1 task, and the one every later task is measured against. Its success threshold is
a **recorded baseline below 25/30**, so a low score is the correct outcome and the eval's own
`_FAILED` is not a regression.

| Run | Result | Evidence |
|---|---|---|
| `--selftest-toolloop-live-grader` (must be green) | `TOOLLOOP_LIVE_GRADER_OK` | `P1-01-red.txt` (red: C04/C01 `expected LEAK got MISSED_TOOL`), `P1-01-green-grader.txt` |
| `--selftest-toolloop-live --quick` (per-task gate) | `1/10`, 227.0 s, pass bar 9 | `P1-01-green.txt` |
| `--selftest-toolloop-live` (full, agent role) | `5/30` in 629.2 s on Qwen3-4B-Instruct-2507 | `P1-01-full-agent-role.txt` |
| `--selftest-toolloop-live --model apple` | `6/30` in 240.8 s | `P1-01-baseline-apple-fm.txt` |
| `--selftest-toolloop` (regression) | `TOOLLOOP_OK` | `P1-01-reg-toolloop.txt` |

Reports and `.jsonl` sidecars: `Tests/Reports/toolloop-live/2026-09-25-baseline-{agent-role,
agent-role-quick,apple-fm}.md`. Two quick runs on the same build scored 1/10 with **identical
per-case verdicts** (0 differ), so the baseline is stable and Phase 1 has a real number to move.

**The Agent is much worse at tools than the transcript suggests: 5/30 with the local model, 6/30
with Apple's.** That is the finding P1-01 exists to produce, and it is the reason P1-02/P1-03/P1-04
are not optional.

Regressions unchanged: `--selftest-toolloop-production` `TOOLLOOP_PRODUCTION_FAILED` with the same
2 `_WRONG` prompt-size lines as the phase baseline (P1-03/P1-06). `--selftest-tool-awareness`
`TOOL_AWARENESS_FAILED: Gemma 4 E4B isn't downloaded` — pre-existing, matches 2026-09-24.

A third `_WRONG` line appeared in `--selftest-toolloop-production` immediately after the quick eval
("plain model answer waited for all tokens before speaking", a 100 ms real-time assertion on a
scripted provider). Re-run on an idle machine it is byte-identical to the baseline, so it was
contention from the eval's resident 2.5 GB model, not a code change; the idle run is what is saved.

Deviation: the grader's green marker went to a separate file so the quick run's red-first score is
not overwritten.

### Phase 0 gate — quiet-machine re-runs, 2026-09-25 20:00
Load average 3.2, dictation workstream's `Core/DictationController.swift` committed and clean.
- `make test` -> **30 tests in 2 suites passed** (was blocked earlier by their uncommitted edit).
- `--selftest-agent-answers` -> **`AGENT_ANSWERS_OK: 3/3 answered by Qwen3-4B-Instruct-2507`**
  (`~/Library/Caches/NextNotesBuild/agent-overhaul/P0-gate/agent-answers-quiet.txt`). The gate
  afternoon's `took too long` was load-induced, as suspected.
- `--selftest-model-unopenable` -> still `MODEL_UNOPENABLE_FAILED: 1 problem(s)`:
  `post-download live: the S1-mini trial took 5.1 s, over the 5 s budget` (5.0 s, 5.0 s, 5.1 s,
  6.5 s across four runs). A real one-token decode that sat just under the budget on 09-24; a
  **marginal timing gate**, not a correctness failure. The parallel workstream's D-06 changed the
  S1-mini load path (`AppleModelWarmth`, `CleanupRouter` gating) — a candidate cause worth one
  look before Phase 2, not a conclusion. No threshold was lowered.

### Phase 0 gate — 2026-09-25 (report `db9a84f`)
Tried: every Phase 0 exit flag, `make test`, `make acceptance TIER=core`, one at a time.
Failing lines: `MODEL_UNOPENABLE_FAILED: 1 problem(s)` (`post-download live: the S1-mini trial took 5.0 s, over the 5 s budget`); `AGENT_ANSWERS_FAILED: What's on my calendar today?: the reply said “took too long”`; `TOOLLOOP_PRODUCTION_FAILED` (two baseline prompt-size lines). Saved under `~/Library/Caches/NextNotesBuild/agent-overhaul/P0-gate/`.
Missing: a quiet machine for the two timing budgets (measured at load average 24–58; both were green on 09-24 at `P0-14b-attempt3.txt`), and P1-03/P1-06 for the prompt-size reds. `make test` is separately missing a compiling `Core/DictationController.swift` (the dictation workstream's uncommitted edit fails at :1466/:1494).
Next step: re-run `--selftest-agent-answers` and `--selftest-model-unopenable` on an idle Mac; if they still miss, P1-06 owns the budget (P0-05's risk note). Do not lower a threshold.

### Scheduling notes from the 2026-09-25 roadmap fold

1. **Historical 2026-09-25 order, superseded by the owner-approved 2026-09-27 6A/6B split:** Phase 6 was after Phase 3. `07-PHASE-6-DURABLE-JOBS.md` (P6-01…P6-10) is an
   extension of Phase 3's `TaskBridge`; every task is gated behind P3-03b/P3-06b. Inside it, P6-08
   runs after P6-09 — §3 is the authoritative order. Its five flags
   (`--selftest-task-durability`, `--selftest-task-recovery`, `--selftest-task-retry`,
   `--selftest-task-graph`, `--jobs-report`) are **not registered yet**; register them when those
   tasks run (one block in `NextNotesApp.swift`, one AGENTS.md line, one tier line each).
2. **P4-07a comes before P4-07** (and before P4-11). It depends only on P0-11 (done), so it is
   runnable; the gate is Phase 4 sequencing, not readiness. The memory order is now
   P4-07a → P4-07 → P4-11.
3. **Do not build the phantom types** named in older prose: `AgentJob` (→ `TaskRecord` +
   `TaskDurability`), `AgentResultBus` (→ `OutputScheduler.enqueue` / `TaskBridge.subscribe()`),
   `AgentUsageLedger` (→ `UsageRecord.taskID`, one log), `AgentToolScope` (→ P1-03),
   `AgentResultDeliveryPolicy` (→ `AgentDeliveryMode` + `TaskDelivery`), `spawn_agent()`
   (→ `TaskBridge.spawn`), `InteractionAgent` (the type stays `RealtimeAgent.handle`). Action
   lanes are requirements on P1-03/P3-04, not Phase 6 tasks.
4. **AGENTS.md carries an uncommitted +15-line invariant** ("There is one task ledger, one channel
   that starts audio, one tool manifest, and one usage log"), added by the roadmap editor after
   P0-12's commit `c0c5c41`. P0-12 preserved it (it is at line 307); **do not reset it** — the
   editor may commit it separately so the diff is visible.
5. **`Core/DictationController.swift` ownership, resolved.** P0-20c is **done** (`effd5c4`) and
   owns the `usage:` seam, `runID` into `recordRun`, and the `dictation.asr` / `dictation.cleanup`
   rows. The remaining call sites in that file belong to the dictation workstream's D-01b/D-01c
   (a `dictation.hold` row per hold) and, later, P6-07 (`UsageRecord.taskID`). One owner per call
   site: P0-20c's rows are frozen; D-01b adds the hold row; P6-07 adds the task id and touches no
   other row. Any change to a row another task owns is a new decision, not a side effect.
6. Handle collision (recorded, no action needed for Phase 0/1/2): `UsageLogSelfTest.swift` is the
   single runner for every usage case (U/M/D/R/E); add cases, never a second marker.

### RESUME HERE — 2026-09-25: Phase 0 complete, Phase 1 next

**Phase 0 is done.** All 29 rows are `done` (27), `done (won't do)` (P0-16) or `blocked` (P0-10).
The gate was run and its report is committed: `Tests/Reports/AGENT-OVERHAUL-P0-2026-09-25.md`
(`db9a84f`).

The headline:
```
AGENT_ANSWERS_OK: 3/3 answered by Qwen3-4B-Instruct-2507
```
turn 3 returning the real calendar. `make acceptance TIER=core` came out `CORE 14/15 PASS`, the
only failure being the documented known-red `--selftest-wake-live` — better than the baseline's
12/14.

**Before Phase 1 opens, two things need a quiet machine:**
1. Re-run `--selftest-agent-answers` and `--selftest-model-unopenable`. Both were green on
   2026-09-24 and missed their budgets (18 s / 5 s) at the gate under load average 24–58. If they
   still miss on an idle Mac, **P1-06 owns the per-round budget** — P0-05's risk note says so —
   and no threshold may be lowered.
2. Re-run `make test`. It is blocked by the dictation workstream's uncommitted
   `Core/DictationController.swift` (optional-unwrap errors at :1466/:1494); it passed earlier the
   same day.

**Phase 0's three reds and their owners:** `--selftest-toolloop-production` (two prompt-size lines
→ P1-03/P1-06); `--selftest-voice-pipeline` (P0-10's blocked EOU race → P2-04/P2-07, plus a new
answer-quality line for Phase 2); the two timing budgets above.

**Then Phase 1**, starting with **P1-01** (`--selftest-toolloop-live`; `--quick` is the per-task
gate, a full 30-case run is for the phase exit), then the order line in 00-README §3.

Operational notes for the next executor:
- The tree is shared with dictation/meetings workstreams that commit concurrently (`D-*`, `M-*`).
  They have repeatedly left untracked test-first files and uncommitted edits that broke the whole
  build (a missing `@escaping`, a missing import, a malformed switch, a duplicated typealias).
  Always `git status` before staging; never `git add -A`; park with a copy kept outside the repo
  and restore exactly; re-run `make install OPEN=0` if `run-selftest.sh` reports `codesign
  verification failed`.
- `stash@{0} temp-wip` (75 files) still exists; its clean-file changes were restored. Leave it for
  the other workstream to drop.
- `--selftest-hf-search` passes now (6.4 Gi free); it needs more than the 4 GB reserve.
- Phase 6 (`07-PHASE-6-DURABLE-JOBS.md`, folded in on 2026-09-25) **extends** Phase 3's
  `TaskBridge`: do not build a second ledger, a second result channel or a second tool manifest.
  In that file P6-08 runs after P6-09 — §3 is authoritative.

## Fold of 2026-09-25 — the multi-agent durable-jobs roadmap

`roadmap/todo/next-notes-multi-agent-durable-jobs-memory-roadmap.md` was rewritten against the tree
at `78cebc9`, audited against the code, and then **partially absorbed** — **and has since been
deleted** (REVIEW-LOG §6). Its surviving half is
`roadmap/backlog/memory-lifecycle-consolidation-roadmap.md`; its provenance prerequisite became
**P4-07a**. What changes for the executor:

1. **Four of its eleven phases named objects this roadmap already owns** — `TaskBridge` (P3-03a/b),
   `OutputScheduler` (P3-04a/b), `AgentCapabilityManifest` (P1-03), island ownership (P3-09). Those
   phases are **deleted** from that file and replaced by an absorption map. **Do not build a second
   ledger, a second result channel or a second tool manifest from it.**
2. **Its durable-job half became Phase 6** (`07-PHASE-6-DURABLE-JOBS.md`; P6-01…P6-10 above). It
   is an **extension** of `TaskBridge`, not a new model: `TaskID.raw` is already `AgentTask.id`,
   the same UUID string `agent-tasks.json` holds.
3. **Its memory half was not folded into Phase 4 as a phase, and the source file is gone.** The
   provenance fix that everything else needs — `MemoryEntry` currently writes three denormalised
   fields and drops the rest of the gate — became **P4-07a**, a lettered subtask of P4-07 and a
   prerequisite for P4-11. Tiers, consolidation and auto-apply stayed a roadmap in
   `roadmap/backlog/memory-lifecycle-consolidation-roadmap.md`, sequenced behind all three, because
   its gate is precision/recall against a fixture corpus that does not exist yet and a phase gate
   that cannot be evaluated is not a gate. Reason recorded in REVIEW-LOG §6.3.
4. **Four proposals were rejected outright**, each because this roadmap already has the better
   version: a separate `AgentJob` type (→ `TaskRecord` + `TaskDurability`), an `AgentResultBus`
   (→ D11/D13), an `AgentUsageLedger` and `job_usage` table (→ P6-07's `UsageRecord.taskID`), and
   an `AgentToolScope` (→ P1-03). See REVIEW-LOG §6.2.
5. **Action lanes (`ActionLane {instant, fast, consequential}`) were deliberately not made tasks.**
   They are a latency property of P1-03 and P3-04, not a durability one. Recorded as requirements
   instead:
   - **P1-03** should expose the consequence grade a lane classifier needs.
     `FunctionCallRelevance.consequentialIDs` is `private static let` at
     `Agent/FunctionCalling/FunctionCallRelevance.swift:177`, so nothing outside that file can read
     it. **A lane decision may not consult a model** — a 300 ms "is this consequential?" call
     would defeat the lane it is choosing. `AgentRisk` (`Agent/AgentModels.swift:10`) and
     `PermissionPolicy.allowsAutomatically` (`Agent/Permissions/PermissionPolicy.swift:114`) are
     the other two inputs.
   - **P3-04** should keep the instant-lane orchestration budget (< 50 ms) honest, because after
     P3-04b the scheduler is the only thing that starts audio.
6. **P6's ids are interleaved with P3's deliberately** (P6-08 runs after P6-09) so an executor
   reading this ledger in id order does not start P6-08 first. The migration order in
   `07-PHASE-6-DURABLE-JOBS.md` §3 is authoritative and the **Depends on** lines agree.
7. **Nothing under `roadmap/` is committed** (00-README §2), so the fold is documentation-only: no
   build, no install, no `install.lock` contention, and no effect on either live workstream.
| **P1 exit gate — the systematic cap** | **Two very different models both score exactly 15/30** | — | — | diagnosed, not fixed | 2026-09-28 | Measured on the same 30 cases: **Qwen3-4B-Instruct 15/30** and **Gemma 4 E4B 15/30**, with different mixes (Qwen `missed_tool=10, refusal=2`; Gemma `missed_tool=5, refusal=6, wrong_tool=2`). Two unrelated models landing on the same half says the cap is **systematic, not model strength** — which retires the "the model is too weak" reading and points somewhere else. **The cause: the persona card is recited.** Almost every reply ends with a block like `Agent Name: Friend / What it should call you: Serge / How it should sound: Like a friend`. Those labels appear **nowhere in the codebase** — the model is paraphrasing the ~999-char persona block (`PROMPT_SIZE_PARTS: first-pass persona=999`) into a form and reading it out instead of answering. It accounts directly for `N01` ("You are Will. Will, your personal agent." — the card, not a capability answer), `N03`, `C03`, and the Apple run's earlier "I'm Will, your friendly helper". **Direction, not yet done:** the persona reaches the model as a *description* of an identity, and a small model treats description as content to repeat. AGENTS.md already holds the principle — the persona card carries "no technical detail or jargon" because "the Apple voice path hears only that card" — so the shape of what the card says is load-bearing and is currently untested for recital. Making it read as *how to behave* rather than *what this agent is* is the fix to try first, and it needs a fixture that fails when a reply echoes a card label | | | | | | |
| **Phase 1 exit gate — final measurement** | **15/30 on both models, before and after the persona fix** | — | — | blocked on model behaviour, not prompt | 2026-09-28 | Three measurements, same 30 cases: Qwen3-4B-Instruct **15/30**, Gemma 4 E4B **15/30**, Gemma after the persona-card fix **15/30**. Two unrelated models and a prompt change that measurably improved the replies all land on the same half. The dominant remaining class is **REFUSAL (8)**, and every one is a **read**: "Would you like me to list them?", "Should I search your email for messages from her about the budget?", "Should I do that?" for a file search. AGENTS.md's permission model is explicit that *a read runs itself because it is invisible to everyone else*, and the planner prompt already says **"If a listed tool can answer the request, call it now; never ask whether you should."** So the instruction is present, in plain words, in the tool section — and the model asks anyway. This is instruction-following, not a missing rule, and a fourth prompt edit aimed at it would be the kind of change this file records as "measured and rejected". **Conclusion: the 25/30 bar is not reachable by prompt, manifest, guard or grammar work on these two models.** It needs either a model that follows the instruction, or a case set that accepts an offer. Both are decisions above this file's pay grade | | | | | | |
| **Two candidate models measured** | **Qwen3.5-4B and the configured cloud model** | — | — | measured, both worse | 2026-09-28 | Asked whether a different model clears the 15/30 wall. Two were measured on the same cases.
**Qwen3.5-4B** (`unsloth/Qwen3.5-4B-GGUF`, Q4_K_M, 2.74 GB) — deliberately **not** the `Qwen3.5-4B-MTP-GGUF` repo, which is the draft-head trap AGENTS.md names. Header read `general.architecture = qwen35` before spending the download, the app's own probe then returned `verdict=opens` (`qwen35` is in the table generated from llama.cpp b10621, and the linked binary agrees). **It is a worse instruction-follower for this app: 2/10 quick**, against Qwen3-4B 6–7/10 and Gemma 4 E4B 6/10. A newer model scoring lower is the fourth measurement landing on the same wall.
**`inclusionai/ling-3.0-flash-sante:free`** (the owner's configured `openRouterAgentModelID`, run with `--allow-cloud` at their request) — resolved and connected fine: `OPENROUTER_OK: catalog, key, completion and stream verified`, 200k context. **Scored 0/10**, and the 0 is not a bad model, it is a failing path: 9 of 10 replies are `The model didn't finish that answer` at 0.0 s. The unified log says why — `tool planner call unreadable: kind=truncated … text=search_email<arg_key>maxResults</arg_key>` on every case, backend `prompt-convention`. The model emits a tool call and the completion is cut before it parses, and `OPENROUTER_REASONING: reasoning_tokens=28 visible=3` shows the allowance going to reasoning. **A cloud model does not produce a better result here; this one cannot complete a tool turn at all.** The concrete error is swallowed into one generic sentence by `AgentReplyRenderer`, which is why the log was needed | | | | | | |
| **P1-04 producer fix — the gate was not a model wall** | **Parser had no reader for an emitted dialect** (`7802de8`, `76160ba`) | — | P1-04 | done, measured | 2026-09-28 | **This corrects the "model wall" conclusion above, and the correction is the finding.**
Captured from the eval report, verbatim, from `inclusionai/ling-3.0-flash-sante:free`: `<tool_call>get_agenda` / `<arg_key>date</arg_key>` / `<arg_value>2026-09-28</arg_value>` / `</tool_call>` — a **complete, correct** call in the Hermes **line** form. Two producer-level defects, neither the model's fault: (a) **U+200B inside the tags**, from the model's own detokenisation — no file under `Sources/` contains U+200B, so our prompt is clean and the tags simply did not match; `stripInvisibleMarks` now runs at the one place a completion enters `parse`, beside `stripReasoningBlock`, and `round.raw` is untouched. (b) **The dialect had no reader at all.** The prompt asks for JSON inside the tags and `decodeCall` read JSON, XML (`<function>`/`<invoke>`) and bare objects — and not this. A reader, not a prompt change: the prompt already states the format it wants, and `parse`'s contract is "every format the shipped models are known to emit". `requireKnownName` still holds, so an unmarked call may only name an offered tool.
**Measured.** Cloud model, same 10 cases: **0/10 → 2/10** (`pass` 0 → 2, `missed_tool` 10 → 5, and C01/C04 now run `get_agenda` / `search_email`+`get_agenda` in one round each, where before no tool ever ran). The run also got ~3× slower, which is the fix working: nine cases used to fail in 0.0 s with nothing parsed.
**And on the local model it was worth more than the cloud one: Qwen3-4B 15/30 → 19/30**, `refusal` 8 → 2. The second part of the commit paid for itself independently: the reminders rule said *"wait for the user's yes before schedule.create"*, which instructs the model to **ask** — and asking in prose loses the details, adds a round trip, and turns an approval card into a yes/no in a chat bubble. It now reads *"then call schedule.create — the card it raises is the yes, not a question in words."* That edit also paid the 1-token overshoot the `.browser` rule had introduced (`2001` against a `2,000` ceiling).
`--selftest-native-tools` carries the captured completion as a case, built with `\u{200B}` rather than pasted — a pasted zero-width space is invisible in a diff and in review, which is the whole difficulty. It failed before the fix with the production symptom (`calls=[] malformed=["truncated"]`).
**What is left of the 11-point gap, and it is two decisions rather than a typo.** (1) *Capability denial* — K03, F02, O02 read "I don't have access to…" with a tool in the roster. (2) *Calendar facts from the prompt* — R03, Y02, O03 answer from the `AgentNow` block, which still carries the next events; that is the same "prompt answers before the tool can" defect as the front app, and unlike the front app it cannot simply be dropped, because `--selftest-now-block` pins "the paths that speak carry the date and the next event" as a deliberate P4-01 decision. Whether a 4B model may be told the next meeting is above this file's pay grade | | | | | | |
| **All four models, updated test** | **Every model re-measured after the parser fix** (`02754d2`) | — | — | measured | 2026-09-29 | Qwen3.5-4B and Gemma were last measured against a build that **could not read the model's dialect**, so both numbers were stale; re-run. **Qwen3-4B-Instruct 15/30 → 19/30** (owner 6/10), **Gemma 4 E4B 15/30 → 16/30** (owner 7/10), **Qwen3.5-4B 2/10 quick → 2/10 quick** (unchanged in score, completely changed in shape: it now calls a tool in 5 of 10 cases where before it called almost none), **ling-3.0-flash-sante 0/10 → 2/10 quick**. **The honest reading: the fix was worth a lot to one model and little to the others.** Qwen3-4B gained 4 cases and `refusal` fell 8 → 2; Gemma gained 1; Qwen3.5-4B gained nothing, which says the dialect was never its binding constraint — it emits parseable calls and simply does not reach for the tool. So "the parser was capping every model" is too strong: it was capping the two models whose output it could not read, and the two whose output it could read were already failing for a different reason.
The re-run also found a flaw **in the reader added the day before**: Qwen3.5-4B wrote `<arg_key></arg_key>` and the value was filed under `""`, handing `filesystem.search` a `folder?=true` it cannot use. `pendingKey` is cleared on an empty key. An empty **value** is kept, because `search_email(query=)` is a real call and "no filter" is how that tool says "the latest" — the same over-correction as sweeping newlines out of a line-oriented format.
One unexplained observation, recorded rather than smoothed over: the **first** post-fix Gemma run exited by itself after 21 of 30 cases with no score line, no crash report and a normal `runningboardd` AppExit. The rerun completed cleanly at 16/30. Not reproduced, not diagnosed; the disk was at 5.1 GB and the model is 4.64 GB, so memory or disk pressure is the honest suspicion, and a clean repeat is not an explanation | | | | | | |


## P1-31 decision and handoff — 2026-09-30

[Report and provenance](../../../Tests/Reports/toolloop-live/2026-09-30-p1-31-investigation.md)
record paired runs on one frozen app and exact existing Q4_K_M files; no download,
cloud run, role/default change or cleanup/iMessage implementation edit. The harness
previously rebuilt planner inputs from real account/grants instead of its fixture
roster. Corrected quick scores are Qwen3 5/10→6/10, MiniCPM 2/10→3/10; Gemma
ordinary 5/10 and Qwen3.5 ordinary 2/10 have incomplete Needle arms (5 and 7 cases
attempted, engine timeouts). These are diagnostics, not a recommendation or SB-07
completion. Earlier 9/10 vs 7/10 Qwen quick reports used the faulty roster and are
not the before/after delta of this fix. Historical scores above remain dated evidence.

Qwen full ordinary/Needle scores are 17/30 vs 16/30, owner 7/10 vs 8/10. First
fixture-result p50 improves 9.047→2.994 s, but whole-case p95 worsens
49.038→51.012 s. Shared-machine measurements omit first token/audible response
and overlap; no promotion gate passed. Normal Agent turns retain the ordinary planner.

Policy continuation now prevents recall from ending a save objective, but live Y01
still omits the save. M03 search coverage, M04 draft, F03/A02 follow-through and
O08/O09 compound completion remain red. The unchanged grader also misclassifies
“I ran out of time before finishing the rest.” through its `i ran` claim phrase;
Needle full C01 is an honest unfinished stop labelled FABRICATED, not an invented
completed action. Do not relabel a stop PASS: next pin this classification defect
red first, then address write/combined-read follow-through on the existing runner.

Regression markers and logs are in the report. Native tools yielded 4/5 grammar-valid
local rounds on two runs of its separate direct grammar-planner path; it is not green
and its exact failure needs diagnosis. No native-mode default flip is authorized by
this evidence. The usage regression required the header pass removed by P1-02; its
assertions now require the actual read and reply records rather than restoring an
extra model round trip. Phase 1 and parent P1-31 remain open.

P1-31a committed as `ac3b852` (production/tests/reports only); roadmaps remain local/ignored. Final rebuilt production and usage logs are linked in the report. Parent P1-31 and Phase 1 remain in progress with the current native-tools red recorded above.

## P1-31b follow-up — 2026-09-30

[Report](../../../Tests/Reports/toolloop-live/2026-09-30-p1-31b-follow-through.md) records the red-first timeout/claim correction and broad-mail grounding fix. A stop is TIMEOUT even after a verified read, never PASS; a broad inbox request no longer becomes a content search for “email.” Explicit topics/quotes/subject and requested counts remain. No extra model round, approval, runtime/store or role/default change.

The manifest save/draft/combined-read hints and independent-read batching prompt were tested and removed: ordinary quick 5/10→4/10, with a new WRONG_TOOL and two timeouts. One real fixture draft is insufficient evidence to retain that mixed candidate. The comparison's later warm-up was interrupted under load >180 without any case verdict; remaining candidate Needle arms did not run. Raw interruptions are not zero model scores. Final one-job Makefile rebuild/install passed; retained-build grader, production and capability checks passed. Final ordinary quick is 5/10; targeted Y01/M04/O09 is incomplete (3 timeouts); Needle M03 executes the corrected broad read but its answer times out. No promotion.

Voice identity is red on both frozen Before and After with the same reply; native tools' prior 4/5 red remains. Phase 1/P1-31 and all SB tasks stay open. Next work must reproduce actual save/draft/combined-read failures through the existing manifest/runner, without adding another model round or weakening gates. Memory lifecycle prerequisites and OpenCode dictation/iMessage ownership are unchanged.

P1-31b committed as `163ba41` (four Agent source/test files plus reports only). The final installed source restores both original prompt files. Final ordinary quick stays 5/10; Y01/M04/O09 and the Needle M03 answer are incomplete on timeouts, while M03's broad read executes without the invented filter. Parent gates remain failed/open. Ten local roadmap files were updated without committing ignored plans or touching OpenCode implementation files.


### P1-31c — explicit memory saves at the action producer (2026-09-30, completed bounded fix)

Owner authorized the next bounded slice: reproduce Y01 (recall followed by an acknowledgment without a write), identify the first incorrect decision, and verify an actual guarded save and durable read-back. The existing scripted Needle continuation case supplies the missing write itself; it is execution-policy evidence, not evidence that the real model completes the save. Add a red-first production-route regression using Y01's bad outputs and a real temporary memory store. Inspect the existing direct-action seam and sole ToolStepRunner; no prompt experiment, new store/runtime/queue, model/default change, cloud run or downloaded artifact. Related questions/negations/compound and external-source requests must retain planner routing; guarded failures must not be confirmed. Parent P1-31 and Phase 1 remain open.

Retained P1-31c commit `4063667` routes only an explicit single personal fact through the existing manifest/ToolStepRunner before planning. Actual guarded write, durable reopen, repeat deduplication and denial/failure honesty pass; first-person preference follows existing canonical punctuation. Live ordinary Y01 PASS (8.2 s whole run); final Needle-first-enabled Y01 PASS (5.289 s whole case, 1.803 s first fixture, 0 model-planning rounds). Final installed production, usage, isolation, model/cleanup/Settings/UI/voice and 30 correction checks pass. Fixed ordinary quick baseline 4/10 in 350.6 s → final 5/10 in 373.5 s, still red; Y01 excluded, no claimed general gain. Existing S1-mini trial latency remains red at 6.5 s versus 5 s. Parent P1-31 and Phase 1 are open. Reports retain full-disk failed attempts and the corrected punctuation assertion; neither is hidden as a model score.


### 2026-10-01 — owner-approved implementation sequencing revision

Aggregate quality is retained as a readiness/promotion gate rather than blanket entry permission. P2-01 now depends on P0-06/P0-11/P0-20a/P4-01; P3-01 on P0-07/P0-11; P6-01 on P0-07/P0-11. P4-07a can start with its existing P0-11 contract. No implementation state, model/default, eval case, threshold or phase-exit evidence changed. Baseline defects are still recorded as defects. 6A/P3-03a/b file ownership is serial, and 6B waits for its actual P3 contracts. See the [tracked sequencing report](../../../Tests/Reports/agent-sequencing-2026-10-01.md) for the dependency audit and next tasks.

Sequencing policy/audit committed as `0bab73f` (AGENTS plus tracked report only); roadmap edits remain local/ignored. No task implementation state was changed by the dependency revision.

### 2026-10-01 — P3-01 complete; IM-16 prerequisites actively claimed

P3-01 source/regressions committed `c1e635b`; see its report for actual route and
refill producer failures, mutation proof and unchanged quality gates. MOD-02
source committed `7dc1b0c` (by-eye evidence open), bounded SB-01b committed
`8b70b24` (parent adoption/catalog gates open). P3-02 and P6-01 are now actual
parallel source claims. IM-16's production host remains blocked: neither green
baseline nor SQLite alone proves attempt/receipt/recovery/delivery safety.

### 2026-10-01 — duplex and canonical storage verified; next dependencies active

P3-02 is committed as `7e3aba1`; P6-02a as `670bc35`. Final installed
regressions pass, including three duplex runs and the actual original correction
flow through real approval/final validity. Deliberate post-wait revision mutation
fires stale effects and fails; restored source passes. Storage passes 18 cases,
actual manager contention at 1.029/1.358 ms and isolation of 21 files/23 defaults.
Core remains 16/18 with known wake accuracy and unresolved variable dictation
capture/retry/injection/outcome-count failures; no numeric gate was changed.
Parent P6-02's evidence/UI child and phase/model/readiness gates remain open.

P6-03 now extends actual manager persistence with an atomic SQL snapshot/journal,
while JSON authority and visible mirror failures remain. P3-06a adds a pure shadow
reducer and additive production events; current audio/work ownership remains.
Its contract now preserves failed-input write holds while C1 reads progress,
uses a separate replay-relative instant and stable lifecycle identity checks.
Both source owners have been explicitly restarted; root owns registrations and
serial build/install. The external Codex WEBSITE-TO-MAC-EXPERIENCE task retains
all app/site UI ownership. IM-16 remains blocked until actual durable attempts,
receipt-linked recovery, origin/message identity and single task/delivery ownership.


### 2026-10-01 — voice shadow foundation committed, physical coverage open

`5ecc7e6` installs ten pure traces plus the real scripted capture, approval and
streamed-output flow:121events, zero disagreements,40comparisons per field,18
output-present and no unavailable fields. Related concurrent/lifecycle/duplex
fixtures observe zero disagreements; their unavailable floors remain4/0/3.
Recorded121-event replay exits0; missing/empty/negative/backwards traces and
Application Support recording refusal exit1. Scripted teardown cannot activate
real wake capture; the harness guard is exercised seven times. Normal wake
shutdown/ONNX exception remains open. Full physical pipeline/barge/rapid and
whole-suite coverage are not proven; P3-06a stays in progress, legacy ownership
remains, and Core16/18 still fails wake accuracy and computer focus. See the
tracked [report](../../../Tests/Reports/voice-production/2026-10-01-p3-06a.md).

P6-04a-1 held/strict-read foundation source work resumes; P6-04a-2 tagged
SQL authority migration remains open. IM-16 is still blocked on actual durable
attempt/lease/receipt recovery and single task/delivery ownership.


### 2026-10-01 — P6-04a-1 committed; authority migration starts

`6f50e07` commits held restart, strict history reads, stale-response guards and
truthful rejected delegation. Installed original actual text routing fails9
assertions; corrected actual routing passes56cases. Twelve related flags pass,
including durability37, task/approval/guided/AgentPane and voice regressions;
isolation verifies21files/23defaults. Core16/18 still fails wake and computer;
dictation passes this run, earlier intermittent failures remain open.

P6-04a-1 is done. Parent P6-04a remains in progress; P6-04a-2 authority migration
is now active with source implementation after plan review. JSON remains current read
authority. A prepared tag in existing JSON must prevent deleted authoritative
SQL from silently importing stale compatibility history. SQL-first writes,
noncreating authority checks and crash-point fixtures are required before any
switch. Real card restoration/leases/receipts/retry remain open; IM-16 stays blocked.

### 2026-10-01 — P6-04a-2 SQL authority and primary admission committed5de382a

The existing ledger now has transactional authority identity/generation, strict
reconciliation and SQL-first saves; retained tagged JSON is an updated-reader
export/witness. New work cannot be dispatched or acknowledged after primary
commit failure. Actual-source original red3 and admission/import mutations red1
each pin those producers. Native-branch-specific omission stays green through
other rejection boundaries; no sensitivity claim. Installed authority54,
recovery56, durability37 and all13 targeted flags pass; isolation21files/23defaults.
Four process exits/readers pass, with no power-loss claim. Latest CORE15/18 fails
dictation capture/continuity, wake accuracy and computer focus. Owner-history
startup migration, older-binary rollback, live repair and large-history latency
remain unmeasured/open. P6-04a parent stays in progress, pending-card restoration
needs real routing/UI coordination. Leases/receipts/retry and IM-16 remain open.
[Report](../../../Tests/Reports/durable-tasks/2026-10-01-p6-04a-authority-migration.md).

### 2026-10-01 — Closure implementation resumed; source integration is not installed proof

P6-04a-3 is actively claimed: exact pending payload in the existing SQLite ledger,
durable review callbacks, startup restoration and Agent input/held-history consumers
are being integrated. Real approval/edit/final execution, prepared-history product
repair and rejected cancellation tests are still pending. No automatic replay or
IM-16 production host is authorized by these changes.

P4-07a's actual memory writers fail 16 original assertions and pass the copied-source
regression with version-3 descriptors and unchanged exact 115-byte legacy snapshot.
Installed MEMORY_OK, MEMORY_REVIEW_OK, PERSONA_OK and isolation 21 files/31 defaults
verify the bounded prerequisite in source commit `8888474`. The scripted review's
other-person false positive remains open despite precision .938 and recall 1.0.
CORE21/22 retains wake failure; fixed Gemma quick 3/10 remains below the unchanged
9/10 bar. All six task Done-when items are satisfied; owner §4.1 permits bounded
completion without promoting a model/default or completing the phase. See the tracked
[memory proof](../../../Tests/Reports/agent-overhaul-closure/memory-provenance/2026-10-01-p4-07a-producer-proof.md).

P2-01 instrumentation repairs have copied-source before/after evidence. Installed
metrics/isolation checks, the real five-run latency baseline and stall attribution
remain pending in this source-integration checkpoint; later installed evidence is
recorded below. The memory prerequisite's bounded completion does not complete a phase.

### 2026-10-01 — Routine producers verified; installed integration next

P4-12 now has original/current evidence through copied actual routing, budget, model construction and quiet-hours delivery producers: original 10/16 assertions fail, current 16/16 pass. Apple routing uses the existing runner and provider seam; each routine retains its own output budget. A deliberately chosen quiet-hours slot delivers silently. The installed scheduler/runner tests and fixed Phase 4 quick evaluation remain required. This does not prove physical Apple inference or scheduled recovery. See the [routine report](../../../Tests/Reports/agent-overhaul-closure/routines/2026-10-01-p4-12.md).

### 2026-10-01 — Installed task restoration and narrow repair verified

The serial full build and installed rerun pass durability37, recovery56, authority56,
restoration28 and history-repair58. Restoration exercises the actual request producer,
SQL authority, gate, persisted review edits, owning local backend and final runtime,
with only a restricted temporary-file effect replaced. It approves the exact edited
payload once and cannot replay completed history. Negative decisions preserve cards
when the primary save fails. This is not rendered-card evidence, power-loss proof,
remote hosting or general recovery/retry authority.

The first installed restoration run failed10 assertions because the fixture injected
its failure before the real gate admitted both requests; awaiting both producer state
and actual consumer admission resolves that test race. The older durability fixture
also fabricated wait states without retained requests; it now uses the actual
identified request producers and retains its journal/execution assertions. Generic
expected storage diagnostics no longer spell terminal `_FAILED` markers; named test
verdicts still do. Input worker production routing and broader retained-history repair
remain open, so P6-04a-3 and parent P6-04a stay in progress.

### 2026-10-01 — Browser and compatibility producers verified; voice baseline exposes real failures

Installed build 3 passes browser deadline/protocol negatives and real CDP, plus durability37, recovery56, authority57, restoration28 and history-repair58. The browser snapshot producer now propagates transport/deadline errors; only a real unsupported-method response selects the existing compatibility read. The compatibility approval producer preserves the waiting card and issues no live token when SQL admission fails. These bounded proofs do not enable automatic replay or IM-16.

The original installed warm-up + five native voice turns failed with median first audio 4.776 s and worst main-actor stall 156 ms. All five measured turns lacked joined speculative model-pass IDs; run 5 also committed twice and used the VAD fallback. The speculative producer started before its usage identity existed; build 4 reserves that identity before inference and checks identity on adoption. Installed focused/native validation is underway. The duplicate-turn investigation found that reset can give old queued audio new decoder callback identity. Its fix must retain the actual input range and preserve next speech captured before the first commit. No current-counter cutoff, latency threshold change or Phase 2 completion claim is authorized by this evidence.

### 2026-10-01 — Native usage join fixed; aggregate quality stays open

The original/current actual speculative producer regression compiles in both modes: original fails the unchanged pass-to-turn join and changed-identity adoption, current passes both and all five recorder cases. Installed native warm-up + five turns pass the strict usage join, one-commit and playback-acknowledgement checks. Median first audio is 2.894 s (p90 3.729 s), measured worst stall35ms; this is a baseline without a0.9s exit budget. The earlier cold duplicate remains open. Installed frontend routing and actual generation/prefill overlap pass on the diagnostic rerun; its first unexplained failure is retained.

Latest CORE is21/22, with only the existing wake17/24+3/32 failure. make test passes30tests in2suites after reusing the validated external build cache; the separate cache initially lacked XCFrameworks. Fixed quick runs locally on Gemma 4 E4B fallback for the saved cloud role:3/10 in106.9s, unchanged bar9/10, owner stores unchanged. This is a different model from the earlier Qwen run, so no quality gain/regression comparison is claimed. Parent quality gates, Phase2 and IM-16 stay open. The bounded filesystem.read/path clarification has installed producer proof recorded below; its native chooser/card acceptance remains open.

Bounded commits: `bdd9766` preserves speculative usage identity; `e8814c8` propagates browser snapshot deadline failures. CU-05 remains todo for its full live safety/latency contract; the deadline subproblem alone is verified. Neither commit promotes a model, enables IM-16 or closes a phase.

### 2026-10-01 — Narrow file-input producer installed; native consumer proof remains open

Installed app8 restoration70 covers the original28 direct-local permission cases plus42 exact local file-input cases. The original actual missing-path producer compiles and fails2 assertions; the broad initial continuation compiles and fails4 unsupported search/directory assertions; final bounded copied source compiles and passes42. Only typed local `filesystem.read/path` and its sole blocking review gap can park a bound question. Exact retained request/schema identity, valid chosen-file answer and primary SQL admission precede one real temporary read. Legacy questions retain their content without guessed input, stale/duplicate callbacks cannot dispatch, and rejected primary decisions retain the card/row. General text/directory/worker clarification remains open.

Installed app9 authority58 passes after correcting one stale diagnostic fixture to submit a valid bound file answer and exact request identity to the rejected SQL commit. A separate legacy question fixture pins refusal before SQL; no production guard was weakened. Historyrepair58, recovery56 and durability37 remain green. Exact raw original/current and installed log hashes are in the [input report](../../../Tests/Reports/agent-overhaul-closure/input-clarification/README.md), alongside the [restoration](../../../Tests/Reports/agent-overhaul-closure/restoration/README.md) and [repair](../../../Tests/Reports/agent-overhaul-closure/history-repair/README.md) reports.

Latest CORE21/22 retains the existing wake failure; UI8/8 and Experience72 pass. They do not prove the real file picker: root's CUA operation was refused with “Computer Use was not approved to use Next Notes”. The isolated native fixture proposal remains unapplied, and rendered permission/input/compatibility/repair consumer journeys stay open. P6-04a-3 and parent P6-04a remain **in progress**. Broader history repair, automatic recovery/retry, attempts/leases/receipts and IM-16 remain open; downstream P6-05 receives no completion or replay authority from these bounded tests.


**2026-10-01 — P6-06a bounded receipt prerequisite (app13, done under §4.1).** The existing P1-21 receipt producer bypassed all harness disk writes and the production writer could erase undecodable retained rows. The actual original harness compiles/runs red10; actual production original compiles/runs red7; fixed copied store green26. Installed app13 actual Orchestrator disk fixture5 requires a fresh `.fired` read before the temporary effect, fresh `.completed` afterward, and zero additional effects on genuine `.fired` write rejection. Tool review/restoration70/authority58/durability37 and isolation21files31defaults pass. Exact logs, build13 source hashes and captured binary hash are in the [receipt report](../../../Tests/Reports/agent-overhaul-closure/receipt-persistence/README.md). Completed direct quick13 FAILED3/10 (launcher exit1, bar9,189.3s): pass3/refusal2/missed-tool3/ungrounded2, matching all ten prior app12 case classes. Initial header-only via-open evidence is retained separately with no verdict. Child P6-06a is **done** only under §4.1 bounded closure; aggregate model quality stays failed. No separate restart process, power-loss/fsync, attempt/lease fencing, task receipt join or retry/IM-16 authority is claimed. Parent P6-06 remains todo; P6-04a/P6-04a-3 and downstream dependency contracts remain open.


**2026-10-01 — Dictation metrics producer repair (committed `8d29f60`).** The actual original installed app14 fixture failed seven assertions. Five exposed stale-tail ownership and lost existential lane-wait values; the fixed app17 preserves successor capture/state and exact receipts while recording the old engine’s 1.25-second wait through the real disk usage consumer. The identical full Dictation fixture now passes (53.091s), with usage26 and owner isolation21files31defaults also passing. The other two original capture/timing observations passed this run without a causal repair claim. The post-metrics generation check and protocol getter requirement repair their responsible producers; no new await, model pass or queue was added. Exact original/current sources, raw logs and binary hashes are in [the report](../../../Tests/Reports/agent-overhaul-closure/dictation-metric-tail/2026-10-01-installed-original-red.md). Physical target readback, real Parakeet contention and broader Phase 2 latency acceptance remain unproven.


**2026-10-01 — P6-06b bounded worker prerequisite (app19).** Original installed app17 failed10 assertions across27 checks. Current installed worker61 passes the unchanged27 plus genuine-producer ownership substitutions and held-cancel admission/rejection. All12 related checks pass (durability37, recovery56, authority58, restoration70, history-repair58, tool review, actual production tool loop, routine authority, schedule, usage26, owner isolation21files31defaults, grader). Build18 failed only three newly added fixture typing errors and was never installed; exact evidence is retained. Build19 installed binary `43d80d8ce964b491f0462c47c257b870d19b180a529962761a64bc1c7fd38366` is bound to frozen source hashes. The source producer now commits attempt metadata before local backend entry, transactionally rejects stale/failed tool facts, preserves runtime receipts on completion-history rejection, and keeps cancelled/held work under exact stored-row authority. The audit-found recovering Cancel omission was corrected before the successful rebuild. This is bounded closure under §4.1; parent P6-04a/P6-04a-3, heartbeat P6-05 and retry P6-06 remain open. No separate process crash, real lease/liveness, continuation-attempt increment, replacement-worker cleanup, receipt-ID join, standing-grant repair, remote/voice/scheduled authority or IM-16 production host is proven. Latest completed aggregate quick13 remains FAILED3/10; no app19 model score is claimed. See [exact original/current evidence](../../../Tests/Reports/agent-overhaul-closure/worker-attempt-prerequisite/README.md).


**2026-10-02 — P2 diagnostic inputs committed (`8684c98`), original duplicate still open.** The four capture/detector/latency diagnostic sources exactly match their installed app12 hashes. The actual cold native probe passed one commit/one EOU/60 intervals, but it skipped real streamed reply/playback and did not reproduce the original response duplicate. Cases2/3 remain unrun. Committing the instrumentation and honest report supplies no production epoch fence or latency/Phase2 completion. The next prepared case must exercise real capture through frontend and streamed reply/playback before any source repair is proposed.


**2026-10-02 — P6-06b continuation acceptance extension (app20).** No production logic changed. The existing original70 restoration assertions remain, with12 actual permission/input ownership checks added (installed restoration82, input48). Fresh primary rows at both backend entry and immediately before the real temporary write/read require prior attempt+1/currentPID; each continuation allocates once and performs its original effect once. Original and restored old contexts refuse facts/capture/token without changing successor SQL/journal. Replay of the exact captured running successor through the existing isolated fixture/store factory holds it in a fresh Manager with no dispatch; that is fresh-object replay, not process restart/liveness proof. Worker61, tool review and isolation21files31defaults pass again. App20 binary `64cd599a829ad3336265ee2e0908fe2e48a9f66b3c68ca892dc531c38249ffb1` is bound to frozen source hashes. Replacement-handle coexistence remains unproven: current typed-local input/permission callbacks publish and unwind synchronously; no private retry/state seam was fabricated. Parent P6-04a/P6-04a-3, heartbeat/retry/IM-16 and aggregate quick gates remain open. See [exact added acceptance](../../../Tests/Reports/agent-overhaul-closure/worker-attempt-prerequisite/continuation/README.md).

**2026-10-02 — P6-05a bounded admitted progress fields (app22).** Actual original app21 failed20 assertions across five field scenarios, with no original61 failures. Current identical fixture passes93; all14 related serial checks pass, including actual owner isolation21files32defaults and voice scheduling. Actual backend and original temporary-file backing observe exact accepted worker/tool progress fields and fact dates in fresh SQL. Persistent tool-start/completion rejection rolls back distinguishable proposed fields in memory and primary SQL; accepted SQL/export failure still performs the one original temporary read. Same existing calls/event sequence, no extra save/row/await/timer. Parent stale detection/runtime classification/liveness/retry/receipt joins/remote host remain unimplemented. App22 binary `dc264d8dfbc0dcba8485595106beff9b365b11f81dbaa6b8df8186933793ff83` is tied to frozen source; latest model quick is historical app13 FAILED3/10. [Exact evidence and limits](../../../Tests/Reports/agent-overhaul-closure/worker-attempt-prerequisite/heartbeat/README.md).

**2026-10-02 — P6-06c exact typed-local receipt binding (app29; bounded closure under §4.1).** Original installed app26 reproduced9 failed join assertions with prior93 checks green. The producer now captures taskAttempt/taskLeaseOwner on the existing ActionReceipt, passes prepared.id at the executor's final effect boundary, and validates that exact fired receipt before adding its UUID to existing TaskDurability.receiptIDs in the same admitted SQL toolStarted/progress transaction. App29 passes156 cases, including preserved original flow inputs, absent/malformed/duplicate bindings, genuine SQL/receipt rejection, SQL-success/export-failure, completion rejection retaining runtime evidence, and fresh receipt/task stores at actual approval/input continuation backing. All14 related flags pass; owner isolation21files32defaults is unchanged. App28 was a fixture-only compiler failure and never installed. No added store/journal column/save/await/timer/model pass. Parent recovery/stale classification/liveness/retry/remote/voice/scheduled/ACP and IM-16 remain open. Missing links are never proof that no effect occurred; bounded receipt retention remains. Latest aggregate quick13 is historical FAILED3/10, not an app29 model verdict. [Exact evidence](../../../Tests/Reports/agent-overhaul-closure/receipt-attempt-join/README.md).

**2026-10-02 — P6-06d terminal receipt admission (app31, bounded closure).** Original app30 RED3 exposes ignored completed-receipt persistence: one actual read, retained fired receipt/exact task link, yet task completed and result delivered. The actual Orchestrator now requires that existing terminal commit before successful return, gives the exact action-ran/result-not-saved explanation and avoids a false failed-action receipt rewrite. Byte-identical original fixture passes worker169; all14 related flags pass, including actual production loop/restoration82/receipt-runtime5 and isolation21files32defaults. Exact retained fired bytes/state, no success fact/delivery and no fresh-manager replay are pinned. No extra save/store/await/model pass. Consequential-write reconciliation, crash/liveness/automatic recovery/retry and IM-16 remain open. Historical app13 quickFAILED3/10 is not an app31 model verdict. [Evidence](../../../Tests/Reports/agent-overhaul-closure/receipt-terminal-commit/README.md).

**2026-10-02 — P6-05b bounded runtime-class fencing (app35).** Original app33 RED122 confirms five nonlocal-class ownership bypasses, actual native browser misclassification and original local held receipt mutation before late refusal. Manager recognizes positive worker history independently of descriptive class; Backend requires primary validity for every positive typed-local attempt at its existing permission hop, before receipt preparation. Same original185 extension passes app34 worker354; app35 adds eight exact bare/doubly damaged waiting actual-backend negatives (worker362). All14 related flags pass, including restoration82 and owner isolation21files32defaults. Native browser admission is classified by its actual registry descriptor, then fixture stops before authorization/backing. One early fail-fast primary probe, no extra actor hop/await/save/store/timer/retry. Full stale/liveness/recovery/receipt reconciliation and IM-16 remain open; no new model verdict. [Evidence](../../../Tests/Reports/agent-overhaul-closure/runtime-class-fence/README.md).

**2026-10-02 — P6-06e changed receipt-source admission (app41, bounded closure).** Original40 RED5 proves the stale writer erases genuinely unreadable rows added after initialization and delivers success after one actual read. Same-store file identity/metadata admission now preserves exact new bytes, committed fired memory and primary receipt link, with the existing honest result-not-saved failure and no replay. Byte-identical original13 plus18 boundary checks pass worker430 and all14 related flags; source/binary stability and isolation21files32defaults unchanged. No extra Data read/save/store/await/timer/model pass. Concurrent CAS/reconciliation/liveness/recovery/retry and IM-16 remain open; historical app13 quickFAILED3/10 supplies no app41 model verdict. [Evidence](../../../Tests/Reports/agent-overhaul-closure/receipt-source-admission/README.md).

**2026-10-02 — P6-05d last existing primary check (app43, bounded feature prerequisite).** Original42 nil-getter scaffold fails15 missing observations, prior430 functional checks green. Byte-identical real worker fixture passes app43 worker491 (+61), all14 related flags and owner isolation21files32defaults unchanged. Existing primary read reuses exact decoded state/durability and file-binding/generation admission; existing Bool state/attempt/owner predicate unchanged. The same bound-handle value caches accepted/mismatch/unavailable, consumed by its actual debug seam. LAST getter opens no SQL; old continuation cannot stamp successor metadata. Cache can predate later progress/receipt commits and supplies no current authority/health/complete receipt coverage or stale/recovery/retry verdict. No new query/save/store/await/timer/state change. Parent P6-05/P6-06 and IM-16 remain open; historical app13 quickFAILED3/10 unchanged. [Evidence](../../../Tests/Reports/agent-overhaul-closure/authoritative-observation/README.md).

**2026-10-02 — P6-06f denied harness reader privacy.** Original installed46 RED10/40 actual Store/fresh-Manager canaries via dedicated pre-App entry; unchanged40 pass fixed47 and worker531. Denied reader returns empty before owner JSON/SQL; admitted temp import/authority/export controls preserved. Default nil guard precedes owner path/lazy mirror. All14 related flags PASS; mutation guards are unchanged-byte proof only. No owner decode/seed in original proof, no new store/query/await/timer/schema. Full-pane model/default/prewarm isolation, liveness/recovery/retry/IM-16 and quality gates remain open. [Evidence](../../../Tests/Reports/agent-overhaul-closure/task-harness-read-isolation/README.md).

**2026-10-02 — P6-05f shared stdio terminal repair (3b07f4c).** Actual consumed-prompt peer EOF original48 RED1 now passes the unchanged fixture in49 alongside MCP/confirmation/worker531/isolation. Existing pending arbitration settles once after draining already-started reads and final notification ordering. No timeout change/polling/retry or new process owner. Targeted actual peer cleanup and full source/bundle invariance pass; exact ACP attempt/health/effect/recovery/IM-16 remain open. [Protocol evidence](../../../Tests/Reports/agent-overhaul-closure/stale-observation-frontier/acp-review/protocol-verification.md).

**2026-10-02 — P6-05e actual last tool-boundary observation.** Actual original50 nil-observer RED15 missing-feature; same fixture fixed51 worker629 (prior531+98), all19 flags green:14 related +worker +privacy40 +ACP/MCP/confirmation. Same handle binds exact receipt/tool/captured attempt; admitted entry and return/threw before completion-save rejection. No added query/save/store/await/timer/schema/state change. LAST metadata supplies no complete active/effect/health/retry/IM-16 proof. [Evidence](../../../Tests/Reports/agent-overhaul-closure/tool-backing-observation/README.md).

**2026-10-02 — Bounded P6-05g ACP session origin admission (done under §4.1, a6daafc).** Actual original52 RED20/68: wrong/missing/blank/nonstring session IDs enter current reply/activity/permission callbacks. Same fixture fixed53 origin68, six serial ACP runs green including immediate-new and valid outside/late updates; MCP/confirmation/worker629/privacy40/production loop/isolation green. Exact incoming identity guard precedes attribution/broker/gate, no prompt-active filter, sleep, retry/store/queue. Only Session differs original/fixed; Sources/binary/bundle stable, owned fixture processes cleaned. External malformed sender, full ACP conformance, all actor schedules, durable ACP attempts/client ownership/post-await validity/recovery and IM-16 remain open. Aggregate gates unchanged. [Evidence](../../../Tests/Reports/agent-overhaul-closure/stale-observation-frontier/acp-invocation-review/origin-admission/verification.md).

**2026-10-02 — Bounded P6-06g/P6-06h typed ACP startup + exact live context (committed1675da8).** Original57 RED14 through actual Manager/Registry/ACPBackend/Orchestrator/Session/owned peer; fixed58 same fixture worker656. Commit positive typed normal ACP attempt/owner/start/acpWorker before process and fence primary mismatch before the existing runtime checkpoint; compatibility remains unbound. Separate original59 RED5 replays the exact released local context after terminal SQL rejection, causing a second actual read/receipt/journal; unchanged fixed60 rejects before SQL and keeps one read. Integrated worker678 plus all20 focused flags PASS; Source/binary/bundle stability and owner isolation21files32defaults unchanged. No new store/schema/timer/queue/save/query/model pass. Nested/current-client/post-await permission authority, SQL-to-Process actor gap, direct record metadata, ACP receipt-ID joins/activity/compatibility/unverified terminal durability, health/recovery/retry and IM-16 stay open. Historical54 path-literal harness failure and56 timestamp-assertion/type errors are archived, never accepted as product proof; authoritative comparisons57/58 and59/60 use unchanged reviewed fixtures. [ACP proof](../../../Tests/Reports/agent-overhaul-closure/stale-observation-frontier/acp-primary-admission-review/verification.md), [live context proof](../../../Tests/Reports/agent-overhaul-closure/stale-observation-frontier/released-context-review/verification.md).

**2026-10-02 — Bounded P6-06i unverified terminal receipt admission (committed3b2acbb).** Actual original61 RED3: the owned ACP prompt confirms positive primary/receipt identity, then makes its temporary fired receipt source nonregular before valid reply; the old unchecked final save Bool permits completion and result delivery. Same fixture fixed62 worker701 plus all20 focused flags PASS, no Source/binary/bundle drift. Only ActionRuntime's existing final record result is guarded; damaged case retains fired bytes/memory and failed task/jobFailed/exact result-not-saved failure without success reply/artifact, accepted control unchanged, fresh managers no replay. No extra save/query/await/store/queue/timer/model pass. Both intermediate/final writes refuse in this original input; not a final-syscall-only race proof. ACP receipt joins/activity, nested/current-client authority, SQL-to-process atomicity, compatibility, effect reconciliation, crash/liveness/recovery/retry and IM-16 remain open. [Actual proof](../../../Tests/Reports/agent-overhaul-closure/stale-observation-frontier/acp-unverified-receipt-review/verification.md).

**2026-10-02 — Bounded P6-06j ACP receipt startup admission (committede946ecd).** Authoritative original65 RED9, same corrected actual fixture fixed66 worker731/all20 PASS. Actual prepared UUID reaches existing primary tool-start join transaction before owned process work; same process startup reads exact saved fired identity and SQL receipt/event, rejected INSERT no launch/link/success, accepted output and terminal-guard controls unchanged. One existing primary ACP startup transaction added, no new store/schema/await/timer/queue/model pass. Historical63/64 nonoptional-result-vs-nil fixture error is archived, both versions rerun after correction. Completion callback, Session actor gap, nested/current-client authority, direct retained metadata, compatibility, effect/reconciliation/health/recovery/retry/IM-16 and aggregate gates remain open. [Evidence](../../../Tests/Reports/agent-overhaul-closure/stale-observation-frontier/acp-receipt-start-review/verification.md).

**2026-10-02 — Bounded P6-06k ACP completion admission (404725b).** Actual original67 RED4; identical fixed68 worker764/all20 PASS, Sources/binary/bundle stable. ACP defers exact receipt-bound existing completion transaction and checks admission after runtime evidence retention. Rejected completion keeps actual returned couldNotVerify receipt but fails actual/fresh SQL task without result/artifact/success delivery; accepted output unchanged, fresh manager no replay. One primary completion transaction added; no new store/schema/await/timer/queue/model pass. Full-history latency, combined throwing/cancel/writer-loss cases, Session actor/current-client/nested permission authority, compatibility, effect/reconciliation/health/recovery/retry/IM-16 and aggregate gates remain open. [Evidence](../../../Tests/Reports/agent-overhaul-closure/stale-observation-frontier/acp-completion-admission-review/verification.md).

**2026-10-02 — Bounded P6-06l ACP permission outcomes (4f37916).** Original69 actual Session/Gate/owned peer RED3; identical new22 fixture fixed70 plus origin68/worker764/all20 PASS, source/binary/bundle stable. Existing incoming response contract uses serialized Data and nested selected/cancelled result; Session marks cancellation before existing Gate withdrawal and rechecks after existing awaits. No new await/store/queue/timer/model pass. Explicit archived single flat-response assertion upgrade executes in six origin modes with all other inputs/guards unchanged. Cancel-after-Gate proves that branch only, no client epoch/durable nested authority/edited payload/malformed option/ID/cancel-notification/effect/recovery/retry/IM-16 or phase/model promotion. [Evidence](../../../Tests/Reports/agent-overhaul-closure/stale-observation-frontier/acp-invocation-review/permission-result-review/native-verification/verification.md).

**2026-10-02 — Bounded P6-05h cached receipt-source provenance (15aaa5a).** Original71 RED13 missing-feature metadata assertions with all functional controls intact; identical fixed72 worker794/all20 focused flags PASS. Actual reader retains historical quality/counts and writer records its LAST existing source comparison. Same original primer/target reads; changed-source terminal refusal keeps exact bytes/fired evidence, fails result delivery and emits cached readable/mismatch diagnostic. Fresh reader partial2/1; fresh manager no replay. No new I/O/query/save/await/timer/store/queue/model pass. Source1029/binary/bundle invariant; no full-history/current-file/health/stale/recovery/retry/IM-16 or parent/model promotion. [Actual proof](../../../Tests/Reports/agent-overhaul-closure/stale-observation-frontier/receipt-source-quality-review/verification.md).

**2026-10-02 — Bounded P6-06m nested ACP permission entry (a8422ec).** Corrected original74 RED1 returns offered allow after a fresh manager commits recovering while the old handle remains live. Identical fixed75 worker849/all20 focused flags PASS; captured normal typed context reaches same Session, current primary/live-handle probe precedes relay/fast allow. Valid control unchanged, held offered reject/no Gate relay, held SQL/journal exact and runtime reply receipt retained. Existing policy hop reused; harness auto-allow now performs it. Initial73 full55 controls invalid timestamp equality, archived verbatim; corrected same fixture used before both74/75. No new store/queue/timer/model pass/retry. Gate journal/pre-grant and post-await/client/edited-payload authority, broader recovery and IM-16 remain open; no parent/model promotion. [Actual proof](../../../Tests/Reports/agent-overhaul-closure/stale-observation-frontier/acp-nested-attempt-review/verification.md).

**2026-10-02 — Bounded P6-06n durable nested Gate decisions (7756ebf).** Corrected original78 RED21 (Gate17 +actual released permission recorder4) → identical fixed79 worker1017/all20 focused flags PASS;1031-source/binary/bundle invariant. Common exact callback TaskLocal reaches real Gate before both. Request admission precedes presentation; explicit decision admission precedes card/resume/audit/grant, rejected save retains same review, successful facts once. Existing Manager live map refuses genuinely released facts before same primary transaction; cancellation false survives denied-save failure. Actual six-mode peer/triggers, fresh readers, exact receipt joins/no replay, once-only choices. The callback bridge now reaches two existing Gate primary writes for formerly unbound ACP; no separate save/store/await/timer/model pass. Historical76/77 incomplete readiness comparison retained; both authoritative runs use real exact-ID field confirmation with immutable values, not selected UUIDs or weaker checks. Identifier-review producer issue, after-Gate/post-Broker/client/edited-payload authority, standing grants, physical UI/latency/recovery/retry/IM-16 and parent gates remain open. [Proof](../../../Tests/Reports/agent-overhaul-closure/stale-observation-frontier/acp-gate-admission-review/verification.md).

**2026-10-02 — Bounded P6-06o post-Gate primary authority (c3997f6).** Actual original80 RED1 offeredallow after valid saved approval followed by synchronous fresh-manager recovering hold → unchanged fixed81 worker1074/all20 focused flags PASS.1032-source/binary/bundle invariant; only Session differs. Same real Gate/peer/current startup receipt joins, exact retained request+approved seq before recoveryHeld, no Task.cancel substitution, held row/journal untouched, accepted control unchanged and fresh no replay. Existing Gate suspension runs approved-bound current predicate on MainActor before Bool/wire handoff; adds ONE fail-fast primary probe, no additional await/save/store/queue/timer/model pass. Historical approval stays; no invented denial. Broker allow/standing grants, after-probe actor handoff/client/close/edited payload, metadata-review producer bug, physical latency/recovery/retry/IM-16 and parent gates remain open. [Proof](../../../Tests/Reports/agent-overhaul-closure/stale-observation-frontier/acp-post-gate-review/verification.md).

**2026-10-02 — Bounded P6-06p ACP review metadata producer (416fd44).** Actual original82 RED4 (editable internal taskID, unready review, actual first-approval refusal) → identical fixed83 worker1092/all20 focused flags PASS;1033-source/binary/bundle invariant. ONLY one Session argument-construction line changes: exact operationJSON remains, duplicate editable taskID removed while typed request/Broker/context/permission attribution preserved. Dedicated18 actual standaloneSession/Gate/peer cases with valid knownUUID, no ManagerID override; original actual refusal captured before genuine confirmation cleanup. Common n160/o57 contract amendments before both retain exacttypedowner/header/encodedrequest/fields/SQL/receipt/card/decision/hold and strengthenoperation dictionary checks; all7 bound reviews fields1/problems0. GenericBuilder calibration unchanged, historical77 exactUUID unavailable; no inspector scrubbing/exemption/newstore/query/save/await/timer/model pass. PhysicalUI/latency/standing grant/after-probe/client/close/payload/recovery/retry/IM-16 and parentgates open. [Proof](../../../Tests/Reports/agent-overhaul-closure/stale-observation-frontier/acp-review-metadata-review/verification.md).

**2026-10-02 — Bounded P6-05i current owned ACP Process/transport (272c7b0).** Actual original84 missing-feature RED10 → identical fixed85 worker1132/all20 focused flags PASS;1034-source/binary/fullbundle invariant. Existing actual stdio Process plus lock-protected transport now emits current PID/running/closed/EOF/outgoing-pending metadata, through common weak SAME Session bridge at admitted existing fire. Real accepted and fresh-primary-held task consumers preserve startup receipt/protocol/current primary refusal, repeated SQL/journal/export/receipt nonmutation and exact current probe ownership. Supplementary standalone Session observes EOF WHILE child alive then actual retained Process exit, transparently not worker-EOF timing proof. Missing/released is unknown; no new registry/store/query/save/progress/timer/foreground await/model or state change. Foundation/OS sample is not health/atomic lease; active tools/effects/current receipts/human waiting/stale detector/recovery/retry/IM-16/parent gates open. No instrumented compute/physical UI/latency/model verdict. [Evidence](../../../Tests/Reports/agent-overhaul-closure/stale-observation-frontier/current-runtime-observation-review/verification.md).

**2026-10-02 — Bounded P6-05j current approval wait (d7fee76).** Actual original86 RED6 missing current projection → same fixed87 worker1161/all20 focused flags PASS;1035-source/binary/fullbundle invariant. Existing Gate active/queued typed Request.taskID now reaches actual current-bound Manager diagnostic, preserving restored-only routing. Two owned typed ACP workers keep exact forty-day progress/running rows while real visible/queued approvals wait; repeated read-only samples preserve SQL/journal/export/receipt/card/choice. Rejected decision save retains both, accepted A promotes B, task-scoped Gate withdrawal returns false before actual worker release returns nil. Exact operation/payload/once wire/receipt/consumer controls remain; no external effect/model/owner seed/decode/newstore/timer/query/save/statechange/foreground await. Queue traversal/task lookup not big-history latency proof. Approval-only conservative taskID exclusion, no broader person-wait/attempt/agewindow/stale/recovery/retry/IM-16/phase promotion. [Actual evidence](../../../Tests/Reports/agent-overhaul-closure/stale-observation-frontier/human-wait-observation-review/verification.md).

**2026-10-02 — Bounded P6-05k current heartbeat diagnostics (83d4853).** Corrected original90 RED149 → same fixed91 worker1352/all20 focused flags PASS;1040-source/fullbundle invariance. Two parallel producer implementations (pure age windows/current receipt fingerprint) integrate through actual Manager fresh primary, SAME ACP Session and current Gate waits. Old heartbeat is age evidence only; actual40day approvals exclude it. Fresh held generation correctly returns unavailable while process remains live, without LAST/memory fallback. Actual receipt-source changes retain original fired/cache/decoded evidence and refuse successful delivery. Initial88/89 fixture precision/generation errors are archived, with unchanged corrected cases before both90/91. Explicit off-path diagnostic only: no automatic monitor/heartbeat generation/newstore/timer/foreground await/state/retry/model pass. Complete session/tool/effect coverage, recovery/retry/durable delivery/IM-16/parent and aggregate model/latency gates remain open. [Actual proof](../../../Tests/Reports/agent-overhaul-closure/stale-observation-frontier/heartbeat-integration-review/verification.md).

**2026-10-02 — Bounded shadow playback producer repair.** Original92 RED13 and same-common reducer RED6 → fixed93 PASS33/10 traces/all20 focused flags, recorded actual native replay and latency instrumentation PASS. VoiceContracts now retains confirmed queued/playing pause, refuses while-paused receipt revival, clears terminal speaking and preserves existing proposals/current acknowledged playback at model completion. Only that producer differs across1041 Source entries; full bundle is invariant. Real native consumers preserve output/token/generation and owner stores. Historical heard is not resumed evidence: epoch/postresume receipt, late-after-resume, approvalResolved, pending Gate/card/live Island ownership and original WAV physical/latency/core acceptance remain open. [Actual proof](../../../Tests/Reports/agent-overhaul-closure/voice-playback-projection-prerequisite/verification.md).


**2026-10-02 — Quit crash implementation, bounded Notes and recording-owner proof; installation held.** Owner confirmed PID41058 occurred during Quit. Original staged131 RED3/7 → same-input fixed132/native133/native135 PASS7; actual Notes native brackets and owned task join before exit, resumable state retained. Introduced ordinary asynchronous diagnostic quit deadlock measured in direct132 process sample; same notes-context133 exits0 after diagnostic instruction producer correction. Recording-stop original134 RED4/24 → fixed135 PASS24 through actual delegate/pipeline/service/store, idle15 unchanged: close the future Notes owner before stop so no late job or false finished state is produced. Physical stop is substituted, not active ASR proof. All source/bundle/model guards pass; notes-context/meeting-resume/isolation/worker1908 repeat green on135. No install or owner migration. Startup Parakeet/Pocket original138 RED9/26 → fixed139 PASS26 with same real public model assets and three producer files changed; pending preparation joined and closed admission refused. Parakeet CoreML drain took41.04s, not fast-quit acceptance. Native Notes7 and recording39 remain green; nine relevant139 checks pass including worker1908/isolation. Actual meeting ASR queue140 RED4/24 →141 PASS24, same native fixture/assets and exactone queueproducer delta; existing tail joined, closed admission refused, queued successor no new native entry. Native Notes7/recording39 plus11related141 checks pass, worker1908/isolation unchanged. Physical capture, final-pass maps/handoff, other ASR/playback/native owners and full-process exit remain open; no phase/model/UI/latency/recovery/retry/IM-16 promotion. [Actual evidence](../../../Tests/Reports/agent-overhaul-closure/native-termination-crash-review/2026-10-02-pid41058/VERIFICATION.md).

**2026-10-03 — Final-pass cancellation and quit ownership, bounded proof; installs still held.** Actual original 143 RED16/77 → unchanged fixed 144 PASS77 through the real FinalTranscriptService, synthetic stereo CAF, shared native ASR and default pipeline. Only the Final producer changes: retain the cancelled task until return, close new admission, join captured tasks and prevent cancelled publication/handoff. The meeting, transcript and audio remain exact and resumable; no late Notes owner is created. Six actual exits and all Source/bundle/45-public-asset invariants pass. Compile-invalid 142 fixture corrected identically before both authoritative versions. Healthy pipeline integrity67 and native meeting-finals on all three tracked synthetic WAVs pass; final recall meets/exceeds live and wrong-language share is zero. Eleven focused 144 regressions pass, including worker1908 and isolation21files32defaults. Integrated Notes7 and shared-ASR24 repeats also pass actual exits and source/bundle/model or public-asset invariants. Non-cancellation-error fallback, fresh-process resume, playback, diarization, other native contexts and physical capture remain open; no full safe/fast quit, installed UI or parent roadmap gate is promoted. [Producer and original/fixed evidence](../../../Tests/Reports/agent-overhaul-closure/native-termination-crash-review/2026-10-02-pid41058/VERIFICATION.md).

**2026-10-03 — Diarization cancellation/quit ownership, bounded proof; installation held.** Actual original145 RED24/130 → unchanged fixed146 PASS130 across six native modes, exact two responsible producer changes and all1,056 compiler inputs pinned. Service retains cancelled task/binding until return; actor closes load admission and joins its preparation task. Cancel/quit preserves exact resumable meeting/transcript/audio, suppresses stale publication and default pipeline handoff; actual healthy watchdog fallback remains once-only with retry audio retained. All exits and Source/bundle/22-public-input guards pass; independent original/fixed review confirms first-verdict grading precedes diagnostic veto/cleanup. Seven related flags, worker1908/isolation21files32defaults, Notes7, ASR24, final77 and recording39 repeat green. Integrated Pocket pending-load repeat is INVALID from LLVM disk exhaustion, not a passing verdict; repeat remains required after reversible root-owned artifact archival. Active preparation, playback, other contexts and direct capture still open; no full safe/fast quit or parent/model/UI/recovery/retry/IM-16 promotion. [Actual evidence](../../../Tests/Reports/agent-overhaul-closure/native-termination-crash-review/2026-10-02-pid41058/VERIFICATION.md).

**2026-10-03 — Integrated146 startup repeat completed.** Exact Pocket pending-load repeat after verified root-owned archive space recovery passes8 with actual exit0/no timeout/unchanged Source,bundle,public assets. Initial LLVM ENOSPC run remains INVALID; no product workaround or assertion change. Startup26, Notes7, ASR24, final77, recording39 and diarization130 integrated checks are green. Other-context original diagnostic mount is held for a first-verdict veto safety correction before executing RED; playback/direct-dictation preparation continues off-source in parallel. Installation/full safe or fast quit remain open.

**2026-10-03 — Other-context original evidence and harness correction.** Safe first-verdict veto/cleanup is mounted. Original147 qualifies six actual S1/embedding/vocabulary modes with producer failures; library preferences control is INVALID. Metadata-only original148 finds five Metal keys added to merged defaults during actual qualification, with the exact isolated PID persistent domain unchanged at every checkpoint. All49 assertions remain intact; the responsible harness comparator needs correction and a complete repeated original/fixed pair. No library fix, aggregate gate, full safe/fast quit or installation claim. Playback and direct-dictation work continues off-source in parallel. [Evidence](../../../Tests/Reports/agent-overhaul-closure/native-termination-crash-review/2026-10-02-pid41058/VERIFICATION.md).

**2026-10-03 — Other-llama bounded shutdown proof.** Corrected original149 RED22/49 → unchanged fixed150 PASS49 across seven actual owner modes, exact six producer bodies, identical COMMON fixture and qualified owned-domain negative/restoration controls. Eleven related flags and selected native Notes7/Pocket8/ASR7/final24/diarization43 pass actual exits and invariants; worker1908 and isolation21files32defaults retain their existing verdicts. Historical147/148 library control failures stay INVALID. Model-trial caller publication, active playback/direct capture/preparation, full safe or fast quit and exact SIGSEGV reproduction remain open; installation and aggregate/phase/IM-16 claims remain held. [Actual proof](../../../Tests/Reports/agent-overhaul-closure/native-termination-crash-review/2026-10-02-pid41058/VERIFICATION.md).

**2026-10-03 — implementation resumed with isolated parallel worktrees.** Root verified P6-06q as above and P4-07 functional pair155/156 (RED13/70 →PASS70; six related flags pass, quick3/10 fails). Knowledge worker prepared actual typed-library route/stream/citation conductor; UI review found the unsanitized saved-claim producer contract, and an additive revision is underway before native admission. It also implements reader-scaled memory/page budgets. A third worker implements quit reliability outside primary Sources. [Worktree ownership](../../../Tests/Reports/agent-overhaul-closure/parallel-implementation-2026-10-03/worktrees.json). Prepared/syntax-checked work is not native acceptance; root retains serial build/model/native ownership and the index stays frozen.


2026-10-03 bounded P4-08 reader capacity: actual171 RED4→172 PASS31, full ASK flag passes with typed59 preserved. Same captured window reaches system and fitter;512 refuses before retrieval/stream,4096 fits. Exact concrete provider runtime replaces global-runtime identity lookup; cold fallback performs no load. Genuinely loaded capacity/residency/native/full gates stay open. [Proof](../../../Tests/Reports/agent-overhaul-closure/provider-reader-capacity-production/verification.md).

**2026-10-03 — P6-05 ACP activity candidate NOT accepted (209/210).** Actual same86-check fixture: original209 RED24 activity admission/progress failures → fixed210 repairs those24 but introduces one scheduling failure. At512 historical tasks/32 actual callbacks, main-queue wait1189.0465ms exceeds unchanged100ms (original0.428875ms); actual probe arm/in-burst/drain controls all pass. Storage producer repair is active; no acceptance, monitor/health/retry or phase promotion. [Actual retained failure](../../../Tests/Reports/agent-overhaul-closure/p6-05-acp-activity-production/verification.md).

**2026-10-03 — Bounded P4-02/P4-08 producer integration211/212.** Actual context20 RED8→PASS and scheduled advertised-reader8 RED1→PASS, with eight related flags and source/bundle invariance. Three responsible producer files differ among1,079 compiler inputs. Stored history/no-effect/current request/floor controls pass. No native classifier accuracy, deflection re-route, genuine loaded capacity, latency, live-owner or phase promotion. ACP210 scheduling failure is retained and not accepted. [Paired proof](../../../Tests/Reports/agent-overhaul-closure/route-context-and-scheduled-reader-production/verification.md).


## 2026-10-03 — actual P6 activity storage and log-only scheduler observation

Qualified original214 fails exactly27 worker assertions (100ms scheduling1, storage2, missing monitor24); staged215 passes2161 unchanged checks. Actual512-task/32-update main-queue stall1330.809→94.840ms; small-history61.027ms, unchanged100ms limit. Same task ledger/export/event transaction now updates only bound activity timestamps while retaining actual witness/authority checks. Six current monitor modes emit one log-only observation, released none, all seven exact owned peers end. Fourteen related flags plus standalone task-reader40 pass with Source/full-bundle invariance. Only three producer files differ across1082 compiler inputs. Historical209/210 stall is reproduced and repaired for this workload; cadence under long routines, periodic beats, other runtime/event coverage, health/outcome/retry/IM-16 remain open.

Restored-query original214 reaches16 checks/RED2; fixed215 reaches46 and actual search1 but fails seven question-equality checks. Precision hypothesis under source audit; no query completion promoted. The combined implementation remains open until qualified input proof. [Actual evidence and retained failure](../../../Tests/Reports/agent-overhaul-closure/p6-restoration-monitor-storage-production/verification.md).


**Integrated217 update:** query correction qualifies actual216 conditional16/RED2→21746/PASS/fullrestoration128. Exact scalar trace confirms five request fields and canonical equality; seven prior215 failures came only from fractional-vs-stored timestamp expectations. The same217 worker repeat fails1 responsiveness assertion at318.892ms (median callback3ms/max144ms), despite storage/monitor functional controls green and21594.840ms passing. Thus P6 activity latency is reopened, not claimed closed; per-stage producer diagnosis delegated. Query and bridge implementation continue independently. No arbitrary process termination or budget change. [Actual retained results](../../../Tests/Reports/agent-overhaul-closure/p6-restoration-monitor-storage-production/verification.md).


**2026-10-03 — P3-03a bounded canonical voice admission verified.** Original219 RED14/47 → fixed220 same47 PASS and prior cancel14/C1 controls, with12 related staged flags PASS and1084 exact compiler inputs differing only Manager/Bridge/Coordinator. Refused primary intake starts no worker/warmup/ghost job and promises no work; rejected terminal commit reports failure without successful delivery; explicit cancel still fences the same Task immediately while exposing save failure. Cached status reads the same admitted row without a model. Original218 frontend fixture0checks remains INVALID; COMMON correction precedes both219/220. Parent origin/session/revision/delivery/ACP/jobs deletion/live reducer remains open; P6 latency217 failure retained. [Actual evidence](../../../Tests/Reports/agent-overhaul-closure/p3-task-bridge-production/verification.md).


**2026-10-03 — P6-04a-3 bounded directory restoration.** Original222 conditional26/RED3 →223 actual60/fullrestoration188 PASS, same correctedCOMMON inputs, exactly ReviewBuilder/Manager/AgentView changed among1085 compiler pins. Actual typed folder question restores exact canonical identity, conditions successor before one confined indexed tree read; admission refusals read zero times. Twelve related flags pass and owner isolation21files32defaults is unchanged. Worker223 retains a distinct burst-small1927.571458ms/100 failure (maxcallback1834ms), history97.773209ms; previous217/221 failures retained. Physical picker/cards/TCC/focus/VO and general clarification/recovery/retry/IM-16 remain open. [Evidence](../../../Tests/Reports/agent-overhaul-closure/p6-directory-input-production/verification.md).


**2026-10-03 — P6 activity cost repair224/225, bounded.** Actual224 history118.703ms FAIL1→225 worker2206 PASS on three unchanged runs: small50.451/46.728/49.636ms, history65.259/61.994/70.935ms, limit100ms. Same86/104 fixtures plus45 genuine compaction controls;13 required related flags pass, including reader40/restoration188/isolation. Exact1086 compiler pins differ only Store/SQL boundary guard/Journal. Ordered IDs avoid mapping, exact export reserves capacity, nil diagnostic hooks skip confinement work, and identical retention SQL starts from terminal events. No skipped events/export/timeout/process kill. Earlier223small1.8sec spike remains unattributed; large retained-journal performance/full latency and parent health/recovery/retry/IM-16 remain open. Supported periodic/cadence entry now proceeds under§4.1. [Actual proof](../../../Tests/Reports/agent-overhaul-closure/p6-restoration-monitor-storage-production/verification.md).

**2026-10-03 — P6 periodic ACP heartbeat and unstarved scheduler, bounded227/229.** Corrected original227 fails19 actual feature assertions; fixed229 passes2366 identical checks plus13 required related flags. Only4 producer files differ across1088 compiler inputs. Eligible225-second owner beat commits heartbeatAt only; current primary/session/permission controls preserved. Actual held routine allows two shared observations, one owner, ordered foreground Run-now and joined stop; no cancelled success delivery. Source/full-bundle invariant, owner21files32defaults unchanged.226 compile-only callback arity failure and228 duplicate original UNRUN retained. Normal wallclock/model owners/complete tool/effect coverage, health/recovery/retry/IM-16/general latency remain open. [Proof](../../../Tests/Reports/agent-overhaul-closure/p6-restoration-monitor-storage-production/periodic-cadence-production/verification.md).


**2026-10-03 — Task-scoped scheduled-worker ownership bounded verification.** Original241 RED34/154 →fixed242 same154 PASS in both runs; unchanged integrated repeat worker2678 PASS and17 related flags PASS. Manager retains the actual per-run Task, admits positive attempt/current process/start before model completion, fences real tool/receipt/journal/terminal callbacks and revokes cancellation immediately even if its SQL save is refused, retaining that exact handle until return. Other eligible routines finish independently. Only Manager differs across1095 compiler inputs; fixture/input/bundle invariance holds. First242 retains inherited small-history1830.389ms FAIL1 (callbackMax1777ms) despite history70.187ms; unchanged repeat44.657/57.725ms passes. Cause remains open, with no sampler/OS attribution and no full latency promotion. Build240 immutable createdAt compile rejection is retained; identical constructor correction precedes both241/242. Scheduled periodic/model progress, full health/effect coverage, crash/recovery/retry/IM-16 and parent exits remain open. [Actual proof](../../../Tests/Reports/agent-overhaul-closure/p6-restoration-monitor-storage-production/scheduled-run-owner-production/verification.md).

**2026-10-03 — bounded public voice admission accepted.** Corrected264 RED26/92/control0→265 same92 PASS, prior200/outcome68 and28 related flags PASS. Duplicate held/terminal intake retains one task, same-session approval blocks new intake, omitted/wrong/closed/replaced-session answer starts no backing, and exact current answer continues once. Historical262/263 cache-vs-primary timestamp controls remain invalid; same stored-clock control qualifies264/265. Raw origin/full API, canonical revisions, ACP/jobs migration, physical/5ms, quality/latency and phase gates remain open. [Evidence](../../../Tests/Reports/agent-overhaul-closure/p3-task-bridge-production/public-spawn-resume-production/verification.md).

**2026-10-03 — canonical revision original qualified; fix under verification.** Actual270 reproduces eight failures across115 checks: correction/answer revision stays zero and refused corrections allow the old effect. All76 codec controls and prior API92 remain green; seven actual Gate context matches use the guarded authored temporary context. Historical266 compile and267–269 invalid codec setup runs are retained. Same COMMON setup corrections preserve final inputs/assertions and primary ownership fences. Exact two-file producer fix271 now saves canonical revisions and holds rejected effects, but exits1 on one naming-retry reply conjunct across125 checks; diagnostic272 is measuring it with inputs/assertions unchanged. No task closure is claimed. [Current proof](../../../Tests/Reports/agent-overhaul-closure/p3-task-bridge-production/canonical-revision-production/verification.md).

**2026-10-03 — canonical voice revision bounded-verified.** Corrected original273 RED8/115/control0→fixed274 PASS125, all76 codec controls and28 related flags green (worker2678/restoration188/authority58/isolation21files32defaults). Same real worker/Gate/effect consumer now commits revision before acknowledgment, holds rejected corrections, and executes the corrected effect once after legitimate retry. Exact1104 compiler inputs differ onlyManager/Coordinator; fixture identical. Historical266–269 invalid setup and271/272 naming expectation mismatch retained; measured SAMECOMMON corrections precede both. Generic changed-primary voice writes/current-question fencing, progress/fullAPI/5ms/legal states, ACP/jobs migration and all parent gates remain open. [Evidence](../../../Tests/Reports/agent-overhaul-closure/p3-task-bridge-production/canonical-revision-production/verification.md).

**2026-10-03 — raw Bridge admission bounded-verified.** Actual275 RED26/89/control0→276 same89 PASS plus28 related flags, priorrevision125/API92green; exact1105 compiler inputs differ onlyBridge/Coordinator. Invalid origin/session/zero-turn/empty requests and stale closed/reopened duplicate receipts now refuse before lookup/save. Nil-origin diagnostic compatibility remains unbound. Raw accepted rows still require the planned Manager-owned worker dispatch; arbitrary old same-session turns, cancel/progress/primary fencing/fullAPI/5ms/legal states/ACP/jobs migration and all parent gates remain open. [Evidence](../../../Tests/Reports/agent-overhaul-closure/p3-task-bridge-production/raw-spawn-authority-production/verification.md).

**2026-10-03 — public cancel verification remains open.** Actual277 RED9/35/control0→278 same35 PASS, but required delivery immediately fails two unchanged saved-question cancellation checks (DB04/DF14). The introduced guard refuses unhosted saved questions before commit/withdraw; this must be repaired at owner routing before acceptance. No parent/task promotion. [Evidence](../../../Tests/Reports/agent-overhaul-closure/p3-task-bridge-production/public-cancel-owner-production/verification.md).

**2026-10-03 — public cancel bounded repair verified.** Introduced278 saved-question regression is retained and reproduced279 RED2/276 with39 owner controls green. Fixed280 same276/39 plus priorraw89/revision125 and all28 related flags PASS (worker2678/restoration188/authority58/isolation21files32defaults). Same Manager now owns the single weak live voice link; unrelated Bridges refuse hosted workers/questions, while genuinely unhosted saved input cancels through existing commit/withdraw even after SQL refusal. Exact1106 compiler inputs differ onlyManager/Bridge. Parent API/primary/progress/5ms/legal states/Manager-only ownership and physical gates remain open. [Proof](../../../Tests/Reports/agent-overhaul-closure/p3-task-bridge-production/public-cancel-unhosted-question-production/verification.md).

**2026-10-03 — current voice primary-store prerequisite and public notice privacy bounded-verified.** Corrected original282 primaryRED2/37/control0→fixed284same37PASS; original281INVALID unsupported paused fixture is retained, with SAMECOMMON legal recovering correction beforeboth. Actual public notice logger282RED2/284/control0→284same284PASS preserves allprior276/UIpayloads and logs onlyconstantkind labels. Both independent producers share all28relatedPASS (worker2678/restoration188/authority58/isolation21files32defaults),1108compiler inputs differ onlyTaskStore/IslandState. Generic Manager revision/resume callers/current-question authority still require nextAPI and live-owner integration; no extraquery/store/worker. ParentPhase3 and all broader gates open. [Store proof](../../../Tests/Reports/agent-overhaul-closure/p3-task-bridge-production/voice-primary-condition-production/verification.md); [privacy proof](../../../Tests/Reports/agent-overhaul-closure/p3-task-bridge-production/island-public-notice-log-production/verification.md).

**2026-10-04 — exact voice transition/serializer prerequisites bounded-verified.** Actual285 RED5/40→286same40PASS and all28relatedgreen, worker2678/restoration188/authority58/isolation21files32defaults. ThreeStore transition failures plus two genuine negative-revision encoder failures are repaired with unchanged inputs/predicates. SameSELECT checks current exact question ID and same transaction accepts legal revision/explicit input transitions; encoder nonzero comparison preserves invalid-1 for its existing decoder refusal beforeSQL. Exact1109compilerinputs differ onlyStore/AgentTask. Generic Manager callers and same live runtime ownership remain migration work, not established by these prerequisites; delivery-attempt negative supplementary case is prepared/unrun. ParentPhase3/6 and aggregate gates open. [Proof](../../../Tests/Reports/agent-overhaul-closure/p3-task-bridge-production/voice-primary-api-transition-production/verification.md).
