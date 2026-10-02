# P6-06e: retain changed action-receipt sources

2026-10-02. Bounded actual writer repair under AGENT-OVERHAUL §4.1.

## Confirmed cause

ActionReceiptStore decided once at initialization whether its history was writable.
Later record/save calls encoded the old in-memory array and atomically replaced the
current file without checking that it was still the source that had been read.
That could erase unreadable evidence added after initialization. P6-06d correctly
refused success when save returned false, but this writer incorrectly returned true.

Original installed app40 reproduces five assertions through actual Manager →
LocalBackend → Executor → Orchestrator → restricted temporary FilesystemExecutor read.
The existing fired receipt and exact primary task/attempt link are observed fresh before
one real read. After that read, the fixture appends a genuinely unreadable required-field
row to the real receipt source, before the runtime attempts its terminal receipt.
The original writer erases those exact new bytes and falsely delivers success:

```
TASK_RECEIPT_SOURCE_TRACE: terminal=completed effects=1 resultDelivered=true retainedFired=false primaryLink=true
TASK_WORKER_ATTEMPT_FAILED: 5 assertions
```

The preceding 399 worker assertions do not fail. No model or invented tool response is
used. Original runtime fixture SHA256:
`bf5c9e1997040f8b1834cd78091a64ff3bf3623eb07337ea15a3eb1c79818735`.

## Producer repair

The same receipt store retains an admitted source fingerprint: known absence or regular
file device/inode/size and nanosecond modification/change timestamps. Existing Data load
is bracketed by matching fingerprints. Each existing atomic save checks that admitted
source first; changed, missing, nonregular or unavailable sources refuse the write and
record restores the prior in-memory receipts. Successful own writes refresh admission;
failed post-write refresh permanently blocks further writes for that instance.

Default self-test shared receipts remain memory-only and never fingerprint owner paths.
There is no new file read, store, save, await, timer, retry or model pass. The existing
terminal runtime admission supplies the action-ran/result-not-saved explanation; no
consumer sanitizer, retry or special task outcome was added.

## Verification

Installed app41 passes **430 worker cases**: prior399, unchanged original13 and
additive18 actual-writer boundaries: foreign source appearing after absent initialization, deleted committed
history, byte-identical atomic replacement, in-place edit, directory/symlink replacement,
and successive own commits. Fixed original trace:

```
TASK_RECEIPT_SOURCE_TRACE: terminal=failed effects=1 resultDelivered=false retainedFired=true primaryLink=true
TASK_WORKER_ATTEMPT_OK: 430 cases
```

The exact newly unreadable bytes, committed fired memory, primary receipt link and one
original read remain. The real Manager/announcement receives the exact action-ran/result-
not-saved explanation, with no completed task fact/result delivery. Fresh Manager starts
no backend and changes no terminal history. The ordinary control still commits completed
receipts and delivers the actual read.

All14 related serial flags pass. Native marker/exit evidence is retained in
[app41-related/verdicts.json](app41-related/verdicts.json):

| Flag | Actual markers | Exit |
|---|---|---|
| `--selftest-task-durability` | TASK_DURABILITY_OK: 37 cases | 0 |
| `--selftest-task-recovery` | TASK_RECOVERY_OK: 56 cases | 0 |
| `--selftest-task-authority` | TASK_AUTHORITY_OK: 58 cases | 0 |
| `--selftest-task-restoration` | TASK_RESTORATION_OK: 82 cases | 0 |
| `--selftest-task-history-repair` | TASK_HISTORY_REPAIR_OK: 58 cases | 0 |
| `--selftest-receipt-persistence` | RECEIPT_RUNTIME_OK: 5 cases | 0 |
| `--selftest-tool-review` | TOOL_REVIEW_OK | 0 |
| `--selftest-toolloop-production` | TOOLLOOP_PRODUCTION_OK | 0 |
| `--selftest-routine-authority` | ROUTINE_AUTHORITY_OK | 0 |
| `--selftest-schedule` | GOALS_OK, SCHEDULE_OK | 0 |
| `--selftest-usage-log` | USAGE_LOG_OK: 26 cases | 0 |
| `--selftest-store-isolation` | STORE_ISOLATION_OK: 21 files and 32 defaults unchanged, TOOLLOOP_PRODUCTION_OK | 0 |
| `--selftest-toolloop-live-grader` | TOOLLOOP_LIVE_GRADER_OK | 0 |
| `--selftest-voice-scheduling` | VOICE_SCHEDULING_OK | 0 |

The original app40 binary SHA256 is
`1941fd732a63d038dec25a9cad187fb7cd1a61014ab5b5bbc0f9aecef1c2e4e3`;
fixed app41 is `375f58f6d2c3bdd32d5aca54ebda753c86bf2cf03110b402fef4773053fe3f7b`.
All pinned source/resource/build inputs and installed binary remain unchanged through
root verification. App41 also packages the independently owned two-file UI candidate;
its native UI acceptance belongs to that owner and is not inferred from worker proof.
Raw compiler logs, full original/final producer sources and byte-identical runtime
fixtures are retained alongside these reports. Tool-review/routine-authority/schedule/
usage-log supply actual stdout markers without companion app logs; no missing log is
interpreted as a pass.

## Limits

Metadata check followed by Foundation atomic write is not a cross-process atomic
compare-and-swap. A concurrent replacement between check/write/refresh remains open;
this proves the reproduced sequential stale-source rejection, not concurrent-writer
fencing. Metadata collisions/hostile metadata restoration are not content hashing.
Post-write observation failure has no dedicated injected native regression.

The actual effect already happened; refusal must never claim it did not, automatically
replay it, or destroy the committed fired receipt/task link. Fresh-object observation
is not process crash/power-loss proof. Consequential-write reconciliation, complete
receipt coverage beyond bounded retention, liveness/recovery/retry and IM-16 hosting
remain open. Historical app13 quick FAILED3/10 stays below the unchanged9/10 bar;
no new model/default, aggregate quality or broader readiness is claimed.
