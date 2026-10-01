# P6-04a-1: held restart and strict legacy history

P6-04a-1 verified and frozen for root scoped commit; parent P6-04a remains in progress. P6-04a-2 (tagged import, transactional authority marker,
SQL-first writes and crash-point proof) remains open. JSON stays read authority.

The original real reader silently converted unreadable, malformed or duplicate-ID
JSON into usable empty/invalid history. The actual manager then accepted new work
and could overwrite those original files. The same isolated actual-source fixture
fails 20 assertions on committed P6-03 and initially passes 45 after fixing the
reader and manager producers. Raw [original red](2026-10-01-p6-04a-1/original-red.log)
and [first green](2026-10-01-p6-04a-1/first-green.log) are retained.

The new reader throws and latches failed initialization; saved originals remain,
and manager record mutations/persistence/new execution are blocked. Missing JSON
alone is a fresh empty history. No SQLite migration or database creation happens
from a failed legacy read.

Actual typed producer sources are `text` (RealtimeAgent delegation) and `user`
(manager default); isolated harness rows use `selftest`. Their local/ACP running
records enter persisted `recovering`, with factual `recoveryHeld`, never
`workerRecovered`. Legacy queued records fail with a conservative explanation.
Voice, scheduled, remote iMessage and unknown owners keep their prior failed
restart baseline. Terminal/pending records, frozen compatibility command/directory,
existing payload/order/artifacts and informational attempts are retained. No
one-shot approval survives restart.

The 34-case pure planner has no action that can start or reattach a worker. Lease,
receipt, journal and checkpoint observations remain supplied facts; missing receipt
IDs and incomplete journals never authorize replay. No process probes, heartbeat
producer, retry, session reattachment or owner runtime adoption is implemented.

The source is frozen for root integration. Focused stale response/failure-property
cases fail 13 assertions before the fix; exact waiting-state admission now rejects
stale input/approval (including approved=true) before arguments/grants/tokens or
queueing. Execution admits queued records only. Failure properties preserve the
known reason or a neutral incomplete-task message, and ask for review before retry;
artifact absence no longer establishes an effect or undo outcome. Guided expectations
were corrected without weakening the stronger existing AgentPane assertion.

The original durability baseline fails five assertions after the changed restart
contract (including its blocker injected before initialization). Its assertions now
measure held running/conservative queued/persisted restart behavior. JSON-write
failure injection moved after successful initialization; strict unreadable-load
cases remain separate. Both actual restart JSON-write failure and held-writer
contention are visible: the former preserves old JSON/SQL/journal; the latter
preserves JSON authority/new held state and leaves old SQL/journal unchanged.

Final isolated actual-source run: **TASK_RECOVERY_OK:53 cases** (34 pure plus19
store/manager cases). [Stale/copy red](2026-10-01-p6-04a-1/stale-copy-red.log),
[old baseline red](2026-10-01-p6-04a-1/old-baseline-red.log), and
[final synchronous green](2026-10-01-p6-04a-1/final-sync-green.log) are retained.
One new fixture initially deadlocked by querying the same intentionally locked
writer; it was stopped (130), corrected to use the other actual connection, and
rerun. This was a fixture defect, not a product lock diagnosis.

App-only `runIncludingDelegation` adds three actual explicit text-route cases
(corrupt/duplicate/unreadable isolated history) via root's SelfTest-only injected
manager seam. It verifies truthful rejected acknowledgement/delegated flag,
no task-success audit, no dispatch/insert, retained files and no SQLite creation.
Root intentionally keeps the original bad acknowledgement for installed red;
these three cases now pass in the final installed run after the consumer correction.
Standalone success does **not** establish this route or end-to-end acknowledgement.

Root's baseline app built in297.40s and installed. The actual registered recovery
flag exits1 with **9 assertions**, exclusively the old reply/delegated/task-audit
behavior across all three rejected-history routes. The same installed flag's
synchronous foundation cases pass53. This is the original actual consumer failure,
not a mocked reply or a skipped harness submit.
[Installed original red](2026-10-01-p6-04a-1/installed-original-delegation-red.log).
The confirmed acknowledgement producer cause was `RealtimeAgent.delegate`
discarding the returned failed task status and unconditionally promising background
work, while outer `handle` always set `delegated:true`. The root's acknowledgement
owner now returns the failed task's diagnostic with `delegated:false` before task
success audit/background promise; outer handle forwards that actual result.
Root final app build passes in374.88s, installs, and the same actual registered
route passes **TASK_RECOVERY_OK:56 cases**, exit0. [Final installed recovery](2026-10-01-p6-04a-1/installed-final-task-recovery.log).
All12 relevant installed flags pass: durability37, tasks, tool review, guided,
Agent panes, activity, realtime, production tool loop, voice reducer, duplex and
store isolation (21files/23defaults), alongside recovery56.
[Installed summary](2026-10-01-p6-04a-1/installed-final-summary.json).
These are actual consumer-path assertions; no model or account is needed for the
failed-submit route.

Ordinary pending input/permission card routing remains unimplemented; preserved
rows and planner `restoreCard` decisions do not restore a live continuation/card.
Held rows currently appear in existing recent/history UI filtering; no active-pane
or visual evidence is claimed.

No app build, installation, model run, owner seeding, recovery/host promotion or
cross-file atomicity claim comes from this worker. Root installed validation passes;
final core/scoped commit are owned by root. Existing unrelated wake/computer focus and intermittent dictation failures
remain reported separately.

## Final copied-source mutation evidence

Every mutation compiles copied actual sources outside the app tree and exits1;
production files remain frozen. Related synchronous durability passes28.

| Check | Result | Raw |
|---|---|---|
| Remove real waiting-input admission |4 assertions fail|[stale input](2026-10-01-p6-04a-1/stale-input-mutation.log)|
| Remove real failed-load save latch |6 assertions fail|[failed load](2026-10-01-p6-04a-1/failed-load-mutation.log)|
| Omit actual startup decision producer |9 assertions fail|[restart](2026-10-01-p6-04a-1/restart-mutation.log)|
| Change terminal noAction into held |3 assertions fail|[pure planner](2026-10-01-p6-04a-1/planner-mutation.log)|
| Unmodified related store/manager |28 cases pass|[related green](2026-10-01-p6-04a-1/related-sync-green.log)|

## Open authority child design and required evidence

Use a versioned envelope in the existing retained `agent-tasks.json`, carrying the
same complete ordered task payload and a durable *prepared* tag. This tag is an
intent witness, not SQLite authority and not another task ledger. Strict decode
and existing-mirror preflight precede any JSON rewrite. Missing JSON is first
installation only if the unmarked mirror is empty; orphan mirror IDs or incompatible
existing ordered artifacts are visible conflicts, with original files untouched.

Prepared tagged JSON is atomically written before the single SQL transaction
reconciles rows and commits its authority marker. That transaction must retain
journal/dependency rows and existing artifact metadata, without stale-row deletion
or journal compaction. Failed reconciliation rolls all SQL changes and the marker
back; the tag remains a truthful prepared witness. Later marked saves commit SQL
snapshot/events first, then export compatibility JSON with a separately visible
export failure. Do not claim cross-file atomicity or measured power-loss durability;
the proposed evidence covers process-crash ordering only.

Required actual fresh-store boundaries for P6-04a-2:

- Malformed/unreadable/duplicate/nonfinite JSON before preparation changes no
  original JSON, SQL rows, child rows or marker.
- Prepared tag plus present valid unmarked SQL reconciles conservatively; it does
  not choose stale mirror rows as authority just because IDs match.
- Triggered import failure leaves SQL snapshot/children/marker rolled back.
- SQL marker committed, compatibility export failed: a new store reads SQL even
  when JSON is stale, corrupt or absent; visible export failure remains distinct.
- Close every store, delete marked SQL and its WAL/SHM, reopen a new store over
  retained tagged JSON: fail closed without creating a replacement DB or importing
  stale JSON. The authority probe/open must be noncreating, including race handling.
- Marked SQL corruption or unsupported schema preserves original bytes and cannot
  fall back to compatibility JSON. A failed load blocks ordinary save/submit.
- Shared/default harness load performs no owner migration/tag/export/database
  creation. Only explicitly validated temporary injected stores may exercise it.

Schema version/marker changes and these crash points are intentionally absent
from P6-04a-1. No authority switch is implemented by the held foundation.


Root final CORE: **16/18**, exit1, no skipped entries. Wake remains17/24
hits and3/32 false at0.6; computer still cannot inspect its owned test window.
Dictation passed49s on this run; earlier intermittent dictation failures remain
unresolved. Raw `core-summary.txt` and `core/` retain actual verdicts. Root uses
the original catalogue/classifier with per-launch AppKit restoration options
placed before self-test flags. No owner saved preferences are changed.

Baseline build297.40s and final build374.88s both exit0. The first baseline
install hit ENOSPC in staging before the swap; removing only its exact failed
stage and reproducible project caches allowed the same compiled result to install.
Final signed installation passes with OPEN=0; no GUI launch or model/default
promotion. Held memory state is not claimed committed when restart save fails.
Manager-owned admission is the verified rejection boundary; this foundation does
not adopt other voice/scheduled/remote execution owners or restore live cards.
