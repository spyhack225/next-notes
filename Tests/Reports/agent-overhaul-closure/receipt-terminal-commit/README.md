# P6-06d: admit completed action receipts before task success

2026-10-02. Bounded source repair under AGENT-OVERHAUL §4.1; parent recovery/retry stays open.

## Confirmed cause and producer

ActionOrchestrator persisted `.fired` before backing, verified the backing's result,
then ignored the Bool returned by add(.completed). A real disk error at that last
write left the committed receipt `.fired`, while returning normal success to Executor
and Manager. Task completion and successful result delivery therefore claimed more
than the durable receipt could establish. P6-06c's exact task receipt link exposed
this next producer contract; it did not repair terminal persistence admission.

Installed original app30 reproduced **three failed assertions** through actual Manager
→ LocalBackend → Executor → Orchestrator → temporary FilesystemExecutor read. The fixture
read ran once, then moved the actual fired JSON aside and replaced its writable file
path with an empty directory. Original trace:

```
TASK_RECEIPT_COMPLETION_TRACE: terminal=completed effects=1 resultDelivered=true retainedFired=true primaryLink=true
TASK_WORKER_ATTEMPT_FAILED: 3 assertions
```

The other156 cases remain green. Both control and rejected path use fresh receipt/SQL
readers before the same real temporary read. No fictitious model/tool result is supplied.

The producer now requires the existing add(.completed) to succeed before returning.
On refusal, only the transient local status becomes couldNotVerify, so the existing
catch does not label an already-run action failed or attempt another receipt write.
The receipt store retains its committed fired state/bytes. The error says exactly:
“The action ran, but its result could not be saved. Check it before trying again.”
Manager commits a failed task with that explanation and no successful result delivery.
No new store, save, await, retry or model pass is added.

## Verification

Installed app31 passes **169 cases**. Its terminal fixture is byte-identical to original
app30 (SHA256 9aa0839309a63352c9ca40498b58ba197b6cfc4af44efd3ffe085212e2e8988e). Fixed trace:

```
TASK_RECEIPT_COMPLETION_TRACE: terminal=failed effects=1 resultDelivered=false retainedFired=true primaryLink=true
TASK_WORKER_ATTEMPT_OK: 169 cases
```

Success control still writes completed evidence and delivers the actual read. Rejection
preserves exact pre-backing fired bytes, committed in-memory receipt, empty refused path,
primary/memory receipt link, one backing operation and no jobCompleted/success text.
The exact plain failure reaches Manager and actual announcement. Fresh-object Manager
reopens both terminal rows without any new backend start, additional read or history edit.
That is fresh-object observation, not a process crash.

All14 serial related flags pass:

| Flag | Actual marker | Exit |
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
| `--selftest-schedule` | SCHEDULE_OK | 0 |
| `--selftest-usage-log` | USAGE_LOG_OK: 26 cases | 0 |
| `--selftest-store-isolation` | STORE_ISOLATION_OK: 21 files and 32 defaults unchanged; TOOLLOOP_PRODUCTION_OK | 0 |
| `--selftest-toolloop-live-grader` | TOOLLOOP_LIVE_GRADER_OK | 0 |
| `--selftest-voice-scheduling` | VOICE_SCHEDULING_OK | 0 |

## Provenance and scope

Original binary SHA256: 372501e81c2707a74480b82a42a2a4be4ec4ece0ba935688ff3b474d149c7572.
Final binary SHA256: 77879466c4e57574484ce07b4e54502145c216c7d5fa947e1ef15bcd5b96527b.
Both binary cache locations, complete source manifests, original/final snapshots,
build logs, direct flag logs and runner stdout are retained here. Original and final
manifest stability checks found no changed source at verification. The existing UI
owner's app29 capture ran in a separate explicitly released native slot; no shared
Swift/build/model work overlapped original30/fixed31.

The durable receipt remains fired when terminal persistence fails; the local status
is not a committed couldNotVerify/completed fact. Task and receipt storage are separate
boundaries. The bounded proof uses a real isolated read; it does not prove mail/send
reconciliation, crash/power-loss durability, automatic replay/retry, runtime liveness,
remote/voice/scheduled/ACP authority or IM-16 hosting. The unverified-result and unknown
outcome branches keep their own contracts; this change repairs the verified completed
receipt producer only. Parent P6-04a/P6-04a-3/P6-05/P6-06 remain open. No model/default
changed or model eval ran; historical app13 quickFAILED3/10 remains below unchanged9/10.
